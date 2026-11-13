import Foundation
@testable import SoundModel
import PlaybackRenderBridge
import FixedRender

enum Failure: Error { case failed(String) }
func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.failed(label) }; print("PASS \(label)") }
actor Memory: LibraryPersistence {
    var data: Data?
    var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func commit(_ value: Data) -> LibraryWriteOutcome { data = value; writes += 1; return .committed }
}
struct ParameterModelChecks {
    static let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
    static func run() async throws {
        let initialPort = Memory()
        guard case .fresh(let initial) = await SoundLibrarySession.open(persistence: initialPort, limits: limits, builtins: .quickMenu) else { throw Failure.failed("fresh") }
        for (name, target) in [("Everyday", "test.everyday"),("Filters", "test.filters")] {
            _ = try await initial.select(initial.snapshot().definitions.first { $0.name == name }!.id, on: target)
        }
        _ = try await initial.checkpoint()
        let seed = await initialPort.data!, initialState = try await initial.snapshot()
        var controls = Set<UUID>(), evaluations = 0
        for assignment in initialState.assignments {
            let use = initialState.uses.first { $0.id == assignment.use }!
            for control in use.controls {
                guard case .slider = control.face else { continue }
                controls.insert(control.id)
                for companionValue in [0.0, 1.0] {
                    let fullPort = Memory(seed), livePort = Memory(seed)
                    let full = try await SoundLibrarySession(persistence: fullPort, limits: limits)
                    let live = try await SoundLibrarySession(persistence: livePort, limits: limits)
                    let binding = LibraryBinding(assignment: assignment.id, use: use.id, target: assignment.target)
                    let address = LibraryControlAddress(path: [], control: control.id)
                    var option: LibraryOptionGesture?
                    for companion in use.controls where companion.id != control.id {
                        guard case .slider = companion.face, !use.optionControls.contains(where: { $0.child.control == companion.id }) else { continue }
                        for owner in [full, live] { _ = try await owner.move(LibraryControlAddress(path: [], control: companion.id), expected: binding, to: .scalar(companionValue)) }
                    }
                    if let relation = use.optionControls.first(where: { $0.child == address }) {
                        guard let parent = use.controls.first(where: { $0.id == relation.parent.control }), case .choice(let options) = parent.face else { throw Failure.failed("parent") }
                        let selected = options.first { $0.id == relation.option }!
                        for owner in [full, live] { _ = try await owner.move(relation.parent, expected: binding, to: .scalar(selected.position)) }
                        option = LibraryOptionGesture(parent: relation.parent, option: relation.option)
                    }
                    var state = try await live.menuState()
                    let originalDocument = try await live.snapshot(), identity = state.identity(for: binding)!
                    let documentGeneration = state.liveGeneration
                    guard let plan = state.parameterPlans.first(where: { $0.identity == identity && $0.address == address && $0.option == option }) else { throw Failure.failed("all13 plan \(control.title)") }
                    var fullMappers = [RenderAssignmentMapper(),RenderAssignmentMapper(),RenderAssignmentMapper()]
                    var liveMappers = fullMappers
                    for (index, value) in [0.0,0.2,0.5,0.8,1.0,0.499999,0.500001,0.999999,1.0].enumerated() {
                        if let option { _ = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(value)) }
                        else { _ = try await full.move(address, expected: binding, to: .scalar(value)) }
                        guard let delta = try plan.evaluate(.scalar(value)), let next = state.applying(delta) else { throw Failure.failed("live evaluation") }
                        state = next; evaluations += 1
                        let reference = try await full.snapshot(), document = try await live.snapshot()
                        let expected = reference.assignments.first { $0.id == assignment.id }!
                        try check(document == originalDocument && state.liveGeneration == documentGeneration && state.transientPosition == address,
                            "\(control.title) explicit transient positions leave actual document/generation unchanged")
                        try check(state.uses == reference.uses && state.assignments == reference.assignments && delta.assignment.parts == expected.parts,
                            "\(control.title) complete state/rows/native parts match full move at\(value), companions\(companionValue)")
                        for (formatIndex, rate) in [44_100.0,48_000,96_000].enumerated() {
                            let format = try RenderProcessingFormat(sampleRate: rate, channels: 2, maximumFrames: 512)
                            let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: UInt64(index + 1))
                            var a = try fullMappers[formatIndex].lower(ListeningRenderAssignment(id: assignment.id, bundleIdentifier: assignment.target, isEnabled: expected.isEnabled, parts: expected.parts), format: format, token: token)
                            var b = try liveMappers[formatIndex].lower(delta.assignment, format: format, token: token)
                            let ap = withUnsafeBytes(of: &a.program) { Data($0) }, bp = withUnsafeBytes(of: &b.program) { Data($0) }
                            let af = withUnsafeBytes(of: &a.frame) { Data($0) }, bf = withUnsafeBytes(of: &b.frame) { Data($0) }
                            try check(a.signature == b.signature && ap == bp && af == bf, "\(control.title) exact signature/program/frame at\(rate)")
                        }
                    }
                    do {
                        _ = try plan.evaluate(.scalar(.infinity))
                        throw Failure.failed("invalid parameter accepted")
                    } catch SoundModelError.invalidPosition { }
                    try check(await livePort.writes == 0, "no live-tick persistence")
                    let final = try await live.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(1))
                    let finalFull = try await full.snapshot(), finalLive = try await live.snapshot()
                    try check(final.outcome != .superseded && !plan.lease.isValid && finalFull == finalLive, "one real final command matches full document and invalidates lease")
                    let a = try await full.checkpoint(), b = try await live.checkpoint()
                    let bytesA = await fullPort.data!, bytesB = await livePort.data!
                    let archiveA = try JSONDecoder().decode(LibraryArchive.self, from: bytesA), archiveB = try JSONDecoder().decode(LibraryArchive.self, from: bytesB)
                    let comparable = LibraryArchive(format: archiveB.format, schema: archiveB.schema, commit: archiveA.commit, provenance: archiveB.provenance,
                        revisions: archiveB.revisions, heads: archiveB.heads, uses: archiveB.uses, assignments: archiveB.assignments, enabled: archiveB.enabled, workspaces: archiveB.workspaces)
                    try check(a.token == archiveA.commit && b.token == archiveB.commit && a.digest == libraryDigest(bytesA) && b.digest == libraryDigest(bytesB)
                        && bytesA == (try archiveA.encoded(limits: limits)) && bytesB == (try archiveB.encoded(limits: limits)) && bytesA == (try comparable.encoded()), "real checkpoint bytes equal except independent commit UUID, each receipt/digest valid")
                    let reopened = try await SoundLibrarySession(persistence: livePort, limits: limits)
                    try check(try await reopened.snapshot() == full.snapshot(), "fresh reopen equals full final state")
                    let refreshed = try await live.menuState(), freshIdentity = refreshed.identity(for: binding)!
                    guard let stalePlan = refreshed.parameterPlans.first(where: { $0.identity == freshIdentity && $0.address == address && $0.option == option }) else { throw Failure.failed("fresh plan") }
                    let other = refreshed.assignments.first { $0.id != assignment.id }!
                    _ = try await live.nameUse(on: other.target, name: "Other app renamed")
                    try check(try stalePlan.evaluate(.scalar(0.2)) == nil, "external other-app metadata replacement refuses stale plan synchronously")
                }
            }
        }
        try check(controls.count == 13, "all13 shipped scalar plans")
        print("PARAMETER D1 \(evaluations) actual live evaluations; no App/audio/native runtime")
    }
}

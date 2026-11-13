import Foundation
@testable import SoundModel
import PlaybackRenderBridge
import FixedRender

private enum Failure: Error { case check(String) }
private func demand(_ value: Bool, _ message: String) throws {
    guard value else { throw Failure.check(message) }
    print("PASS \(message)")
}
private actor Memory: LibraryPersistence {
    var data: Data?
    var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func commit(_ data: Data) -> LibraryWriteOutcome { self.data = data; writes += 1; return .committed }
}

struct DirectDragModelChecks {
    static let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
    static func run() async throws {
        let port = Memory()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: port, limits: limits, builtins: .quickMenu) else {
            throw Failure.check("fresh quick menu")
        }
        for (name, target) in [("Everyday", "test.delta.everyday"), ("Filters", "test.delta.filters")] {
            let definition = try await seedOwner.snapshot().definitions.first { $0.name == name }!
            _ = try await seedOwner.select(definition.id, on: target)
        }
        _ = try await seedOwner.checkpoint()
        let seed = await port.data!
        let initial = try await seedOwner.snapshot()
        var qualified = 0, executions = 0, presetPrograms: Set<UInt32> = []
        for assignment in initial.assignments {
            let use = initial.uses.first { $0.id == assignment.use }!
            for control in use.controls {
                guard case .slider = control.face else { continue }
                let fullPort = Memory(seed), deltaPort = Memory(seed)
                let full = try await SoundLibrarySession(persistence: fullPort, limits: limits)
                let deltaOwner = try await SoundLibrarySession(persistence: deltaPort, limits: limits)
                let binding = LibraryBinding(assignment: assignment.id, use: use.id, target: assignment.target)
                let address = LibraryControlAddress(path: [], control: control.id)
                var option: LibraryOptionGesture?
                if let relation = use.optionControls.first(where: { $0.child == address }) {
                    let parent = use.controls.first { $0.id == relation.parent.control }!
                    guard case .choice(let options) = parent.face else { throw Failure.check("child parent") }
                    let choice = options.first { $0.id == relation.option }!
                    for owner in [full, deltaOwner] {
                        _ = try await owner.move(relation.parent, expected: binding, to: .scalar(choice.position))
                    }
                    option = LibraryOptionGesture(parent: relation.parent, option: relation.option)
                }
                var state = try await deltaOwner.menuState()
                let identity = state.identity(for: binding)!
                var fullMappers = [RenderAssignmentMapper(), RenderAssignmentMapper(), RenderAssignmentMapper()]
                var deltaMappers = fullMappers
                let values = [0.0, 0.2, 0.5, 0.8, 1.0, 0.499999, 0.500001, 0.999999, 1.0]
                for (index, value) in values.enumerated() {
                    // Exercise compensation combinations, not only one knob over neutral companions.
                    if index == 0 || index == 4 {
                        for companion in use.controls where companion.id != control.id {
                            guard case .slider = companion.face,
                                  !use.optionControls.contains(where: { $0.child.control == companion.id }) else { continue }
                            let otherAddress = LibraryControlAddress(path: [], control: companion.id)
                            for owner in [full, deltaOwner] {
                                _ = try await owner.move(otherAddress, expected: binding, to: .scalar(index == 0 ? 0 : 1))
                            }
                        }
                        state = try await deltaOwner.menuState()
                    }
                    let oldOutcome: LibraryLiveMutation
                    if let option { oldOutcome = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(value)) }
                    else { oldOutcome = try await full.move(address, expected: binding, to: .scalar(value)) }
                    let result = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(value))
                    guard case .delta(let delta) = result, let updated = state.applying(delta) else {
                        throw Failure.check("\(control.title) did not produce coherent delta")
                    }
                    state = updated; executions += 1
                    let reference = try await full.snapshot(), observed = try await deltaOwner.snapshot()
                    try demand(reference == observed && oldOutcome == result.outcome,
                        "D1 \(assignment.target)/\(control.title) \(value) exact full logical state/outcome")
                    let expectedUse = reference.uses.first { $0.id == use.id }!
                    let expectedAssignment = reference.assignments.first { $0.id == assignment.id }!
                    try demand(state.uses == reference.uses && state.assignments == reference.assignments
                        && state.isEnabled == reference.isEnabled && state.compareOriginal == reference.compareOriginal,
                        "D1 \(control.title) current presentation including other assignment")
                    try demand(delta.assignment.parts == expectedAssignment.parts && delta.occurrences == expectedUse.occurrences,
                        "D1 \(control.title) complete parts and every affected/hidden row")
                    for row in expectedUse.controls {
                        guard case .scalar(let expectedPosition) = expectedUse.positions[row.id],
                              case .scalar(let actualPosition) = delta.positions[LibraryControlAddress(path: [], control: row.id)] else { continue }
                        let expectedText = try row.readout?.text(at: expectedPosition), actualText = try row.readout?.text(at: actualPosition)
                        try demand(expectedPosition == actualPosition && expectedText == actualText,
                            "D1 \(control.title) row/readout \(row.title)")
                    }
                    for (formatIndex, rate) in [44_100.0, 48_000, 96_000].enumerated() {
                        let format = try RenderProcessingFormat(sampleRate: rate, channels: 2, maximumFrames: 512)
                        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: UInt64(index + 1))
                        var a = try fullMappers[formatIndex].lower(ListeningRenderAssignment(id: assignment.id,
                            bundleIdentifier: assignment.target, isEnabled: expectedAssignment.isEnabled,
                            parts: expectedAssignment.parts), format: format, token: token)
                        var b = try deltaMappers[formatIndex].lower(delta.assignment, format: format, token: token)
                        let programA = withUnsafeBytes(of: &a.program) { Data($0) }, programB = withUnsafeBytes(of: &b.program) { Data($0) }
                        let frameA = withUnsafeBytes(of: &a.frame) { Data($0) }, frameB = withUnsafeBytes(of: &b.frame) { Data($0) }
                        try demand(a.signature == b.signature && programA == programB && frameA == frameB,
                            "D1 \(control.title) \(value) \(rate) exact signature/program/frame bytes")
                        if assignment.target.hasSuffix("filters"), control.title == "Room size" {
                            presetPrograms.formUnion(b.signature.map(\.preset))
                        }
                    }
                }
                let unchangedFull: LibraryLiveMutation
                if let option { unchangedFull = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(1)) }
                else { unchangedFull = try await full.move(address, expected: binding, to: .scalar(1)) }
                let unchanged = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(1))
                guard case .delta(let unchangedDelta) = unchanged, let unchangedState = state.applying(unchangedDelta) else {
                    throw Failure.check("no-change delta refused")
                }
                state = unchangedState; executions += 1
                let unchangedReference = try await full.snapshot(), unchangedObserved = try await deltaOwner.snapshot()
                try demand(unchangedFull == .noChange && unchanged.outcome == .noChange
                    && unchangedReference == unchangedObserved && unchangedDelta.assignment.parts == unchangedReference.assignments.first { $0.id == assignment.id }!.parts,
                    "D1 exact no-change outcome and complete native parts")
                let fullWrites = await fullPort.writes, deltaWrites = await deltaPort.writes
                try demand(fullWrites == 0 && deltaWrites == 0, "D1 \(control.title) no move writes")
                let beforeInvalid = try await deltaOwner.snapshot()
                do {
                    _ = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(.infinity))
                    throw Failure.check("invalid proposed value accepted")
                } catch SoundModelError.invalidPosition { }
                try demand(try await deltaOwner.snapshot() == beforeInvalid, "D1 invalid proposed value atomic")
                let wrongOwner = LibraryMenuIdentity(ownerID: UUID(), binding: binding, reference: identity.reference)
                try demand(try await deltaOwner.moveForMenu(address, expected: wrongOwner, optionGesture: option, to: .scalar(0.3)) == .superseded,
                    "D1 stale owner refuses without replay")
                await full.setEnabled(true); await deltaOwner.setEnabled(true)
                let afterPower = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(0.3))
                if let option { _ = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(0.3)) }
                else { _ = try await full.move(address, expected: binding, to: .scalar(0.3)) }
                guard case .delta(let powerDelta) = afterPower else { throw Failure.check("power context move") }
                try demand(state.applying(powerDelta) == nil, "D1 changed OFF context refuses old presentation base")
                await full.setEnabled(false); await deltaOwner.setEnabled(false)
                state = try await deltaOwner.menuState()
                let other = state.assignments.first { $0.id != assignment.id }!
                let otherUse = state.uses.first { $0.id == other.use }!
                let otherControl = otherUse.controls.first { control in
                    if case .slider = control.face { return !otherUse.optionControls.contains { $0.child.control == control.id } }
                    return false
                }!
                let otherBinding = LibraryBinding(assignment: other.id, use: other.use, target: other.target)
                let otherAddress = LibraryControlAddress(path: [], control: otherControl.id)
                for owner in [full, deltaOwner] { _ = try await owner.move(otherAddress, expected: otherBinding, to: .scalar(0.1)) }
                let interleaved = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(0.8))
                guard case .delta(let gap) = interleaved else { throw Failure.check("interleaved generation") }
                try demand(state.applying(gap) == nil && gap.baseGeneration > state.liveGeneration,
                    "D1 other-app public mutation refuses incomplete merge across generation gap")
                if let option { _ = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(0.8)) }
                else { _ = try await full.move(address, expected: binding, to: .scalar(0.8)) }
                let reconciled = try await deltaOwner.snapshot(), expectedReconciled = try await full.snapshot()
                try demand(reconciled == expectedReconciled, "D1 full reconciliation retains other app without replaying drag")
                state = try await deltaOwner.menuState()
                _ = try await full.nameUse(on: binding.target, name: "Renamed test use")
                _ = try await deltaOwner.nameUse(on: binding.target, name: "Renamed test use")
                let renamedMove = try await deltaOwner.moveForMenu(address, expected: identity, optionGesture: option, to: .scalar(0.2))
                guard case .delta(let renamedDelta) = renamedMove else { throw Failure.check("renamed use move") }
                try demand(state.applying(renamedDelta) == nil,
                    "D1 same-live-generation committed metadata change refuses stale presentation merge")
                if let option { _ = try await full.move(address, expected: binding, optionGesture: option, to: .scalar(0.2)) }
                else { _ = try await full.move(address, expected: binding, to: .scalar(0.2)) }
                let a = try await full.checkpoint(), b = try await deltaOwner.checkpoint()
                let bytesA = await fullPort.data!, bytesB = await deltaPort.data!
                let archiveA = try JSONDecoder().decode(LibraryArchive.self, from: bytesA)
                let archiveB = try JSONDecoder().decode(LibraryArchive.self, from: bytesB)
                let comparable = LibraryArchive(format: archiveB.format, schema: archiveB.schema, commit: archiveA.commit,
                    provenance: archiveB.provenance, revisions: archiveB.revisions, heads: archiveB.heads, uses: archiveB.uses,
                    assignments: archiveB.assignments, enabled: archiveB.enabled, workspaces: archiveB.workspaces)
                let encodedA = try archiveA.encoded(limits: limits), encodedB = try archiveB.encoded(limits: limits)
                let comparableBytes = try comparable.encoded()
                try demand(archiveA.commit == a.token && archiveB.commit == b.token && a.digest == libraryDigest(bytesA)
                    && b.digest == libraryDigest(bytesB) && bytesA == encodedA
                    && bytesB == encodedB && encodedA == comparableBytes,
                    "D1 \(control.title) independently valid exact receipts/bytes; only commit identity differs")
                let reopenedA = try await SoundLibrarySession(persistence: fullPort, limits: limits)
                let reopenedB = try await SoundLibrarySession(persistence: deltaPort, limits: limits)
                let restoredA = try await reopenedA.snapshot(), restoredB = try await reopenedB.snapshot()
                try demand(restoredA == restoredB, "D1 \(control.title) fresh reopen full equality")
                qualified += 1
            }
        }
        try demand(qualified == 13 && presetPrograms.isSuperset(of: [1, 2, 3]), "D1 all13 plus actual Filters preset programs1/2/3")
        print("D1 model differential: \(qualified) controls, \(executions) actual delta executions; no App/audio/device runtime")
    }
}

import Foundation
import AppKit
import Combine
@testable import SoundModel
@testable import EverydayMenu
import PlaybackRenderBridge
@testable import PlaybackOutput
@testable import tap_n_filter

private enum Failure: Error { case check(String) }
private func demand(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure.check(message) }
    print("PASS \(message)")
}
private actor Port: LibraryPersistence {
    var data: Data?
    var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    var hold = false
    private var held: CheckedContinuation<Void, Never>?
    private var entrants: [CheckedContinuation<Void, Never>] = []
    func arm() { hold = true }
    func entered() async { if held == nil { await withCheckedContinuation { entrants.append($0) } } }
    func release() { held?.resume(); held = nil }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        writes += 1
        if hold {
            hold = false
            await withCheckedContinuation { continuation in held = continuation; for entrant in entrants { entrant.resume() }; entrants = [] }
        }
        self.data = data; return .committed
    }
}
private actor Reads {
    var count = 0
    var owner: SoundLibrarySession?
    func read(_ owner: SoundLibrarySession) async throws -> LibraryMenuState {
        self.owner = owner; count += 1; return try await owner.menuState()
    }
}
@MainActor private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { waiter = $0; for observer in observers { observer.resume() }; observers.removeAll() }
    }
    func entered() async { if waiter == nil { await withCheckedContinuation { observers.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}
@MainActor private final class Surface {
    weak var app: LibraryAppSession?
    var view: MenuPresentation?
    var actions: [EverydayMenuAction] = []
    weak var selectedEditor: TNFEditorCommands?
    var fullChanges = 0
    func full() {
        fullChanges += 1
        guard let app, let presentation = app.presentation, let data = app.menuData else { return }
        if view == nil { view = MenuPresentation(presentation: presentation, glyph: NSImage(size: NSSize(width: 1, height: 1)), perform: { [weak self] in self?.actions.append($0); self?.app?.send($0) }) }
        view?.positionContext = app.coordinator.positionContext
        if view?.snapshot != data { view?.snapshot = data }
        selectedEditor?.receiveOwnerChange()
    }
    func positions(_ delta: LibraryMenuDelta, _ context: MenuPositionContext) -> Bool {
        view?.applyPositions(delta, context: context) ?? false
    }
}
@MainActor private struct Fixture {
    let app: LibraryAppSession
    let surface: Surface
    let reads: Reads
    let port: Port
    let owner: SoundLibrarySession
    init(menuMove: LibraryListeningCoordinator.MenuMove? = nil) async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = Port()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else { throw Failure.check("seed") }
        let definitions = try await seedOwner.snapshot().definitions
        _ = try await seedOwner.select(definitions.first { $0.name == "Everyday" }!.id, on: "com.apple.Safari")
        _ = try await seedOwner.select(definitions.first { $0.name == "Filters" }!.id, on: "test.other")
        _ = try await seedOwner.checkpoint()
        let port = Port(await seed.data), reads = Reads(), surface = Surface()
        let app = LibraryAppSession(changed: { surface.full() },
            contextChanged: { surface.view?.installPositionContext($0) }, positionsChanged: { surface.positions($0, $1) }, read: { try await reads.read($0) }, menuMove: menuMove)
        surface.app = app
        await app.start(persistence: port, limits: limits)
        self.app = app; self.surface = surface; self.reads = reads; self.port = port
        owner = await reads.owner!
    }
    func card(_ target: String = "com.apple.Safari") -> MenuSoundCard { app.menuData!.assignments.first { $0.bundleIdentifier == target }! }
    func slider(_ title: String = "Softer", target: String = "com.apple.Safari") -> MenuSoundControl {
        let card = card(target)
        return (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.title == title }!
    }
    func move(_ control: MenuSoundControl, card: MenuSoundCard, to value: Double, gestureIdentity: UUID? = nil) throws -> Task<LibrarySliderResult, Error> {
        try app.coordinator.submitSliderMove(control.address, expected: card.binding!, to: .scalar(value),
            optionGesture: control.optionGesture, menuIdentity: card.menuIdentity, expectedEpoch: card.menuEpoch, gestureIdentity: gestureIdentity)
    }
}

struct DirectDragAppChecks {
    @MainActor static func run() async throws {
        try await rowsAndRelease()
        try await parameterBarriers()
        try await externalRevisions()
        try await childParentBarrier()
        try await optionRowObservation()
        try await heldWrite()
        try await producerHeldWrite()
        try await choiceDuringCheckpoint()
        try await editorReadAdmission(automatic: true)
        try await editorReadAdmission(automatic: false)
        try await controllerStartingOff()
        try controllerPolicy()
        try controllerStopResumePolicy()
        try await controllerAsyncLifecycle()
        print("PASS direct-drag coordinator/row/controller pure fakes; no native App/window/audio/device path")
    }
    @MainActor static func rowsAndRelease() async throws {
        let f = try await Fixture(), app = f.app
        var controls = 0
        for assignment in app.presentation!.assignments {
            let use = app.presentation!.uses.first { $0.id == assignment.use }!
            for metadata in use.controls {
                guard case .slider = metadata.face else { continue }
                if let relation = use.optionControls.first(where: { $0.child.control == metadata.id }) {
                    let parent = use.controls.first { $0.id == relation.parent.control }!
                    guard case .choice(let options) = parent.face else { throw Failure.check("choice") }
                    _ = try await f.owner.move(relation.parent, expected: f.card(assignment.target).binding!,
                        to: .scalar(options.first { $0.id == relation.option }!.position))
                    await app.coordinator.refresh(mode: .positions)
                }
                _ = await app.flushSave()?.value
                let reference = try await SoundLibrarySession(persistence: Port(await f.port.data), limits: LibraryAppSession.normalLimits())
                let beforeDocument = try await f.owner.snapshot()
                var evaluations = 0, documents = 0
                app.coordinator.perfParameterEvaluated = { _, _ in evaluations += 1 }
                app.coordinator.perfParameterDocumentCommit = { _ in documents += 1 }
                let card = f.card(assignment.target)
                let control = f.slider(metadata.title, target: assignment.target)
                let view = f.surface.view!, row = view.rowPosition(control, on: card)
                let identity = ObjectIdentifier(row), folds = view.folds.entries, more = view.more
                var global = 0, resized = 0
                let token = view.objectWillChange.sink { global += 1 }
                view.resize = { resized += 1 }
                let reads = await f.reads.count, writes = await f.port.writes
                app.send(.beginGesture)
                for value in [0.0, 0.2, 0.5, 0.8, 1] {
                    let result = try await f.move(control, card: card, to: value).value
                    guard case .live = result else { throw Failure.check("\(metadata.title) not delivered") }
                    if let option = control.optionGesture {
                        _ = try await reference.move(control.address, expected: card.binding!, optionGesture: option, to: .scalar(value))
                    } else { _ = try await reference.move(control.address, expected: card.binding!, to: .scalar(value)) }
                    let expected = try await reference.snapshot(), document = try await f.owner.snapshot()
                    try demand(app.presentation!.uses == expected.uses && app.presentation!.assignments == expected.assignments
                        && row.value == value && document == beforeDocument && app.presentation!.transientPosition == control.address,
                        "parameter UI \(metadata.title) \(value) full model parity, document deliberately unchanged")
                    try demand(ObjectIdentifier(view.rowPosition(control, on: card)) == identity
                        && global == 0 && resized == 0 && folds == view.folds.entries && more == view.more,
                        "D3 \(metadata.title) stable row/no global publication/resize/fold pass")
                }
                token.cancel()
                let afterReads = await f.reads.count, afterWrites = await f.port.writes
                try demand(reads == afterReads && writes == afterWrites && evaluations == 5 && documents == 0, "D1 \(metadata.title) zero drag full reads/writes")
                app.send(.endGesture)
                guard let save = app.gestureSave else { throw Failure.check("release task") }
                let receipt = await save.value
                guard case .accepted = receipt.outcome else { throw Failure.check("release save") }
                let releaseReads = await f.reads.count, releaseWrites = await f.port.writes
                try demand(releaseReads == reads + 1 && releaseWrites == writes + 1 && documents == 1 && app.presentation!.transientPosition == nil,
                    "D1 \(metadata.title) one joined release read and one actual save")
                controls += 1
            }
        }
        try demand(controls == 13, "D1 all13 actual consumer controls use precomputed parameters, including stepped preset")
        app.close()
    }
    @MainActor static func parameterBarriers() async throws {
        for barrier in ["OFF", "compare", "source-format", "query", "None", "drain"] {
            let f = try await Fixture(), app = f.app, card = f.card(), control = f.slider()
            var documents = 0
            app.coordinator.perfParameterDocumentCommit = { _ in documents += 1 }
            app.send(.beginGesture)
            guard case .live = try await f.move(control, card: card, to: 0.9).value else { throw Failure.check("live before boundary") }
            let late = card.movement(for: control, to: 0.1)!
            switch barrier {
            case "OFF": _ = try await app.coordinator.submitEnabled(false).value
            case "compare": _ = try await app.coordinator.submitCompare(true).value
            case "source-format":
                app.coordinator.playbackDidChange()
                _ = try await app.coordinator.editorQuery { try await $0.snapshot() }
            case "query": _ = try await app.coordinator.editorQuery { try await $0.snapshot() }
            case "None": _ = await app.coordinator.submitSelect(nil, on: card.bundleIdentifier).value
            default:
                app.beginDrain()
                guard case .saved = await app.finishDrain(.save) else { throw Failure.check("drain") }
            }
            let current = try await f.owner.snapshot()
            try demand(current.uses.first { $0.id == card.binding!.use }!.positions[control.id] == .scalar(0.9) && documents == 1,
                "\(barrier) flushes latest through one real command before boundary")
            app.send(late)
            let after = try await f.owner.snapshot()
            try demand(after == current, "\(barrier) stale rendered callback cannot replay old graph")
            if barrier != "drain" { app.beginDrain(); _ = await app.finishDrain(.save) }
            app.close()
        }
    }
    @MainActor static func externalRevisions() async throws {
        for metadata in [false, true] {
            let f = try await Fixture(), app = f.app, card = f.card(), control = f.slider()
            app.send(.beginGesture)
            _ = try await f.move(control, card: card, to: 0.4).value
            let other = f.card("test.other"), otherControl = f.slider("Volume", target: "test.other")
            if metadata { _ = try await f.owner.nameUse(on: "test.other", name: "External name") }
            else { _ = try await f.owner.move(otherControl.address, expected: other.binding!, to: .scalar(0.1)) }
            _ = try await f.move(control, card: card, to: 0.9).value
            let current = try await f.owner.snapshot()
            try demand(current.uses.first { $0.id == card.binding!.use }!.positions[control.id] == .scalar(0.9),
                "external revision commits latest without evaluating stale plan")
            try demand(metadata ? current.uses.first { $0.id == other.binding!.use }!.name == "External name"
                : current.uses.first { $0.id == other.binding!.use }!.positions[otherControl.id] == .scalar(0.1),
                "external other-app position/metadata survives final real command")
            app.send(.endGesture); _ = await app.gestureSave?.value
            app.close()
        }
    }
    @MainActor static func childParentBarrier() async throws {
        let f = try await Fixture(), app = f.app
        for relation in app.presentation!.uses.first(where: { $0.target == "com.apple.Safari" })!.optionControls {
            let metadata = app.presentation!.uses.first { $0.target == "com.apple.Safari" }!
            let parent = metadata.controls.first { $0.id == relation.parent.control }!
            guard case .choice(let options) = parent.face else { throw Failure.check("parent") }
            _ = try await f.owner.move(relation.parent, expected: f.card().binding!, to: .scalar(options.first { $0.id == relation.option }!.position))
            _ = await app.flushSave()?.value
            let card = f.card(), child = (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.address == relation.child }!
            app.send(.beginGesture)
            guard case .live = try await f.move(child, card: card, to: 0.9).value else { throw Failure.check("child live") }
            let other = options.first { $0.id != relation.option }!
            _ = try await app.coordinator.submitMenuMove(relation.parent, expected: card.menuIdentity!, to: .scalar(other.position),
                optionGesture: nil, expectedEpoch: card.menuEpoch).value
            let snapshot = try await f.owner.snapshot()
            try demand(snapshot.uses.first { $0.id == card.binding!.use }!.positions[child.id] == .scalar(0.9), "child latest committed before parent option switch")
            _ = try await f.move(child, card: card, to: 0.1).value
            let after = try await f.owner.snapshot()
            try demand(after == snapshot, "stale child option callback refuses after parent boundary")
            app.send(.endGesture); _ = await app.gestureSave?.value
        }
        app.close()
    }
    @MainActor static func optionRowObservation() async throws {
        let f = try await Fixture(), app = f.app
        let initial = try await f.owner.snapshot(), binding = f.card().binding!
        let use = initial.uses.first { $0.id == binding.use }!, relation = use.optionControls.first!
        let parent = use.controls.first { $0.id == relation.parent.control }!
        guard case .choice(let options) = parent.face else { throw Failure.check("parent choice") }
        _ = try await f.owner.move(relation.parent, expected: binding, to: .scalar(options.first { $0.id == relation.option }!.position))
        await app.coordinator.refresh(mode: .positions)
        _ = await app.flushSave()?.value
        let card = f.card()
        guard let tab = card.optionTabs.first, let child = tab.controls.first else { throw Failure.check("active option child") }
        let view = f.surface.view!
        let row = MenuOptionControlRow(state: view, assignment: card, tab: tab, control: child, index: 0)
        let old = child.position, value = old == 0.8 ? 0.2 : 0.8
        var global = 0
        let observation = view.objectWillChange.sink { global += 1 }
        app.send(.beginGesture)
        guard case .live = try await f.move(child, card: card, to: value).value else { throw Failure.check("child live") }
        let actual = row.position, text = row.readout, updates = global
        let expected = (try? child.readout?.text(at: value)) ?? "\(Int((value * 100).rounded()))%"
        app.send(.endGesture); _ = await app.gestureSave?.value
        observation.cancel(); app.close()
        try demand(actual == value && text == expected && updates == 0,
            "visible option child row and readout observe live patch without global publication")
    }
    @MainActor static func heldWrite() async throws {
        let f = try await Fixture(), app = f.app, card = f.card(), control = f.slider(), view = f.surface.view!
        view.beginGesture()
        guard case .beginMenuGesture(let oldIdentity) = f.surface.actions.last else { throw Failure.check("actual menu gesture identity") }
        _ = try await f.move(control, card: card, to: 0.6, gestureIdentity: oldIdentity).value
        let oldCallback = EverydayMenuAction.gestureMove(oldIdentity, card.menuIdentity!, card.menuEpoch!, control.address, control.optionGesture, .scalar(0.1))
        await f.port.arm()
        view.endGesture()
        await f.port.entered()
        let first = app.gestureSave!
        let retired = try await f.move(control, card: card, to: 0.1, gestureIdentity: oldIdentity).value
        guard case .executed(.superseded) = retired else { throw Failure.check("retired checkpoint callback admitted") }
        view.beginGesture()
        guard case .beginMenuGesture(let freshIdentity) = f.surface.actions.last, freshIdentity != oldIdentity else { throw Failure.check("distinct fresh gesture identity") }
        _ = try await f.move(control, card: f.card(), to: 0.9, gestureIdentity: freshIdentity).value
        app.send(oldCallback)
        _ = try await app.coordinator.editorQuery { try await $0.snapshot() }
        view.endGesture()
        let second = app.gestureSave!
        await f.port.release()
        _ = await first.value; _ = await second.value
        let reopened = try await SoundLibrarySession(persistence: Port(await f.port.data), limits: LibraryAppSession.normalLimits())
        try demand(try await reopened.snapshot().uses.first { $0.id == card.binding!.use }!.positions[control.id] == .scalar(0.9),
            "OLD callback AFTER fresh begin/newer move cannot overwrite saved/reopened0.9; fresh gesture remains usable")
        app.close()
    }
    @MainActor static func producerHeldWrite() async throws {
        let f = try await Fixture(), app = f.app, card = f.card(), control = f.slider(), view = f.surface.view!
        let oldChange: (Double) -> Void = { value in view.move(control, on: card, to: value) }
        let oldGesture = view.beginMovement(control, on: card)
        oldChange(0.6)
        await f.port.arm(); view.endGesture(); await f.port.entered()
        let first = app.gestureSave!
        let newerCard = f.card()
        let freshGesture = view.beginMovement(control, on: newerCard)
        let newerChange = freshGesture.change
        func apply(_ change: @escaping (Double) -> Void, _ value: Double) async -> LibraryLiveMutation {
            await withCheckedContinuation { continuation in
                app.perfMutationCompleted = { outcome in app.perfMutationCompleted = nil; continuation.resume(returning: outcome) }
                change(value)
            }
        }
        try demand(await apply(newerChange, 0.9) != .superseded, "actual fresh producer remains usable during held checkpoint")
        try demand(await apply(oldChange, 0.1) == .superseded, "retained untracked rendered-row closure cannot borrow new gesture UUID")
        try demand(await apply(oldGesture.change, 0.2) == .superseded, "retained actual gesture change keeps its retired begin-time identity")
        oldGesture.end()
        try demand(app.gestureSave == nil, "late old gesture end cannot end/checkpoint fresh gesture")
        try demand(await apply(newerChange, 0.8) != .superseded, "fresh producer still accepts changes after old end")
        _ = await apply(newerChange, 0.9)
        freshGesture.end(); let second = app.gestureSave!
        await f.port.release(); _ = await first.value; _ = await second.value
        let reopened = try await SoundLibrarySession(persistence: Port(await f.port.data), limits: LibraryAppSession.normalLimits())
        let value = try await reopened.snapshot().uses.first { $0.id == card.binding!.use }!.positions[control.id]
        print("PRODUCER reopened=\(String(describing: value)) expected=scalar0.9")
        try demand(value == .scalar(0.9), "retained actual row producer after fresh begin/newer move preserves saved/reopened0.9")
        app.close()
    }
    @MainActor static func choiceDuringCheckpoint() async throws {
        let f = try await Fixture(), app = f.app, card = f.card(), control = f.slider(), view = f.surface.view!
        let drag = view.beginMovement(control, on: card); drag.change(0.6)
        await f.port.arm(); drag.end(); await f.port.entered()
        let first = app.gestureSave!
        let parent = card.controls.first { if case .choice = $0.face { return true }; return false }!
        guard case .choice(let options) = parent.face else { throw Failure.check("choice") }
        let choice = options.first { $0.id != card.effectiveOption(parent)?.id }!
        let outcome: LibraryLiveMutation = await withCheckedContinuation { continuation in
            app.perfMutationCompleted = { result in app.perfMutationCompleted = nil; continuation.resume(returning: result) }
            view.activate(choice, control: parent, on: card)
        }
        print("CHOICE held checkpoint outcome=\(outcome)")
        await f.port.release(); _ = await first.value; _ = await app.flushSave()?.value
        let reopened = try await SoundLibrarySession(persistence: Port(await f.port.data), limits: LibraryAppSession.normalLimits())
        let value = try await reopened.snapshot().uses.first { $0.id == card.binding!.use }!.positions[parent.id]
        try demand(outcome != .superseded && value == .scalar(choice.position), "actual fresh choice click survives held slider checkpoint and fresh reopen")
        app.close()
    }
    @MainActor static func editorReadAdmission(automatic: Bool) async throws {
        let f = try await Fixture(), app = f.app
        let commands = TNFEditorCommands(app: app)
        try await commands.select(.use(f.card().binding!))
        try demand(commands.projection != nil, "actual selected editor projection installed")
        if automatic {
            let gate = Gate()
            var observed = false
            let subscription = commands.$projection.dropFirst().sink { value in
                if value != nil { observed = true; gate.release() }
            }
            f.surface.selectedEditor = commands
            await app.coordinator.refresh(mode: .positions)
            if !observed { await gate.wait() }
            subscription.cancel()
            let publications = f.surface.fullChanges
            try await commands.refresh(); try await commands.refresh()
            try demand(f.surface.fullChanges == publications, "read-only selected editor mappings do not feed back owner publication/query")
        } else {
            await app.coordinator.refresh(mode: .positions)
            app.editor.requestDisplay(); await app.editor.displaySettled()
        }
        let card = f.card(), control = f.slider(), gesture = f.surface.view!.beginMovement(control, on: card)
        let result = try await f.move(control, card: card, to: 0.9,
            gestureIdentity: f.surface.actions.compactMap { if case .beginMenuGesture(let id) = $0 { return id }; return nil }.last).value
        print("EDITOR automatic=\(automatic) contextPresent=\(app.coordinator.positionContext != nil) result=\(result)")
        let admitted: Bool
        switch result { case .executed(.superseded), .fenced(.superseded): admitted = false; default: admitted = true }
        f.surface.selectedEditor = nil
        gesture.end(); _ = await app.gestureSave?.value
        try demand(admitted, "selected editor read barrier restores fresh menu admission")
        app.close()
    }
    @MainActor static func controllerStopResumePolicy() throws {
        func state(_ id: UUID?, enabled: Bool = true, bundle: String = "test.resume") -> ListeningRenderSnapshot {
            ListeningRenderSnapshot(isEnabled: enabled, assignments: id.map {
                [ListeningRenderAssignment(id: $0, bundleIdentifier: bundle, isEnabled: true, parts: [])]
            } ?? [])
        }
        let a = UUID(), b = UUID(), c = UUID()
        var policy = PlaybackStopResumePolicy()
        policy.activate(state(a))
        let positionsStop = policy.stopping(assignment: a, includesCurrentActivation: false)
        var resumed = 0
        func complete(_ stop: PlaybackStopResumePolicy.Stop, _ desired: ListeningRenderSnapshot) {
            if policy.mayResume(stop, desired: desired) { resumed += 1 }
        }
        complete(positionsStop, state(b))
        try demand(resumed == 0, "actual stop-resume policy: positions removal cannot activate replacement B")
        policy.activate(state(a))
        complete(positionsStop, state(a))
        try demand(resumed == 1, "actual stop-resume policy: later explicit activation authorizes held-stop restart")
        complete(positionsStop, state(c))
        try demand(resumed == 1, "actual stop-resume policy: later activation A cannot authorize positions-only replacement C")
        let activationStop = policy.stopping(assignment: a, includesCurrentActivation: true)
        complete(activationStop, state(c))
        try demand(resumed == 1, "actual stop-resume policy: original activation cannot replay a different positions-only scope")
        complete(activationStop, state(a))
        try demand(resumed == 2, "actual stop-resume policy: unchanged explicit activation scope retains restart")
        complete(positionsStop, state(b, enabled: false))
        complete(positionsStop, state(nil))
        complete(positionsStop, state(b, bundle: "test.other-source"))
        try demand(resumed == 2, "actual stop-resume policy: OFF/removal/source replacement never starts")
    }
    @MainActor static func controllerPolicy() throws {
        let id = UUID(), part = ListeningRenderPart(id: UUID(), path: [], type: "gain", parameters: [ListeningParameter(key: "gainDb", value: -3)])
        let assignment = ListeningRenderAssignment(id: id, bundleIdentifier: "test.policy", isEnabled: true, parts: [part])
        let on = ListeningRenderSnapshot(isEnabled: true, assignments: [assignment])
        var updates = 0, stops = 0
        let inactive = PlaybackPositionDelivery(snapshot: on, running: [], known: [id: "test.policy"])
        try demand(inactive.apply(update: { _ in updates += 1 }, stop: { _ in stops += 1 }) == .retainedInactive
            && updates == 0 && stops == 0, "D1 inactive delta/full fallback has zero factory/start/retry activity")
        let active = PlaybackPositionDelivery(snapshot: on, running: [id], known: [id: "test.policy"])
        try demand(active.apply(update: { try demand($0 == assignment, "D1 active complete assignment unchanged"); updates += 1 }, stop: { _ in stops += 1 }) == .applied
            && updates == 1 && stops == 0, "D1 active lane uses existing complete update, no activation capability")
        let off = PlaybackPositionDelivery(snapshot: ListeningRenderSnapshot(isEnabled: false, assignments: [assignment]), running: [id], known: [id: "test.policy"])
        _ = off.apply(update: { _ in updates += 1 }, stop: { _ in stops += 1 })
        try demand(updates == 1 && stops == 1, "D1 OFF stops/restricts without applying ON parts or starting")
        let stale = PlaybackPositionDelivery(snapshot: on, running: [id], known: [id: "test.new-source"])
        try demand(stale.apply(update: { _ in updates += 1 }, stop: { _ in stops += 1 }) == .requiresFull && updates == 1,
            "D1 stale source identity cannot update old lane")
    }
}

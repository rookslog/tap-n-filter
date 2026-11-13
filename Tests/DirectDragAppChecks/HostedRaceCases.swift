import Foundation
import AppKit
import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

// PR #39 race checks: editor read counts after read failures, and menu clicks or drags that land
// while an editor read or a release save is in flight.
// Ordering is by gates and completion signals only. The one Task.sleep in this file is inside the
// labelled legacy-predicate demonstration in R15-A, which reproduces Main.swift's check unchanged;
// it orders nothing (the edit-read gate is what holds trigger 2).

private enum HostedError: Error { case setup(String) }

@MainActor private final class HostedSignal {
    private(set) var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func send() { count += 1; let ready = waiters.filter { count >= $0.0 }; waiters.removeAll { count >= $0.0 }; for item in ready { item.1.resume() } }
    func wait(_ value: Int) async { if count < value { await withCheckedContinuation { waiters.append((value, $0)) } } }
}
private actor HostedGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var arrivals = 0
    func pause() async {
        await withCheckedContinuation { continuations.append($0); arrivals += 1
            let ready = observers.filter { arrivals > $0.0 }; observers.removeAll { arrivals > $0.0 }; for o in ready { o.1.resume() }
        }
    }
    func entered(after count: Int = 0) async { if arrivals <= count { await withCheckedContinuation { observers.append((count, $0)) } } }
    func release() { let current = continuations; continuations = []; for c in current { c.resume() } }
}
/// Single-shot hold: the first call after `arm()` parks at `gate`.
private actor HostedArmedGate {
    private var armed = false
    let gate = HostedGate()
    func arm() { armed = true }
    func pauseIfArmed() async { if armed { armed = false; await gate.pause() } }
}
private actor HostedPort: LibraryPersistence {
    var bytes: Data?
    var writes = 0
    var held = false
    let gate = HostedGate()
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func load() -> Data? { bytes }
    /// Single-shot: the next write parks at `gate` until released.
    func arm() { held = true }
    func commit(_ value: Data) async -> LibraryWriteOutcome {
        writes += 1
        if held { held = false; await gate.pause() }
        bytes = value; return .committed
    }
}

// MARK: - R15 fixture (same construction as Main.swift Fixture, plus an edit-read gate and an atomic counter sample)

private actor HostedCountingReads {
    private(set) var count = 0
    private(set) var owner: SoundLibrarySession?
    private var errors: [String] = []
    private(set) var injectedFailures = 0
    func armFailures(_ messages: [String]) { errors = messages; injectedFailures = 0 }
    func read(_ owner: SoundLibrarySession) async throws -> LibraryMenuState {
        self.owner = owner; count += 1
        if !errors.isEmpty { injectedFailures += 1; throw HostedError.setup(errors.removeFirst()) }
        return try await owner.menuState()
    }
    /// Both counters in one actor turn, so no read can start between them.
    func sample() -> (reads: Int, injected: Int) { (count, injectedFailures) }
}
@MainActor private final class HostedSurface {
    weak var app: LibraryAppSession?
    var view: MenuPresentation?
    var actions: [EverydayMenuAction] = []
    weak var selectedEditor: TNFEditorCommands?
    var fullChanges = 0
    var attentionChanges = 0
    var observedProblems: [String?] = []
    /// Fires on every attention or full notification, so a wait never hangs on the "wrong" kind.
    let notified = HostedSignal()
    func attention() {
        attentionChanges += 1
        observedProblems.append(app?.problem)
        view?.problem = app?.problem == nil ? nil : "Audio Needs Attention…"
        notified.send()
    }
    func full() {
        fullChanges += 1
        defer { notified.send() }
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
@MainActor private struct HostedReadFixture {
    let app: LibraryAppSession
    let surface: HostedSurface
    let reads: HostedCountingReads
    let port: HostedPort
    let editGate: HostedArmedGate
    init() async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = HostedPort()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else { throw HostedError.setup("seed") }
        let definitions = try await seedOwner.snapshot().definitions
        _ = try await seedOwner.select(definitions.first { $0.name == "Everyday" }!.id, on: "com.apple.Safari")
        _ = try await seedOwner.select(definitions.first { $0.name == "Filters" }!.id, on: "test.other")
        _ = try await seedOwner.checkpoint()
        let port = HostedPort(await seed.bytes), reads = HostedCountingReads(), surface = HostedSurface(), editGate = HostedArmedGate()
        let app = LibraryAppSession(changed: { surface.full() }, attentionChanged: { surface.attention() },
            contextChanged: { surface.view?.installPositionContext($0) }, positionsChanged: { surface.positions($0, $1) },
            read: { try await reads.read($0) },
            editRead: { [editGate] owner, handle in await editGate.pauseIfArmed(); return try await owner.inspectEdit(handle) })
        surface.app = app
        await app.start(persistence: port, limits: limits)
        self.app = app; self.surface = surface; self.reads = reads; self.port = port; self.editGate = editGate
    }
    func card(_ target: String = "com.apple.Safari") -> MenuSoundCard { app.menuData!.assignments.first { $0.bundleIdentifier == target }! }
    func slider(_ title: String = "Softer", target: String = "com.apple.Safari") -> MenuSoundControl {
        let card = card(target)
        return (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.title == title }!
    }
}

// MARK: - R26 fixture (same construction as RaceCases.swift RaceFixture)

private actor HostedHeldReads {
    var owner: SoundLibrarySession?
    var hold = false
    let gate = HostedGate()
    func arm() { hold = true }
    func read(_ owner: SoundLibrarySession) async throws -> LibraryMenuState {
        self.owner = owner
        if hold { hold = false; await gate.pause() }
        return try await owner.menuState()
    }
}
@MainActor private final class HostedReply {
    var result: String?
    let signal = HostedSignal()
    func finish(_ value: String) { guard result == nil else { return }; result = value; signal.send() }
    func value() async -> String { await signal.wait(1); return result! }
}
@MainActor private final class HostedMenuFixture {
    var app: LibraryAppSession!
    var view: MenuPresentation!
    var actions: [EverydayMenuAction] = []
    let reads = HostedHeldReads(), delay = HostedGate()
    var port: HostedPort!
    init() async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = HostedPort()
        guard case .fresh(let opened) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else { throw HostedError.setup("seed") }
        let defs = try await opened.snapshot().definitions
        _ = try await opened.select(defs.first { $0.name == "Everyday" }!.id, on: "com.apple.Safari")
        _ = try await opened.checkpoint()
        port = HostedPort(await seed.bytes)
        app = LibraryAppSession(changed: { [weak self] in self?.refresh() }, read: { [reads] in try await reads.read($0) },
            checkpointDelay: { [delay] in await delay.pause(); try Task.checkCancellation() })
        await app.start(persistence: port, limits: limits)
        _ = await app.coordinator.attachPlayback { _, _, _ in }
    }
    func refresh() {
        guard let presentation = app.presentation, let data = app.menuData else { return }
        if view == nil { view = MenuPresentation(presentation: presentation, glyph: NSImage(size: NSSize(width: 1, height: 1)), perform: { [weak self] in self?.actions.append($0); self?.app.send($0) }) }
        view.snapshot = data
    }
    var card: MenuSoundCard { app.menuData!.assignments[0] }
    var slider: MenuSoundControl { card.controls.first { $0.title == "Softer" }! }
    var choice: MenuSoundControl { card.controls.first { if case .choice = $0.face { return true }; return false }! }
    func begin() throws -> UUID {
        view.beginGesture()
        guard case .beginMenuGesture(let id) = actions.last else { throw HostedError.setup("begin producer") }
        return id
    }
    /// Sends the action the menu row would send and resolves with the coordinator's reported outcome.
    func move(_ value: Double, token: UUID?, card: MenuSoundCard, control: MenuSoundControl) async -> String {
        let reply = HostedReply()
        app.perfMutationCompleted = { reply.finish(String(describing: $0)) }
        app.perfMutationFailed = { reply.finish("failure") }
        app.coordinator.perfParameterEvaluated = { _, _ in reply.finish("live") }
        if let token { app.send(.gestureMove(token, card.menuIdentity!, card.menuEpoch!, control.address, control.optionGesture, .scalar(value))) }
        else { app.send(.menuMove(card.menuIdentity!, card.menuEpoch!, control.address, control.optionGesture, .scalar(value))) }
        return await reply.value()
    }
    func end() { view.endGesture() }
    func finish() async throws -> LibrarySnapshot {
        _ = await app.flushSave()?.value
        await delay.release()
        let reopened = try await SoundLibrarySession(persistence: HostedPort(await port.bytes), limits: LibraryAppSession.normalLimits())
        return try await reopened.snapshot()
    }
    func close() async { app.close(); await delay.release() }
}

struct PR39HostedRaceCases {
    @MainActor private static var failures = 0
    @MainActor private static func check(_ yes: Bool, _ message: String) {
        if !yes { failures += 1 }
        print("HOSTED \(yes ? "PASS" : "FAIL") \(message)")
    }
    @MainActor static func run(_ selected: String = "all") async throws {
        failures = 0
        func wants(_ name: String) -> Bool {
            selected == "all" || selected == name || (selected == "R15" && name.hasPrefix("R15"))
                || (selected == "R26" && name.hasPrefix("R26")) || (selected == "P1" && name.hasPrefix("P1"))
        }
        if wants("R15-A") { try await r15HeldTrigger() }
        if wants("R15-B") { try await r15SplitSample() }
        for window in ["A", "B"] {
            if wants("R26-\(window)") { try await r26(window, probe: .click) }
            if wants("R26-\(window)-retired-token") { try await r26(window, probe: .retiredToken) }
            if wants("R26-\(window)-retired-epoch") { try await r26(window, probe: .retiredEpoch) }
        }
        for follow in [P1Follow.click, .drag, .retiredToken, .retiredEpoch] where wants("P1-\(follow.rawValue)") {
            try await p1NewerEpochDuringSave(follow)
        }
        if failures > 0 { throw HostedError.setup("\(failures) hosted race assertions") }
    }

    // MARK: R15

    @MainActor private static func readFixture() async throws -> (HostedReadFixture, TNFEditorCommands) {
        let f = try await HostedReadFixture()
        let commands = TNFEditorCommands(app: f.app)
        try await commands.select(.use(f.card().binding!))
        await f.app.editor.displaySettled()
        try await commands.refresh()
        await f.app.editor.displaySettled()
        f.surface.selectedEditor = commands
        return (f, commands)
    }
    /// Waits for the next surface notification after `before` and returns how many arrived.
    @MainActor private static func awaitNotification(_ f: HostedReadFixture, after before: Int) async {
        await f.surface.notified.wait(before + 1)
    }

    // Requirement: each time the editor asks for its view after a failed read, the app reads exactly once
    // and does not retry on its own, however slowly that read runs. (Event-driven replacement for
    // Main.swift readFailureNotifications, which sleeps 50 ms / 200 ms and samples its counters in two awaits.)
    @MainActor private static func r15HeldTrigger() async throws {
        let (f, commands) = try await readFixture()
        let publications = f.surface.fullChanges, notices = f.surface.attentionChanges
        let base = await f.reads.sample().reads
        let failures = ["availability-one", "availability-two", "availability-three"]
        await f.reads.armFailures(failures)
        func relative() async -> (reads: Int, injected: Int) { let s = await f.reads.sample(); return (s.reads - base, s.injected) }

        // Trigger 1.
        var seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await awaitNotification(f, after: seen)
        let s1 = await relative()
        check(s1 == (1, 1), "R15-A trigger 1 performs exactly one read: (reads,injected)=\(s1) expected=(1, 1)")
        check(f.surface.attentionChanges == notices + 1 && f.surface.fullChanges == publications,
            "R15-A failure 1 notifies attention without owner publication: attention=+\(f.surface.attentionChanges - notices) full=+\(f.surface.fullChanges - publications)")
        check(f.app.problem?.contains(failures[0]) == true && f.app.coordinator.positionContext == nil,
            "R15-A failure 1 observable: problem=\(String(describing: f.app.problem)) contextPresent=\(f.app.coordinator.positionContext != nil)")

        // Trigger 2, held inside editorQuery's operation, before the counted read.
        await f.editGate.arm()
        seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await f.editGate.gate.entered()
        let held = await relative()
        check(held == (1, 1), "R15-A trigger 2 held before its read: (reads,injected)=\(held) expected=(1, 1)")
        // DEMO, not ordering: Main.swift:416-418 unchanged (sleep 200 ms, then two separate awaits).
        try await Task.sleep(for: .milliseconds(200))
        let legacyReads = await f.reads.count - base, legacyInjected = await f.reads.injectedFailures
        let legacyPredicate = legacyReads == 2 && legacyInjected == 2
        print("HOSTED DEMO R15-A legacy predicate (reads == 2 && injected == 2) on sample (\(legacyReads),\(legacyInjected)) -> \(legacyPredicate ? "PASS" : "FAIL")")
        await f.editGate.gate.release()
        await awaitNotification(f, after: seen)
        let s2 = await relative()
        check(s2 == (2, 2), "R15-A trigger 2 after completion performs exactly one read: (reads,injected)=\(s2) expected=(2, 2)")
        check(!legacyPredicate && s2 == (2, 2),
            "R15-A legacy sleep-based predicate reports FAIL (\(legacyReads),\(legacyInjected)) on a run whose read count is correct \(s2): it measures latency, not reads")
        check(f.surface.attentionChanges == notices + 2 && f.surface.fullChanges == publications && f.app.problem?.contains(failures[1]) == true,
            "R15-A failure 2 notifies attention only: attention=+\(f.surface.attentionChanges - notices) full=+\(f.surface.fullChanges - publications) problem=\(String(describing: f.app.problem))")

        // Trigger 3.
        seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await awaitNotification(f, after: seen)
        let s3 = await relative()
        check(s3 == (3, 3), "R15-A trigger 3 performs exactly one read: (reads,injected)=\(s3) expected=(3, 3)")
        check(f.surface.attentionChanges == notices + 3 && f.surface.fullChanges == publications && f.app.problem?.contains(failures[2]) == true
            && f.surface.view?.problem == "Audio Needs Attention…" && f.app.coordinator.positionContext == nil,
            "R15-A failure 3 observable: attention=+\(f.surface.attentionChanges - notices) full=+\(f.surface.fullChanges - publications) viewProblem=\(String(describing: f.surface.view?.problem)) contextPresent=\(f.app.coordinator.positionContext != nil)")

        // Recovery.
        seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await awaitNotification(f, after: seen)
        await f.app.editor.displaySettled()
        let s4 = await relative()
        check(s4 == (4, 3), "R15-A recovery performs exactly one read with no retry: (reads,injected)=\(s4) expected=(4, 3)")
        check(f.app.coordinator.positionContext != nil && commands.projection != nil && f.app.problem == nil && f.surface.view?.problem == nil
            && f.surface.attentionChanges == notices + 4 && f.surface.fullChanges == publications,
            "R15-A recovery restores context quietly: contextPresent=\(f.app.coordinator.positionContext != nil) projection=\(commands.projection != nil) problem=\(String(describing: f.app.problem)) attention=+\(f.surface.attentionChanges - notices) full=+\(f.surface.fullChanges - publications)")
        print("HOSTED READ_FAILURE_COUNTS reads=\(s4.reads) injectedFailures=\(s4.injected) ownerPublications=\(f.surface.fullChanges - publications) attentionNotifications=\(f.surface.attentionChanges - notices)")

        // A fresh drag after recovery is admitted and saved.
        let card = f.card(), control = f.slider()
        f.surface.selectedEditor = nil
        let gesture = f.surface.view!.beginMovement(control, on: card)
        let token = f.surface.actions.compactMap { if case .beginMenuGesture(let id) = $0 { return id }; return nil }.last
        let result = try await f.app.coordinator.submitSliderMove(control.address, expected: card.binding!, to: .scalar(0.9),
            optionGesture: control.optionGesture, menuIdentity: card.menuIdentity, expectedEpoch: card.menuEpoch, gestureIdentity: token).value
        let admitted: Bool
        switch result { case .executed(.superseded), .fenced(.superseded): admitted = false; default: admitted = true }
        check(admitted, "R15-A recovered context admits a fresh drag: result=\(result)")
        gesture.end()
        let outcome = await f.app.gestureSave?.value.outcome
        let reopened = try await SoundLibrarySession(persistence: HostedPort(await f.port.bytes), limits: LibraryAppSession.normalLimits())
        let snapshot = try await reopened.snapshot(), saved = snapshot.uses.first { $0.id == card.binding!.use }!.positions[control.id]
        check(saved == .scalar(0.9) && !snapshot.isEnabled, "R15-A recovered drag saves 0.9 with power still OFF: saveOutcome=\(String(describing: outcome)) reopened=\(String(describing: saved)) enabled=\(snapshot.isEnabled)")
        f.app.close()
    }

    // Requirement (test soundness): a read count sampled in two separate awaits can disagree with itself
    // while the app performs exactly one read; the counters must be sampled together after completion.
    @MainActor private static func r15SplitSample() async throws {
        let (f, commands) = try await readFixture()
        let base = await f.reads.sample().reads
        await f.reads.armFailures(["availability-one", "availability-two", "availability-three"])
        var seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await awaitNotification(f, after: seen)
        let s1 = await f.reads.sample()
        await f.editGate.arm()
        seen = f.surface.notified.count
        commands.receiveOwnerChange()
        await f.editGate.gate.entered()
        let splitReads = await f.reads.count - base
        await f.editGate.gate.release()
        await awaitNotification(f, after: seen)
        let splitInjected = await f.reads.injectedFailures
        let atomic = await f.reads.sample()
        let atomicPair = (atomic.reads - base, atomic.injected)
        print("HOSTED DEMO R15-B split sample (\(splitReads),\(splitInjected)) -> legacy predicate \(splitReads == 2 && splitInjected == 2 ? "PASS" : "FAIL"); atomic sample \(atomicPair)")
        check(s1.reads - base == 1 && s1.injected == 1 && splitReads == 1 && splitInjected == 2 && atomicPair == (2, 2),
            "R15-B split two-await sample gives (\(splitReads),\(splitInjected)) while the atomic sample after completion is \(atomicPair) and trigger 1 was (\(s1.reads - base),\(s1.injected)); expected split=(1,2) atomic=(2, 2)")
        f.app.close()
    }

    // MARK: R26

    private enum Probe { case click, retiredToken, retiredEpoch }

    // R26 Requirement (click): a choice clicked in the menu while the editor is refreshing its view
    //   (an automatic display read, window A, or a follow-up editor query, window B) is applied and saved.
    // R26 Requirement (retired-token / retired-epoch): in that same window, a drag that has already
    //   ended, or a card shown before the last save, still cannot change the slider.
    @MainActor private static func r26(_ window: String, probe: Probe) async throws {
        let name = "R26-\(window)" + (probe == .click ? "" : probe == .retiredToken ? "-retired-token" : "-retired-epoch")
        let f = try await HostedMenuFixture(), card = f.card, slider = f.slider
        guard case .choice(let options) = f.choice.face, options.count >= 2 else { throw HostedError.setup("choice options") }
        let original = f.card.effectiveOption(f.choice)
        guard let target = options.first(where: { $0.id != original?.id }) else { throw HostedError.setup("second choice") }

        // RaceCases.swift editorBarrier("query") through :252, unchanged.
        let commands = TNFEditorCommands(app: f.app)
        try await commands.select(.use(card.binding!)); await f.app.editor.displaySettled()
        try await commands.refresh(); await f.app.editor.displaySettled()
        await f.app.menuOpened().value
        let captured = f.card, token = try f.begin()
        let m1 = await f.move(0.3, token: token, card: captured, control: slider), m2 = await f.move(0.4, token: token, card: captured, control: slider)
        _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() }
        let m3 = await f.move(0.6, token: token, card: captured, control: slider), m4 = await f.move(0.8, token: token, card: captured, control: slider)
        f.end(); _ = await f.app.gestureSave?.value
        let setupMoves = [m1, m2, m3, m4]
        guard setupMoves.allSatisfy({ $0 != "superseded" }) else {
            check(false, "\(name) INVALID setup: identified drag moves were refused before the window opened: \(setupMoves)")
            await f.close(); return
        }

        // Open the window and hold its projection read.
        var followup: Task<Void, Error>?
        if window == "A" {
            await f.app.editor.displaySettled()
            await f.app.coordinator.refresh(mode: .positions)
            await f.reads.arm()
            f.app.editor.requestDisplay()
            await f.reads.gate.entered()
        } else {
            await f.app.menuOpened().value
            await f.reads.arm()
            followup = Task { _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() } }
            await f.reads.gate.entered()
        }
        let contextPresent = f.app.coordinator.positionContext != nil
        let shown = f.card
        print("HOSTED WINDOW \(name) setupMoves=\(setupMoves) capturedEpoch=\(String(describing: captured.menuEpoch)) shownEpoch=\(String(describing: shown.menuEpoch)) contextEpoch=\(String(describing: f.app.coordinator.positionContext?.epoch)) original=\(String(describing: original?.title)) target=\(target.title)")
        guard !contextPresent else {
            check(false, "\(name) INVALID precondition: a position context is installed while the read is held (contextEpoch=\(String(describing: f.app.coordinator.positionContext?.epoch)))")
            await f.reads.gate.release(); _ = try? await followup?.value; await f.close(); return
        }

        let result: String
        switch probe {
        case .click: result = await f.move(target.position, token: nil, card: shown, control: f.choice)
        case .retiredToken: result = await f.move(0.05, token: token, card: captured, control: slider)
        case .retiredEpoch: result = await f.move(0.05, token: nil, card: captured, control: slider)
        }
        await f.reads.gate.release()
        if let followup { try await followup.value } else { await f.app.editor.displaySettled() }
        let saved = try await f.finish().uses.first { $0.id == card.binding!.use }!
        let savedSlider = saved.positions[slider.id], savedChoice = saved.positions[f.choice.id]
        let values = "result=\(result) savedSlider=\(String(describing: savedSlider)) savedChoice=\(String(describing: savedChoice)) targetChoice=\(target.position) originalChoice=\(String(describing: original?.position))"
        switch probe {
        case .click:
            check(result != "superseded", "\(name) choice click during the held read is admitted: \(values)")
            check(savedChoice == .scalar(target.position), "\(name) reopen shows the clicked choice: \(values)")
            check(savedSlider == .scalar(0.8), "\(name) reopen keeps the drag's 0.8: \(values)")
        case .retiredToken:
            check(result == "superseded", "\(name) ended drag's move during the held read is refused: \(values)")
            check(savedSlider == .scalar(0.8), "\(name) reopen keeps 0.8, not the ended drag's 0.05: \(values)")
        case .retiredEpoch:
            check(result == "superseded", "\(name) no-identity move with the pre-save card epoch is refused: \(values)")
            check(savedSlider == .scalar(0.8), "\(name) reopen keeps 0.8, not the stale card's 0.05: \(values)")
        }
        await f.close()
    }

    // MARK: P1, newer displayed epoch during a held release save

    private enum P1Follow: String { case click, drag, retiredToken = "retired-token", retiredEpoch = "retired-epoch" }

    // P1 Requirement (click / drag): while a slider's release save is still writing, if the menu has been
    //   refreshed and shows a newer card, clicking a choice on that card and then clicking again, or starting
    //   a new drag, all take effect and are still there after reopening.
    // P1 Requirement (retired-token / retired-epoch): in that same moment, a move from the drag that already
    //   ended, or a slider move carrying the card shown before the save, still cannot change the slider.
    @MainActor private static func p1NewerEpochDuringSave(_ follow: P1Follow) async throws {
        let name = "P1-\(follow.rawValue)"
        let f = try await HostedMenuFixture(), card = f.card, slider = f.slider
        guard case .choice(let options) = f.choice.face, options.count >= 3 else { throw HostedError.setup("three choices") }
        let original = f.card.effectiveOption(f.choice)
        let others = options.filter { $0.id != original?.id }
        guard others.count >= 2 else { throw HostedError.setup("two other choices") }
        let first = others[0], second = others[1]

        // Drag G1 to 0.5, release, and hold the release save's write.
        let g1 = try f.begin()
        let m1 = await f.move(0.3, token: g1, card: card, control: slider), m2 = await f.move(0.5, token: g1, card: card, control: slider)
        await f.port.arm(); f.end()
        guard let save1 = f.app.gestureSave else { throw HostedError.setup("release save") }
        await f.port.gate.entered()
        let preSave = f.card

        // An editor read completes during the held save and publishes a newer card epoch.
        _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() }
        let shown = f.card
        let contextEpoch = f.app.coordinator.positionContext?.epoch
        print("HOSTED WINDOW \(name) g1Moves=\(m1),\(m2) preSaveEpoch=\(String(describing: preSave.menuEpoch)) shownEpoch=\(String(describing: shown.menuEpoch)) contextEpoch=\(String(describing: contextEpoch)) original=\(String(describing: original?.title)) first=\(first.title) second=\(second.title)")
        guard m1 != "superseded", m2 != "superseded", shown.menuEpoch != nil, shown.menuEpoch != preSave.menuEpoch, contextEpoch == shown.menuEpoch else {
            check(false, "\(name) INVALID precondition: the editor read did not publish a newer on-screen epoch during the held save (g1Moves=\(m1),\(m2) preSave=\(String(describing: preSave.menuEpoch)) shown=\(String(describing: shown.menuEpoch)) context=\(String(describing: contextEpoch)))")
            await f.port.gate.release(); _ = await save1.value; await f.close(); return
        }

        // Click a choice on the newer card, and hold that click's follow-up refresh read.
        await f.reads.arm()
        let click1 = await f.move(first.position, token: nil, card: shown, control: f.choice)
        await f.reads.gate.entered()
        let onScreen = f.card
        print("HOSTED WINDOW \(name) click1=\(click1) onScreenEpoch=\(String(describing: onScreen.menuEpoch)) contextEpoch=\(String(describing: f.app.coordinator.positionContext?.epoch))")

        var outcomes: [String] = []
        var save2: Task<LibraryConsumerCommandResult, Never>?
        switch follow {
        case .click: outcomes.append(await f.move(second.position, token: nil, card: onScreen, control: f.choice))
        case .drag:
            let g2 = try f.begin()
            for value in [0.6, 0.7, 0.8] { outcomes.append(await f.move(value, token: g2, card: onScreen, control: slider)) }
            f.end(); save2 = f.app.gestureSave
        case .retiredToken: outcomes.append(await f.move(0.05, token: g1, card: preSave, control: slider))
        case .retiredEpoch: outcomes.append(await f.move(0.05, token: nil, card: preSave, control: slider))
        }
        await f.reads.gate.release(); await f.port.gate.release()
        _ = await save1.value; _ = await save2?.value
        let saved = try await f.finish().uses.first { $0.id == card.binding!.use }!
        let savedSlider = saved.positions[slider.id], savedChoice = saved.positions[f.choice.id]
        let values = "click1=\(click1) followUp=\(outcomes) savedSlider=\(String(describing: savedSlider)) savedChoice=\(String(describing: savedChoice)) first=\(first.position) second=\(second.position) original=\(String(describing: original?.position))"
        switch follow {
        case .click:
            check(click1 != "superseded", "\(name) click on the newer card during the held save is admitted: \(values)")
            check(outcomes.allSatisfy { $0 != "superseded" }, "\(name) follow-up click while the first click's refresh is held is admitted: \(values)")
            check(savedChoice == .scalar(second.position), "\(name) reopen shows the follow-up click's choice: \(values)")
            check(savedSlider == .scalar(0.5), "\(name) reopen keeps the released drag's 0.5: \(values)")
        case .drag:
            check(click1 != "superseded", "\(name) click on the newer card during the held save is admitted: \(values)")
            check(outcomes.allSatisfy { $0 != "superseded" }, "\(name) every move of a fresh drag while the click's refresh is held is admitted: \(values)")
            check(savedChoice == .scalar(first.position), "\(name) reopen shows the clicked choice: \(values)")
            check(savedSlider == .scalar(0.8), "\(name) reopen shows the fresh drag's 0.8: \(values)")
        case .retiredToken:
            check(outcomes == ["superseded"], "\(name) move from the drag that already ended is refused: \(values)")
            check(savedSlider == .scalar(0.5), "\(name) reopen keeps 0.5, not the ended drag's 0.05: \(values)")
        case .retiredEpoch:
            check(outcomes == ["superseded"], "\(name) no-identity slider move with the pre-save card is refused: \(values)")
            check(savedSlider == .scalar(0.5), "\(name) reopen keeps 0.5, not the stale card's 0.05: \(values)")
        }
        await f.close()
    }
}

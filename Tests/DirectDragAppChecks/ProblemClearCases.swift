import Foundation
@testable import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

// Problems clear, and a failed start quits cleanly: behaviour checks.
// A save problem and an apply problem are kept apart and cleared only by their own events;
// `problem` reads read, then save, then apply; quitting after a failed boot never asks to save.
// New product names live only in ProblemClearNames.swift. Pure fakes: no App, window, audio or disk.
//
// Markers: every injected or faked failure carries a unique word, so a case can tell the save text
// from the apply text although both begin "The change could not be saved."

private struct UnitAMark: Error, CustomStringConvertible { let description: String }

/// Library port whose commit answer and readback are set by the case.
private actor UnitAPort: LibraryPersistence {
    private(set) var data: Data?
    private(set) var writes = 0
    private var next: LibraryWriteOutcome = .committed
    private var loadFails = false
    init(_ data: Data?) { self.data = data }
    func answer(_ outcome: LibraryWriteOutcome) { next = outcome }
    func failLoads(_ fail: Bool) { loadFails = fail }
    func load() throws -> Data? {
        if loadFails { throw UnitAMark(description: "UNIT-A-LOAD-REFUSED") }
        return data
    }
    func commit(_ value: Data) -> LibraryWriteOutcome {
        writes += 1
        switch next {
        case .committed, .identical: data = value
        case .unresolved: data = value      // the bytes landed; only the answer was lost, so a readback matches
        case .refused: break
        }
        return next
    }
}

/// Records what `problem` was at every changed/attention notification (what the menu item would show).
@MainActor private final class UnitAObserver {
    weak var app: LibraryAppSession?
    private(set) var seen: [String?] = []
    private var clearWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    func note() {
        let current = app?.problem
        seen.append(current)
        guard current == nil else { return }
        let ready = clearWaiters; clearWaiters = []
        for waiter in ready { waiter.continuation.resume(returning: true) }
    }
    /// True once a notification after `count` saw no problem. The deadline only turns a missing
    /// notification into a reported failure instead of a hang; no passing result depends on it.
    func waitForClear(since count: Int, deadline: Duration = .seconds(20)) async -> Bool {
        if seen.dropFirst(count).contains(where: { $0 == nil }) { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            clearWaiters.append((id, continuation))
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: deadline)
                guard let self, let index = self.clearWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.clearWaiters.remove(at: index).continuation.resume(returning: false)
            }
        }
    }
}

/// Counts calls from `@Sendable` closures (reads, checkpoint delays).
private final class UnitACounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Controls the fakes. `failure`: the `move:` override throws with that marker (ordered fixture).
/// Drag fixture: `failures` counts down the live-apply and menu-move failures, each thrown with `mark`;
/// `followers` are sent from inside the next live apply, while that sample is still in flight.
@MainActor private final class UnitAFlip {
    var failure: String?
    var failures = 0
    var mark = "UNIT-A-DRAG"
    var followers: [EverydayMenuAction] = []
}

@MainActor private final class UnitAReply {
    private var result: String?
    private var waiter: CheckedContinuation<String, Never>?
    func finish(_ value: String) {
        guard result == nil else { return }
        result = value; waiter?.resume(returning: value); waiter = nil
    }
    /// The deadline only turns a missing callback into a reported failure instead of a hang.
    func value(deadline: Duration = .seconds(20)) async -> String {
        if let result { return result }
        Task { @MainActor [weak self] in try? await Task.sleep(for: deadline); self?.finish("timeout") }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor private final class UnitAFixture {
    let app: LibraryAppSession
    let port: UnitAPort
    let observer: UnitAObserver
    let flip: UnitAFlip
    let reads: UnitACounter
    let delays: UnitACounter
    private var names = 0

    private init(app: LibraryAppSession, port: UnitAPort, observer: UnitAObserver, flip: UnitAFlip,
                 reads: UnitACounter, delays: UnitACounter) {
        self.app = app; self.port = port; self.observer = observer; self.flip = flip; self.reads = reads; self.delays = delays
    }

    /// `drag: false` (default): live moves go through the `move:` override, so the ordered path runs.
    /// `drag: true`: no `move:` override, so a menu drag reaches the optimised live path (`.live`, `.coalesced`);
    /// failures come from `applyFailureForTesting` and the `menuMove:` override.
    static func make(drag: Bool = false) async throws -> UnitAFixture {
        let limits = try LibraryAppSession.normalLimits(), seed = UnitAPort(nil)
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else {
            throw UnitAMark(description: "setup: seed library did not open fresh")
        }
        let definitions = try await seedOwner.snapshot().definitions
        guard let everyday = definitions.first(where: { $0.name == "Everyday" }) else { throw UnitAMark(description: "setup: no Everyday") }
        _ = try await seedOwner.select(everyday.id, on: "com.apple.Safari")
        _ = try await seedOwner.checkpoint()
        let port = UnitAPort(await seed.data), observer = UnitAObserver(), flip = UnitAFlip()
        let reads = UnitACounter(), delays = UnitACounter()
        let ordered: LibraryListeningCoordinator.Move = { _, _, _, _, _ in
            if let mark = flip.failure { throw UnitAMark(description: mark) }
            return .changed
        }
        let menuMove: LibraryListeningCoordinator.MenuMove = { session, address, identity, option, value in
            if flip.failures > 0 { flip.failures -= 1; throw UnitAMark(description: flip.mark) }
            return try await session.moveForMenu(address, expected: identity, optionGesture: option, to: value)
        }
        let app = LibraryAppSession(changed: { observer.note() }, attentionChanged: { observer.note() },
            read: { reads.bump(); return try await $0.menuState() },
            // No debounced checkpoint: a save behind a live command would clear a save problem by itself.
            checkpointDelay: { delays.bump(); throw CancellationError() },
            move: drag ? nil : ordered,
            menuMove: drag ? menuMove : nil)
        observer.app = app
        if drag {
            app.coordinator.applyFailureForTesting = { [weak app] in
                let followers = flip.followers; flip.followers = []
                for action in followers { app?.send(action) }
                if flip.failures > 0 { flip.failures -= 1; throw UnitAMark(description: flip.mark) }
            }
        }
        await app.start(persistence: port, limits: limits)
        await app.quiescent()
        guard app.isReady, app.problem == nil else {
            throw UnitAMark(description: "setup: session not ready or already has a problem: \(String(describing: app.problem))")
        }
        return UnitAFixture(app: app, port: port, observer: observer, flip: flip, reads: reads, delays: delays)
    }

    var problem: String? { app.problem }
    var notifications: Int { observer.seen.count }
    /// True when a notification arrived after `count` and the latest one saw no problem.
    func notifiedClear(since count: Int) -> Bool {
        guard observer.seen.count > count, let last = observer.seen.last else { return false }
        return last == nil
    }

    func card() throws -> MenuSoundCard {
        guard let card = app.menuData?.assignments.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            throw UnitAMark(description: "setup: no Safari card")
        }
        return card
    }
    func binding() throws -> LibraryBinding {
        guard let binding = try card().binding else { throw UnitAMark(description: "setup: Safari card has no binding") }
        return binding
    }
    /// A top-level choice control: `listen` routes it through `live(positionOnly:)` and the `move:` override.
    func choiceMove() throws -> EverydayMenuAction {
        let card = try card()
        guard let control = card.controls.first(where: { if case .choice = $0.face { return true }; return false }),
              case .choice(let options) = control.face, let option = options.last else {
            throw UnitAMark(description: "setup: no choice control on the Everyday card")
        }
        return .libraryMove(try binding(), control.address, .scalar(option.position))
    }
    func sliderControl() throws -> MenuSoundControl {
        guard let control = try card().controls.first(where: {
            guard $0.optionGesture == nil, case .slider = $0.face else { return false }
            return true
        }) else { throw UnitAMark(description: "setup: no top-level slider on the Everyday card") }
        return control
    }
    /// A top-level slider: `listen` routes it through `submitSliderMove` and the slider success arms.
    func sliderMove(_ value: Double) throws -> EverydayMenuAction {
        .libraryMove(try binding(), try sliderControl().address, .scalar(value))
    }
    /// One sample of a menu drag `gesture` on the slider, addressed to the card as it is now.
    func dragSample(_ gesture: UUID, _ value: Double) throws -> EverydayMenuAction {
        let card = try card(), control = try sliderControl()
        guard let identity = card.menuIdentity, let epoch = card.menuEpoch else {
            throw UnitAMark(description: "setup: the Safari card has no menu identity or epoch")
        }
        return .gestureMove(gesture, identity, epoch, control.address, control.optionGesture, .scalar(value))
    }
    /// Drag fixture: one drag whose first sample fails, leaving an apply problem; the failure ends the drag.
    func failDrag(_ mark: String) async throws {
        let gesture = UUID()
        app.send(.beginMenuGesture(gesture))
        flip.mark = mark; flip.failures = 1
        let sample = try dragSample(gesture, 0.3)
        let outcome = await live(sample)
        flip.failures = 0
        app.send(.endGesture)
        await app.quiescent()
        guard outcome == "failed", has(app.problem, mark) else {
            throw UnitAMark(description: "setup: the drag sample did not fail (\(outcome), \(String(describing: app.problem)))")
        }
    }

    /// Sends one live action, waits for its completion or failure callback, then for quiescence.
    /// `problem` is read only after this returns, never inside the callback.
    func live(_ action: EverydayMenuAction) async -> String {
        let reply = UnitAReply()
        app.perfMutationCompleted = { _ in reply.finish("completed") }
        app.perfMutationFailed = { reply.finish("failed") }
        app.send(action)
        let value = await reply.value()
        app.perfMutationCompleted = nil; app.perfMutationFailed = nil
        await app.quiescent()
        return value
    }
    /// Makes one live move throw with `mark`; returns the problem text it left.
    func failApply(_ mark: String) async throws -> String {
        flip.failure = mark
        let action = try choiceMove()
        let outcome = await live(action)
        flip.failure = nil
        guard outcome == "failed" else { throw UnitAMark(description: "setup: the apply did not fail (\(outcome))") }
        return app.problem ?? ""
    }
    /// One real structural command through the coordinator, answered by the port with `outcome`.
    func save(_ outcome: LibraryWriteOutcome) async -> LibraryConsumerCommandResult {
        await port.answer(outcome)
        names += 1
        let result = await app.createEmpty(name: "Unit A \(names)").value
        await app.quiescent()
        return result
    }
    func inject(_ event: LibraryConsumerEvent) { unitAReceive(app, event) }
    /// The problem alert's life as `showProblem()` runs it: build (what it shows), then dismiss. Returns the shown text.
    @discardableResult func showAndDismissAlert() -> String? {
        let shown = unitAPresent(app)
        unitADismiss(app)
        return shown
    }
}

private func commit(_ digest: String, _ outcome: LibraryWriteOutcome) -> LibraryCommit {
    LibraryCommit(token: UUID(), digest: digest, outcome: outcome)
}
private func commandEvent(_ outcome: LibraryConsumerCommandOutcome) -> LibraryConsumerEvent {
    .command(LibraryConsumerCommandResult(command: UUID(), outcome: outcome))
}
private func acceptedCommand() -> LibraryConsumerEvent { commandEvent(.accepted(commit("UNIT-A-OK", .committed))) }
private func acceptedReconciliation() -> LibraryConsumerEvent { .reconciliation(.accepted(command: UUID(), commit: UUID())) }
private func refusedSave(_ mark: String) -> LibraryConsumerEvent { commandEvent(.refused(commit(mark, .refused(.io("injected"))))) }
private func unresolvedSave(_ mark: String) -> LibraryConsumerEvent { commandEvent(.unresolved(commit(mark, .unresolved("injected")))) }
private func outcomeName(_ result: LibraryConsumerCommandResult) -> String {
    String(String(describing: result.outcome).prefix { $0 != "(" })
}
private func has(_ problem: String?, _ mark: String) -> Bool { problem?.contains(mark) == true }

enum ProblemClearCases {
    @MainActor private static var failures: [String] = []
    @MainActor private static func check(_ yes: Bool, _ id: String, _ message: String) {
        if !yes { failures.append(id) }
        print("UNIT-A \(yes ? "PASS" : "FAIL") \(id) \(message)")
    }

    @MainActor static func run() async throws {
        failures = []
        try await s1RefusedThenAcceptedCommand()
        try await s2TwoRefusalsKeepOneProblem()
        try await s3RefusedThenAcceptedReconciliation()
        try await s4UnresolvedClearsOnEitherAccept()
        try await s5BlockedClearsOnEitherAccept()
        try await s6NonAcceptingReconciliationsClearNothing()
        try await s7OtherFailedOutcomes()
        try await s8RealUnresolvedClearsOnReconciliationAlone()
        try await s9RealBlockedClearsOnAcceptedReconciliation()
        try await s10LiveSuccessKeepsSaveProblem()
        try await p1PowerAndMoveSuccessClearApply()
        try await p2SliderSuccessClearsApply()
        try await p3CompareSuccessClearsApply()
        try await p4AcceptedResultsKeepApply()
        try await p5SecondApplyFailureReplaces()
        try await p6SupersededCompletionClearsApply()
        try await p7LiveDragSampleClearsApply()
        try await p8CoalescedSampleKeepsApply()
        try await d1DismissClearsShownApply()
        try await d2DismissKeepsSave()
        try await d3DismissKeepsRead()
        try await d4DismissKeepsHiddenApply()
        try await o1PrecedenceReadSaveApply()
        try await o2SaveShownOverLaterApply()
        try await w1StartupProblemStays()
        quitDecisions()
        sourceWiring()
        guard failures.isEmpty else { throw UnitAMark(description: "Unit A failed: \(failures.joined(separator: ", "))") }
        print("PASS Unit A: problems clear by writer, read/save/apply precedence, failed boot quits without a save alert")
    }

    // MARK: Save problem

    @MainActor static func s1RefusedThenAcceptedCommand() async throws {
        let f = try await UnitAFixture.make()
        let refused = await f.save(.refused(.io("UNIT-A-S1-IO")))
        check(outcomeName(refused) == "refused" && has(f.problem, "UNIT-A-S1-IO"), "S1a",
            "a refused real save sets the save problem: outcome=\(outcomeName(refused)) problem=\(String(describing: f.problem))")
        let before = f.notifications
        let accepted = await f.save(.committed)
        check(outcomeName(accepted) == "accepted" && f.problem == nil && f.notifiedClear(since: before), "S1b",
            "the next accepted real save clears it and the menu is told: outcome=\(outcomeName(accepted)) problem=\(String(describing: f.problem)) notifiedClear=\(f.notifiedClear(since: before))")
    }

    @MainActor static func s2TwoRefusalsKeepOneProblem() async throws {
        let f = try await UnitAFixture.make()
        _ = await f.save(.refused(.io("UNIT-A-S2-FIRST")))
        _ = await f.save(.refused(.io("UNIT-A-S2-SECOND")))
        check(has(f.problem, "UNIT-A-S2-SECOND") && !has(f.problem, "UNIT-A-S2-FIRST"), "S2a",
            "two refused saves leave one save problem, the latest: problem=\(String(describing: f.problem))")
        _ = await f.save(.committed)
        check(f.problem == nil, "S2b", "one accepted save clears it; no count of failures: problem=\(String(describing: f.problem))")
    }

    @MainActor static func s3RefusedThenAcceptedReconciliation() async throws {
        let f = try await UnitAFixture.make()
        f.inject(refusedSave("UNIT-A-S3"))
        check(has(f.problem, "UNIT-A-S3"), "S3a", "an injected refused save sets the save problem: \(String(describing: f.problem))")
        let before = f.notifications
        f.inject(acceptedReconciliation())
        check(f.problem == nil && f.notifiedClear(since: before), "S3b",
            "an accepted reconciliation clears a refused save: problem=\(String(describing: f.problem))")
    }

    /// The rule: any save problem clears on the next accepted command or accepted reconciliation.
    @MainActor static func s4UnresolvedClearsOnEitherAccept() async throws {
        let f = try await UnitAFixture.make()
        f.inject(unresolvedSave("UNIT-A-S4-CMD"))
        check(has(f.problem, "UNIT-A-S4-CMD"), "S4a", "an unresolved save sets the save problem: \(String(describing: f.problem))")
        var before = f.notifications
        f.inject(acceptedCommand())
        check(f.problem == nil && f.notifiedClear(since: before), "S4b",
            "an accepted command clears an unresolved save: \(String(describing: f.problem))")
        f.inject(unresolvedSave("UNIT-A-S4-REC"))
        before = f.notifications
        f.inject(acceptedReconciliation())
        check(f.problem == nil && f.notifiedClear(since: before), "S4c",
            "an accepted reconciliation clears an unresolved save: \(String(describing: f.problem))")
    }

    @MainActor static func s5BlockedClearsOnEitherAccept() async throws {
        let f = try await UnitAFixture.make(), first = UUID(), second = UUID()
        f.inject(commandEvent(.blocked(first)))
        check(has(f.problem, first.uuidString), "S5a", "a blocked save sets the save problem: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(f.problem == nil, "S5b", "an accepted command clears a blocked save: \(String(describing: f.problem))")
        f.inject(commandEvent(.blocked(second)))
        f.inject(acceptedReconciliation())
        check(f.problem == nil, "S5c", "an accepted reconciliation clears a blocked save: \(String(describing: f.problem))")
    }

    @MainActor static func s6NonAcceptingReconciliationsClearNothing() async throws {
        let others: [LibraryConsumerReconciliation] = [
            .idle, .inFlight(nil), .refused(command: UUID(), commit: UUID(), reason: .destinationChanged),
            .unresolved(nil, "UNIT-A-S6-STILL"), .superseded]
        let f = try await UnitAFixture.make()
        f.inject(refusedSave("UNIT-A-S6-REFUSED"))
        for event in others { f.inject(.reconciliation(event)) }
        check(has(f.problem, "UNIT-A-S6-REFUSED"), "S6a",
            "idle, in-flight, refused, unresolved and superseded reconciliations leave a refused save: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        f.inject(unresolvedSave("UNIT-A-S6-UNRESOLVED"))
        for event in others { f.inject(.reconciliation(event)) }
        check(has(f.problem, "UNIT-A-S6-UNRESOLVED"), "S6b",
            "the same reconciliations leave an unresolved save: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(f.problem == nil, "S6c",
            "after a refused or superseded reconciliation, the next accepted command clears it (it can never stick): \(String(describing: f.problem))")
    }

    @MainActor static func s7OtherFailedOutcomes() async throws {
        let f = try await UnitAFixture.make()
        f.inject(commandEvent(.failed("UNIT-A-S7-FAILED")))
        check(has(f.problem, "UNIT-A-S7-FAILED"), "S7a", "a failed command result is a save problem, as today: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(f.problem == nil, "S7b", "an accepted command clears it: \(String(describing: f.problem))")
        f.inject(commandEvent(.rejected(.draining)))
        check(has(f.problem, "rejected"), "S7c", "a rejected command result is a save problem, as today: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(f.problem == nil, "S7d", "an accepted command clears it: \(String(describing: f.problem))")
    }

    @MainActor static func s8RealUnresolvedClearsOnReconciliationAlone() async throws {
        let f = try await UnitAFixture.make()
        let unresolved = await f.save(.unresolved("UNIT-A-S8-UNRESOLVED"))
        check(outcomeName(unresolved) == "unresolved" && has(f.problem, "UNIT-A-S8-UNRESOLVED"), "S8a",
            "a real unresolved save sets the save problem: outcome=\(outcomeName(unresolved)) problem=\(String(describing: f.problem))")
        let writes = await f.port.writes, before = f.notifications
        await f.app.menuOpened().value
        await f.app.quiescent()
        let after = await f.port.writes
        check(f.problem == nil && after == writes && f.notifiedClear(since: before), "S8b",
            "opening the menu reconciles the matching readback and clears it, with no new write: problem=\(String(describing: f.problem)) writes=\(writes)->\(after)")
    }

    @MainActor static func s9RealBlockedClearsOnAcceptedReconciliation() async throws {
        let f = try await UnitAFixture.make()
        let unresolved = await f.save(.unresolved("UNIT-A-S9-UNRESOLVED"))
        await f.port.failLoads(true)
        let blocked = await f.save(.committed)
        check(outcomeName(unresolved) == "unresolved" && outcomeName(blocked) == "blocked" && has(f.problem, "blocked"), "S9a",
            "with the readback refused, the next real save is blocked and that is the save problem: outcomes=\(outcomeName(unresolved)),\(outcomeName(blocked)) problem=\(String(describing: f.problem))")
        await f.port.failLoads(false)
        await f.app.menuOpened().value
        await f.app.quiescent()
        check(f.problem == nil, "S9b", "once the readback matches, the accepted reconciliation clears it: \(String(describing: f.problem))")
    }

    @MainActor static func s10LiveSuccessKeepsSaveProblem() async throws {
        let f = try await UnitAFixture.make()
        _ = await f.save(.refused(.io("UNIT-A-S10-IO")))
        let writes = await f.port.writes
        let power = await f.live(.setEnabled(true))
        let moveAction = try f.choiceMove()
        let move = await f.live(moveAction)
        let after = await f.port.writes
        check(power == "completed" && move == "completed" && after == writes && has(f.problem, "UNIT-A-S10-IO"), "S10",
            "successful power and move commands leave the save problem (no checkpoint ran): power=\(power) move=\(move) writes=\(writes)->\(after) problem=\(String(describing: f.problem))")
    }

    // MARK: Apply problem

    @MainActor static func p1PowerAndMoveSuccessClearApply() async throws {
        let f = try await UnitAFixture.make()
        let text = try await f.failApply("UNIT-A-P1-POWER")
        check(has(text, "UNIT-A-P1-POWER"), "P1a", "a thrown live move sets the apply problem: \(text)")
        var before = f.notifications
        let power = await f.live(.setEnabled(true))
        check(power == "completed" && f.problem == nil && f.notifiedClear(since: before), "P1b",
            "a successful power command clears it and the menu is told: \(power) problem=\(String(describing: f.problem))")
        _ = try await f.failApply("UNIT-A-P1-MOVE")
        let moveAction = try f.choiceMove()
        before = f.notifications
        let move = await f.live(moveAction)
        check(move == "completed" && f.problem == nil && f.notifiedClear(since: before), "P1c",
            "a successful position-only move clears it: \(move) problem=\(String(describing: f.problem))")
    }

    @MainActor static func p2SliderSuccessClearsApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-P2")
        let sliderAction = try f.sliderMove(0.37), before = f.notifications
        let slider = await f.live(sliderAction)
        check(slider == "completed" && f.problem == nil && f.notifiedClear(since: before), "P2",
            "a successful slider move clears the apply problem and the menu is told: \(slider) problem=\(String(describing: f.problem))")
    }

    @MainActor static func p3CompareSuccessClearsApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-P3")
        let before = f.notifications
        let compare = await f.live(.compare(true))
        check(compare == "completed" && f.problem == nil && f.notifiedClear(since: before), "P3",
            "a successful compare command (no save behind it) clears the apply problem and the menu is told: \(compare) problem=\(String(describing: f.problem))")
        _ = await f.live(.compare(false))
    }

    @MainActor static func p4AcceptedResultsKeepApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-P4")
        let accepted = await f.save(.committed)
        check(outcomeName(accepted) == "accepted" && has(f.problem, "UNIT-A-P4"), "P4a",
            "an accepted real save does not clear the apply problem: outcome=\(outcomeName(accepted)) problem=\(String(describing: f.problem))")
        f.inject(acceptedCommand())
        f.inject(acceptedReconciliation())
        check(has(f.problem, "UNIT-A-P4"), "P4b",
            "an accepted command result and an accepted reconciliation do not clear it: \(String(describing: f.problem))")
    }

    @MainActor static func p5SecondApplyFailureReplaces() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-P5-FIRST")
        _ = try await f.failApply("UNIT-A-P5-SECOND")
        check(has(f.problem, "UNIT-A-P5-SECOND") && !has(f.problem, "UNIT-A-P5-FIRST"), "P5",
            "two failed applies leave one apply problem, the latest: \(String(describing: f.problem))")
    }

    /// Amended rule: a live command that completes without throwing clears the apply problem, whatever its result kind.
    @MainActor static func p6SupersededCompletionClearsApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-P6")
        let stale = LibraryBinding(assignment: UUID(), use: UUID(), target: "com.apple.Safari")
        let power = await f.live(.libraryPower(stale, true))
        check(power == "completed" && f.problem == nil, "P6",
            "a power command answered superseded (stale binding, no throw) still clears the apply problem: \(power) problem=\(String(describing: f.problem))")
    }

    /// A drag sample delivered on the optimised path (`.live`) clears the apply problem, and the `.live` arm asks
    /// for no save and no refresh (the drag's end does both).
    @MainActor static func p7LiveDragSampleClearsApply() async throws {
        let f = try await UnitAFixture.make(drag: true)
        try await f.failDrag("UNIT-A-P7")
        let gesture = UUID()
        f.app.send(.beginMenuGesture(gesture))
        let sample = try f.dragSample(gesture, 0.42)
        let evaluated = UnitAReply()
        f.app.coordinator.perfParameterEvaluated = { _, _ in evaluated.finish("live") }
        let before = f.notifications, reads = f.reads.value, delays = f.delays.value, writes = await f.port.writes
        f.app.send(sample)
        let path = await evaluated.value()
        f.app.coordinator.perfParameterEvaluated = nil
        let cleared = await f.observer.waitForClear(since: before)
        // A refresh or save request would start within a few main-actor turns; quiescence is not awaited mid-drag.
        for _ in 0..<50 { await Task.yield() }
        let readsAfter = f.reads.value, delaysAfter = f.delays.value, writesAfter = await f.port.writes
        check(path == "live", "P7a", "setup: the sample took the optimised live path: \(path)")
        check(cleared && f.problem == nil, "P7b",
            "a .live drag sample clears the apply problem and the menu is told: cleared=\(cleared) problem=\(String(describing: f.problem))")
        check(readsAfter == reads && delaysAfter == delays && writesAfter == writes, "P7c",
            "the .live arm requests no refresh and no save: reads \(reads)->\(readsAfter) checkpoint delays \(delays)->\(delaysAfter) writes \(writes)->\(writesAfter)")
        f.app.send(.endGesture)
        await f.app.quiescent()
    }

    /// A coalesced drag sample (replaced before it ran) leaves the apply problem. The samples around it fail,
    /// so nothing else in the sequence may clear it; a clear by the coalesced arm shows as a notification seeing nil.
    @MainActor static func p8CoalescedSampleKeepsApply() async throws {
        let f = try await UnitAFixture.make(drag: true)
        try await f.failDrag("UNIT-A-P8-FIRST")
        let gesture = UUID()
        f.app.send(.beginMenuGesture(gesture))
        let first = try f.dragSample(gesture, 0.2), replaced = try f.dragSample(gesture, 0.25), last = try f.dragSample(gesture, 0.3)
        var coalesced = 0, failed = 0
        let done = UnitAReply()
        f.app.coordinator.perfSliderCoalesced = { coalesced += 1 }
        f.app.perfMutationCompleted = { _ in done.finish("completed") }
        f.app.perfMutationFailed = { failed += 1; if failed == 2 { done.finish("two failures") } }
        // `first` is in flight when `replaced` and `last` arrive: `last` replaces `replaced`, which finishes coalesced.
        // `first` and `last` both fail, so only the coalesced arm could clear the problem.
        f.flip.mark = "UNIT-A-P8-SECOND"; f.flip.failures = 2; f.flip.followers = [replaced, last]
        let before = f.notifications
        f.app.send(first)
        let outcome = await done.value()
        f.flip.failures = 0; f.flip.followers = []
        f.app.perfMutationCompleted = nil; f.app.perfMutationFailed = nil; f.app.coordinator.perfSliderCoalesced = nil
        f.app.send(.endGesture)
        await f.app.quiescent()
        let sawClear = f.observer.seen.dropFirst(before).contains { $0 == nil }
        check(coalesced == 1 && outcome == "two failures", "P8a",
            "setup: one sample coalesced and the two around it failed: coalesced=\(coalesced) outcome=\(outcome) failed=\(failed)")
        check(!sawClear && f.problem != nil, "P8b",
            "a .coalesced drag sample does not clear the apply problem: sawClear=\(sawClear) problem=\(String(describing: f.problem))")
    }

    // MARK: Dismissing the alert

    @MainActor static func d1DismissClearsShownApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-D1")
        let before = f.notifications
        let shown = f.showAndDismissAlert()
        check(has(shown, "UNIT-A-D1") && f.problem == nil, "D1a",
            "dismissing the alert that showed the apply problem clears it: shown=\(String(describing: shown)) problem=\(String(describing: f.problem))")
        check(f.notifiedClear(since: before), "D1b",
            "the dismissal tells the menu, so the item hides: notifications=+\(f.notifications - before)")
    }

    @MainActor static func d2DismissKeepsSave() async throws {
        let f = try await UnitAFixture.make()
        _ = await f.save(.refused(.io("UNIT-A-D2-IO")))
        f.showAndDismissAlert()
        check(has(f.problem, "UNIT-A-D2-IO"), "D2", "dismissing the alert leaves a save problem: \(String(describing: f.problem))")
    }

    @MainActor static func d3DismissKeepsRead() async throws {
        let f = try await UnitAFixture.make()
        f.inject(.readFailure("UNIT-A-D3-READ"))
        f.showAndDismissAlert()
        check(f.problem == "UNIT-A-D3-READ", "D3", "dismissing the alert leaves a read problem: \(String(describing: f.problem))")
    }

    /// Reading chosen for an open question: an apply problem the alert did not show has not been seen.
    @MainActor static func d4DismissKeepsHiddenApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-D4-APPLY")
        f.inject(refusedSave("UNIT-A-D4-SAVE"))
        let shown = f.showAndDismissAlert()
        check(has(shown, "UNIT-A-D4-SAVE") && has(f.problem, "UNIT-A-D4-SAVE"), "D4a",
            "the alert showed the save problem and it stays: shown=\(String(describing: shown)) problem=\(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(has(f.problem, "UNIT-A-D4-APPLY"), "D4b",
            "the apply problem the alert hid stays after that dismissal: \(String(describing: f.problem))")
    }

    // MARK: Precedence

    @MainActor static func o1PrecedenceReadSaveApply() async throws {
        let f = try await UnitAFixture.make()
        _ = try await f.failApply("UNIT-A-O1-APPLY")
        f.inject(refusedSave("UNIT-A-O1-SAVE"))
        check(has(f.problem, "UNIT-A-O1-SAVE") && !has(f.problem, "UNIT-A-O1-APPLY"), "O1a",
            "save is read before apply: \(String(describing: f.problem))")
        f.inject(.readFailure("UNIT-A-O1-READ"))
        check(f.problem == "UNIT-A-O1-READ", "O1b", "read is read before save and apply: \(String(describing: f.problem))")
        _ = await f.app.coordinator.refresh()
        await f.app.quiescent()
        check(has(f.problem, "UNIT-A-O1-SAVE"), "O1c", "a successful read clears only the read problem: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(has(f.problem, "UNIT-A-O1-APPLY"), "O1d", "with the save cleared the apply problem shows: \(String(describing: f.problem))")
    }

    @MainActor static func o2SaveShownOverLaterApply() async throws {
        let f = try await UnitAFixture.make()
        f.inject(refusedSave("UNIT-A-O2-SAVE"))
        _ = try await f.failApply("UNIT-A-O2-APPLY")
        check(has(f.problem, "UNIT-A-O2-SAVE") && !has(f.problem, "UNIT-A-O2-APPLY"), "O2a",
            "a later apply failure does not replace the save text: \(String(describing: f.problem))")
        let power = await f.live(.setEnabled(true))
        check(power == "completed" && has(f.problem, "UNIT-A-O2-SAVE"), "O2b",
            "a successful live command clears the apply problem only: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        check(f.problem == nil, "O2c", "an accepted command then clears the save problem, leaving none: \(String(describing: f.problem))")
    }

    // MARK: Startup writer (unchanged; not reachable in a normal launch)

    @MainActor static func w1StartupProblemStays() async throws {
        let f = try await UnitAFixture.make()
        f.inject(.startup(.refused(.load("UNIT-A-W1-BOOT"))))
        check(has(f.problem, "UNIT-A-W1-BOOT"), "W1a", "a refused startup still sets a problem: \(String(describing: f.problem))")
        f.inject(acceptedCommand())
        f.inject(acceptedReconciliation())
        f.showAndDismissAlert()
        check(has(f.problem, "UNIT-A-W1-BOOT"), "W1b",
            "the startup problem is not cleared by an accepted command, an accepted reconciliation or a dismissal: \(String(describing: f.problem))")
    }

    // MARK: Quit

    @MainActor static func quitDecisions() {
        check(unitAQuit(after: .startupUnavailable(nil)) == .terminate, "Q1",
            "drain result startupUnavailable(nil): nothing to save, terminate without the save alert")
        let startups: [LibraryConsumerStartup] = [.refused(.destination("UNIT-A-Q2")), .refused(.load("tooLarge")),
            .freshPreparationFailed(.failure("UNIT-A-Q2")), .starting]
        let failedBoots = startups.map { unitAQuit(after: .startupUnavailable($0)) }
        check(failedBoots.allSatisfy { $0 == .terminate }, "Q2",
            "every startupUnavailable(startup) terminates without the save alert: \(failedBoots)")
        check(unitAQuit(after: .saved(commit("UNIT-A-Q3", .committed))) == .terminate, "Q3", "saved terminates, as today")
        let realFailures: [LibraryDrainResult] = [.refused(commit("UNIT-A-Q4", .refused(.io("full")))),
            .refused(commit("UNIT-A-Q4", .refused(.destinationChanged))), .unresolved(nil, "UNIT-A-Q4"), .blocked(nil), .failed("UNIT-A-Q4")]
        let asked = realFailures.map { unitAQuit(after: $0) }
        check(asked.allSatisfy { $0 == .confirmUnsaved }, "Q4",
            "a real save failure at quit still shows today's alert: \(asked)")
        let unchanged: [LibraryDrainResult] = [.discarded, .cancelled, .closed]
        let others = unchanged.map { unitAQuit(after: $0) }
        check(others.allSatisfy { $0 == .confirmUnsaved }, "Q5",
            "discarded, cancelled and closed keep today's alert (nothing else changes): \(others)")
    }

    /// The only wiring check possible without launching the App (pattern: LaunchChecks.bootClaimsBeforeLibraryWork).
    @MainActor static func sourceWiring() {
        let root = ProcessInfo.processInfo.environment["TNF_SOURCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Sources/tap-n-filter/App.swift"), encoding: .utf8) else {
            check(false, "Q6", "App.swift not found for the source check"); return
        }
        func body(_ start: String, until end: String) -> Substring? {
            guard let from = source.range(of: start),
                  let to = source.range(of: end, range: from.upperBound..<source.endIndex) else { return nil }
            return source[from.lowerBound..<to.lowerBound]
        }
        let quit = body("private func requestTermination()", until: "private func argument(")
        check(quit?.contains(unitAQuitDecisionCall) == true, "Q6a",
            "requestTermination() decides through \(unitAQuitDecisionCall)…) instead of an inline switch")
        let show = body("private func showProblem()", until: "func applicationDockMenu(")
        check(show?.contains(unitAPresentCall) == true && show?.contains(unitADismissCall) == true, "Q6b",
            "showProblem() builds its text through \(unitAPresentCall)…) and reports the dismissal through \(unitADismissCall)…)")
    }
}

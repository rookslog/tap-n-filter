// Drives the real session and coordinator through one admission sequence, one model event at a
// time (await-each mode), and records what happened in the model's vocabulary.
//
// Each model event maps to the real producer: menu drags go through
// MenuPresentation.beginGesture/endGesture, moves and clicks through LibraryAppSession.send, editor
// reads through editorQuery with a caller-held operation, barriers through playbackDidChange and
// submitSelect. "Lane change" reproduces the App wiring, where every playback publication calls
// playbackDidChange with its cause.

import Foundation
import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

/// Admission receipts. Admitted and superseded receipts fire synchronously inside `send`, so a send's own
/// receipt is the first one logged after it starts; the action's description is a second check.
/// A failed apply sends a later `.failed` receipt for the same action (moves carry distinct values).
@MainActor final class ReceiptBook {
    private(set) var log: [(key: String, outcome: AOutcome)] = []
    private var waiters: [(mark: Int, key: String, continuation: CheckedContinuation<AOutcome, Never>)] = []
    private(set) var failedKeys: Set<String> = []
    var count: Int { log.count }
    func record(_ action: EverydayMenuAction, _ outcome: AOutcome) {
        let key = String(describing: action)
        if outcome == .failed { failedKeys.insert(key) }
        log.append((key, outcome))
        let index = log.count - 1
        if let w = waiters.firstIndex(where: { index >= $0.mark && $0.key == key }) { waiters.remove(at: w).continuation.resume(returning: outcome) }
    }
    /// Each `.failed` receipt belongs to one send: the earliest send with that key, at or before it, that hasn't
    /// claimed one (applies finish in send order). Identical actions no longer share a failure.
    private var claimed: Set<Int> = []
    func claimFailure(after mark: Int, for key: String) -> Bool {
        guard mark < log.count else { return false }
        for i in mark..<log.count where log[i].key == key && log[i].outcome == .failed && !claimed.contains(i) {
            claimed.insert(i); return true
        }
        return false
    }
    /// The first receipt for `key` logged at or after `mark`.
    func outcome(after mark: Int, for key: String) async -> AOutcome {
        if let hit = log[min(mark, log.count)...].first(where: { $0.key == key }) { return hit.outcome }
        return await withCheckedContinuation { waiters.append((mark, key, $0)) }
    }
}

@MainActor final class ReplyBox {
    private var result: AOutcome?
    private var waiter: CheckedContinuation<AOutcome, Never>?
    func finish(_ value: AOutcome) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value); waiter = nil
    }
    func value() async -> AOutcome {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}
actor SnapshotHolder {
    private(set) var snapshot: LibrarySnapshot?
    func set(_ s: LibrarySnapshot) { snapshot = s }
}

struct EditorReadInFlight {
    let gate: TableGate
    let task: Task<Bool, Never>
}

@MainActor final class AdmissionDriver {
    static let denominator = 37.0
    let f: TableFixture
    let initialCard: MenuSoundCard
    let initialSlider: Double
    let initialChoice: Double
    let otherOptions: [Double]
    var gestures: [Gesture: UUID] = [:]
    var clicks: [(step: Int, option: Double, admitted: Bool)] = []
    var reads: [EditorReadInFlight] = []
    var heldCompletion: EditorReadInFlight?
    var structuralCount = 0
    var writeSteps: [Int] = []          // completion step of each port write
    var notes: [String] = []
    var step = 0
    let receipts = ReceiptBook()
    /// Send-time mode: menu actions go out without waiting; their receipts are collected afterwards.
    var sendTime = false
    var pending: [(index: Int, key: String, mark: Int)] = []
    var lastSentKey: String?

    init(_ f: TableFixture) throws {
        self.f = f
        initialCard = f.shownCard
        guard let s = f.slider(on: initialCard), let c = f.choice(on: initialCard), case .choice(let options) = c.face, options.count >= 3 else {
            throw TableError.setup("first card needs the Softer slider and a choice with three options")
        }
        initialSlider = s.position; initialChoice = c.position
        let scaled = initialSlider * Self.denominator
        guard abs(scaled - scaled.rounded()) > 1e-6 || scaled.rounded() < 1 || scaled.rounded() > Self.denominator - 1 else {
            throw TableError.setup("initial slider value \(initialSlider) collides with a move value")
        }
        otherOptions = options.map(\.position).filter { abs($0 - c.position) > 1e-9 }
        let book = receipts
        Seams.observeAdmissions(f.app) { action, outcome in book.record(action, outcome) }
    }

    func send(_ action: EverydayMenuAction) {
        lastSentKey = String(describing: action)
        switch action {
        case .menuMove(_, _, let address, _, let position), .gestureMove(_, _, _, let address, _, let position):
            // A change: only its own ordered move may take an armed failApply (not a drag commit it flushes first).
            ChangeTag.$current.withValue(ChangeTag.Target(address: address, position: position)) { f.app.send(action) }
        default: f.app.send(action)
        }
    }

    /// Collects the receipts of every action sent since the last collection (send-time mode).
    func collect(into outcomes: inout [AOutcome?]) async {
        guard !pending.isEmpty else { return }
        await f.quiet()
        for p in pending {
            let book = receipts, key = p.key, mark = p.mark
            let first = await watched("receipt for step \(p.index + 1)") { await book.outcome(after: mark, for: key) } ?? AOutcome.none
            outcomes[p.index] = book.claimFailure(after: mark, for: key) ? .failed : first
            if let c = clicks.firstIndex(where: { $0.step == p.index + 1 }) { clicks[c].admitted = outcomes[p.index] == .admitted }
        }
        pending = []
    }

    func sliderValue(_ k: Int) -> Double { Double(k) / Self.denominator }
    func sliderStep(_ p: Double?) -> Int {
        guard let p else { return -1 }
        if abs(p - initialSlider) < 1e-9 { return 0 }
        let scaled = p * Self.denominator, k = scaled.rounded()
        return abs(scaled - k) < 1e-6 && k >= 1 && k < Self.denominator ? Int(k) : -1
    }
    func choiceStep(_ p: Double?) -> Int {
        guard let p else { return -1 }
        if let hit = clicks.last(where: { $0.admitted && abs($0.option - p) < 1e-9 }) { return hit.step }
        if abs(p - initialChoice) < 1e-9 { return 0 }
        return clicks.last(where: { abs($0.option - p) < 1e-9 })?.step ?? -1
    }
    func card(_ c: Card) -> MenuSoundCard { c == .initial ? initialCard : f.shownCard }
    var readProblemShown: Bool {
        guard let p = f.app.problem else { return false }
        return !p.hasPrefix("The change could not be saved")
    }

    /// Sends one menu action and waits for its own outcome signal. `fenced(.noChange)` counts as
    /// superseded: the sample was dropped.
    /// Uses the action's own admission receipt. In send-time mode the receipt is collected later and this
    /// returns a placeholder.
    func reply(_ label: String, _ send: () -> Void) async -> AOutcome {
        lastSentKey = nil
        let mark = receipts.count
        send()
        guard let key = lastSentKey else { notes.append("\(label) at step \(step): nothing was sent"); return .superseded }
        if sendTime { pending.append((step - 1, key, mark)); return AOutcome.none }
        let book = receipts
        let first = await watched("\(label) at step \(step)") { await book.outcome(after: mark, for: key) } ?? .none
        await f.quiet()
        return book.claimFailure(after: mark, for: key) ? .failed : first
    }

    func published(since before: (Int, UInt64?)) -> Bool {
        f.surface.contextChanges != before.0 || f.app.presentationGeneration != before.1
    }
    var publicationMark: (Int, UInt64?) { (f.surface.contextChanges, f.app.presentationGeneration) }

    /// Returns nil for an event this build cannot drive (a missing seam).
    func perform(_ e: AEvent) async -> AOutcome? {
        step += 1
        let value = step
        defer { }
        switch e {
        case .begin(let g):
            // The real producer: beginMovement ends any drag the view holds, then begins a new one.
            f.view.endGesture(); f.view.beginGesture()
            guard case .beginMenuGesture(let id)? = f.surface.actions.last else { notes.append("begin produced no identity"); return .none }
            gestures[g] = id
            if !sendTime { await f.quiet() }
            return AOutcome.none
        case .move(let g, let c):
            let card = card(c)
            guard let id = gestures[g], let identity = card.menuIdentity, let epoch = card.menuEpoch, let s = f.slider(on: card) else {
                notes.append("move at \(step): card has no menu identity or epoch"); return .superseded
            }
            let o = await reply("move") { send(.gestureMove(id, identity, epoch, s.address, s.optionGesture, .scalar(sliderValue(value)))) }
            if !sendTime { await f.quiet() }
            return o
        case .end:
            f.view.endGesture()
            if !sendTime { await f.quiet() }
            return AOutcome.none
        case .click(let c):
            let card = card(c)
            guard let identity = card.menuIdentity, let epoch = card.menuEpoch, let ch = f.choice(on: card) else {
                notes.append("click at \(step): card has no menu identity or epoch"); return .superseded
            }
            let current = clicks.last(where: \.admitted)?.option
            let option = otherOptions.first { current == nil || abs($0 - current!) > 1e-9 } ?? otherOptions[0]
            let o = await reply("click") { send(.menuMove(identity, epoch, ch.address, ch.optionGesture, .scalar(option))) }
            clicks.append((step, option, o == .admitted))   // send-time: fixed up when the receipt is collected
            if !sendTime { await f.quiet() }
            return o
        case .nudge(let c):
            let card = card(c)
            guard let identity = card.menuIdentity, let epoch = card.menuEpoch, let s = f.slider(on: card) else {
                notes.append("step at \(step): card has no menu identity or epoch"); return .superseded
            }
            let o = await reply("keyboard step") { send(.menuMove(identity, epoch, s.address, s.optionGesture, .scalar(sliderValue(value)))) }
            if !sendTime { await f.quiet() }
            return o
        case .holdWrite:
            await f.port.hold(); return AOutcome.none
        case .releaseWrite:
            await f.port.gate.releaseAll(); await f.quiet(); return AOutcome.none
        case .refuseWrite:
            await f.port.refuse(); return AOutcome.none
        case .failApply:
            Seams.failNextApply(f.app.coordinator, f.failNext)   // the fast-path hook, or the menuMove override on ordered routes
            return AOutcome.none
        case .readBegin:
            let gate = TableGate(), holder = SnapshotHolder(), app = f.app
            let task = Task { @MainActor () -> Bool in
                do {
                    _ = try await ReadTag.$current.withValue("editor") {
                        try await app.coordinator.editorQuery { session in
                            let snapshot = try await session.snapshot()
                            await holder.set(snapshot)
                            await gate.pass()
                            return 0
                        }
                    }
                    return true
                } catch { return false }
            }
            _ = await watched("editor read op at step \(step)") { await gate.arrived(after: 0) }
            reads.append(EditorReadInFlight(gate: gate, task: task))
            guard let snapshot = await holder.snapshot, let s = f.slider(on: initialCard), let ch = f.choice(on: initialCard) else { return .observed(Values(slider: -1, choice: -1)) }
            let p = f.positions(snapshot, slider: s, choice: ch)
            await f.quiet()
            return .observed(Values(slider: sliderStep(p.0), choice: choiceStep(p.1)))
        case .readEnd(let oldest, let ok):
            let r = reads.remove(at: oldest ? 0 : reads.count - 1)
            if !ok { await f.reads.armEditorFailure() }
            let mark = publicationMark, attention = f.surface.attentionChanges
            await r.gate.releaseAll()
            _ = await watched("editor read end at step \(step)") { await r.task.value }
            await f.reads.disarm()
            await f.quiet()
            if ok { return published(since: mark) ? .published : .discarded }
            let attempts = await f.reads.attempts, arrivals = await f.reads.menuGate.arrivals
            await f.quiet()
            let attemptsAfter = await f.reads.attempts, arrivalsAfter = await f.reads.menuGate.arrivals
            let retriggered = attemptsAfter != attempts || arrivalsAfter != arrivals
            return .failure(shown: f.surface.attentionChanges != attention && readProblemShown, retriggered: retriggered)
        case .completionHeld:
            let r = reads.removeFirst()
            await f.reads.armCompletionHold()
            let arrivals = await f.reads.completionGate.arrivals
            await r.gate.releaseAll()
            _ = await watched("completion read at step \(step)") { await self.f.reads.completionGate.arrived(after: arrivals) }
            heldCompletion = r
            await f.quiet()
            return AOutcome.none
        case .completionRelease:
            guard let r = heldCompletion else { return AOutcome.none }
            heldCompletion = nil
            let mark = publicationMark
            await f.reads.completionGate.releaseAll()
            _ = await watched("completion publication at step \(step)") { await r.task.value }
            await f.quiet()
            return published(since: mark) ? .published : .discarded
        case .playbackChange:
            Seams.sourceOrFormatChanged(f.app.coordinator)          // a real barrier
            await f.quiet()
            return AOutcome.none
        case .laneChange:
            Seams.lanePublished(f.app.coordinator)                  // a lane publication, not a barrier
            await f.quiet()
            return AOutcome.none
        case .structural:
            structuralCount += 1
            let definition = f.otherDefinitions[structuralCount % 2 == 1 ? 0 : 1]
            let task = f.app.coordinator.submitSelect(definition, on: "test.other"), coordinator = f.app.coordinator
            Task { @MainActor in _ = await task.value; coordinator.requestRefresh() }
            await f.quiet()
            return AOutcome.none
        case .refresh:
            let coordinator = f.app.coordinator
            let ok = await watched("refresh at step \(step)") { await ReadTag.$current.withValue("driver") { await coordinator.refresh() } }
            await f.quiet()
            return ok == true ? .published : .discarded
        case .menuOpen:
            let mark = publicationMark, app = f.app
            let task = ReadTag.$current.withValue("driver") { app.menuOpened() }
            _ = await watched("menu open at step \(step)") { await task.value }
            await f.quiet()
            return published(since: mark) ? .published : .discarded
        }
    }

    /// Call after each event: writes completed so far are stamped with the current step.
    func stampWrites() async {
        let count = await f.port.log.count
        while writeSteps.count < count { writeSteps.append(step) }
    }

    func capture(attentionBefore: Bool, settleStep: Int) async -> ASettled {
        await stampWrites()
        let log = await f.port.log
        var records: [WriteRecord] = []
        for (i, refused) in log.enumerated() { records.append(WriteRecord(step: i < writeSteps.count ? writeSteps[i] : settleStep, refused: refused)) }
        guard let s = f.slider(on: initialCard), let ch = f.choice(on: initialCard) else { fatalError("controls vanished") }
        let saved = (try? await f.reopenedSnapshot()).map { f.positions($0, slider: s, choice: ch) } ?? (nil, nil)
        let live = (try? await f.owner.snapshot()).map { f.positions($0, slider: s, choice: ch) } ?? (nil, nil)
        let shownCard = f.shownCard
        let shown = (f.slider(on: shownCard)?.position, f.choice(on: shownCard)?.position)
        let refused = log.filter { $0 }.count
        let saveProblem = (f.app.problem ?? "").hasPrefix("The change could not be saved")
        return ASettled(saved: Values(slider: sliderStep(saved.0), choice: choiceStep(saved.1)),
                        live: Values(slider: sliderStep(live.0), choice: choiceStep(live.1)),
                        shown: Values(slider: sliderStep(shown.0), choice: choiceStep(shown.1)),
                        attentionBefore: attentionBefore, delivered: [], settleReads: 1, writes: records,
                        saveProblems: saveProblem ? refused : 0, applyProblems: 0)
    }

    func drain() async {
        let app = f.app
        _ = await watched("session quiescent") { await Seams.sessionQuiescent(app) }
        for _ in 0..<3 {
            await f.quiet()
            _ = await watched("issued saves during settle") { await self.f.app.coordinator.waitForIssuedSaves() }
        }
    }

    /// Settles twice on one run: first without the end-of-test flush, then with it.
    func settle() async -> (noFlush: ASettled, flush: ASettled) {
        // Let actions sent without waiting (send-time mode) reach the port before refusals are disarmed.
        await f.quiet()
        let attentionBefore = readProblemShown
        await f.port.disarm(); await f.reads.disarm(); Seams.disarmApplyFailure(f.app.coordinator, f.failNext)
        if let r = heldCompletion {
            heldCompletion = nil
            await f.reads.completionGate.releaseAll()
            _ = await watched("held completion during settle") { await r.task.value }
        }
        while !reads.isEmpty {
            let r = reads.removeFirst()
            await r.gate.releaseAll()
            _ = await watched("in-flight editor read during settle") { await r.task.value }
        }
        await f.port.gate.setOpen(true); await f.debounce.setOpen(true); await f.reads.menuGate.setOpen(true)
        await drain()
        let settleStep = step + 1
        let noFlush = await capture(attentionBefore: attentionBefore, settleStep: settleStep)
        let app = f.app
        _ = await watched("end-of-test flush") { _ = await app.flushSave()?.value }
        await drain()
        let coordinator = f.app.coordinator
        _ = await watched("closing refresh") { await coordinator.refresh() }
        await f.quiet()
        let flush = await capture(attentionBefore: attentionBefore, settleStep: settleStep)
        return (noFlush, flush)
    }
}

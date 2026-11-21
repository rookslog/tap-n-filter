// The count: with no fault armed, how many of a drag's ordered commits come back superseded or throw?
//
// Each run opens a fresh fixture, begins drag G on the dragged app's Softer slider with one admitted sample, then
// plays one sequence over the alphabet below, ends any drag still held and settles. Every sequence of the given
// length is played, in two send modes:
//   await  menu actions (sample, click, keyboard step, end, begin H) each wait for the session to go quiet before the
//          next event; select, remove and the lane callback are left in flight, so each overlaps the next event.
//   send   nothing waits: every event goes out back to back, and the run settles only at the end.
// Every drag commit is counted at the commit site (the coordinator's commit seam), so none can be missed or put
// in the wrong bin; other ordered menu moves are counted in the fixture's override.

import Foundation
import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

enum CountEvent: String, CaseIterable {
    /// One more sample of drag G.
    case move
    /// A pick on the card's parent choice (Place), always a different option that owns a child control.
    case click
    /// A keyboard step on the dragged slider.
    case nudge
    /// Select a different definition on the dragged app (alternates Filters and Everyday).
    case selectDragged
    /// Remove the dragged app's definition (select nil).
    case removeDragged
    /// A lane publication (not a barrier).
    case lane
    /// Release the pointer.
    case end
    /// Begin drag H on the same slider, which ends G, and send one H sample.
    case beginH
}

enum CountMode: String, CaseIterable { case awaitEach = "await", send }

struct ModeTotals {
    var sequences = 0, fixtureFailures = 0, watchdogs = 0, skippedEvents = 0, unfinished = 0, dragStarted = 0
    var drag = Tally(), other = Tally()
    var admitted: [String: Int] = [:], refused: [String: Int] = [:], failed: [String: Int] = [:]
    var whileDragging: [String: Int] = [:]
    var aborted = false
    var examples: [String: String] = [:]
    var firstFixtureError: String?
}

@MainActor final class CountDriver {
    let f: CountFixture
    let mode: CountMode
    var gestureG: UUID?
    var gestureH: UUID?
    var valueStep = 0
    var lastPick: UUID?
    var selectedOther = false
    var inFlight: [@MainActor () async -> Void] = []
    var skipped = 0
    var watchdogs = 0

    init(_ f: CountFixture, mode: CountMode) { self.f = f; self.mode = mode }

    /// Distinct slider values that never equal the starting value (0).
    func nextValue() -> LibraryPosition { valueStep += 1; return .scalar(Double(valueStep % 35 + 1) / 37) }

    func quiet() async {
        let app = f.app
        let ok = await watched("session quiescent") { await app.quiescent() }
        if !ok { watchdogs += 1 }
        for _ in 0..<8 { await Task.yield() }
    }

    func begin() -> UUID? {
        guard let view = f.surface.view else { return nil }
        view.endGesture(); view.beginGesture()
        return f.surface.lastGesture
    }

    /// The dragged control. The child target keeps the child it began on, as a held pointer would, even after a
    /// click has moved the parent off the child's option and the card no longer shows it.
    func dragged(on card: MenuSoundCard) -> (address: LibraryControlAddress, option: LibraryOptionGesture?)? {
        if let child = f.childControl { return (child.address, child.optionGesture) }
        return CountFixture.slider(on: card).map { ($0.address, $0.optionGesture) }
    }

    func sample(_ gesture: UUID?) {
        guard let gesture, let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let s = dragged(on: card) else { skipped += 1; return }
        f.app.send(.gestureMove(gesture, identity, epoch, s.address, s.option, nextValue()))
    }

    func click() {
        guard let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let c = CountFixture.choice(on: card), case .choice(let options) = c.face else { skipped += 1; return }
        // Top target: cycle through the options that own a child, so each pick changes which child control the card
        // has. Child target: cycle through the options that do not own the dragged child, so each pick leaves it
        // inactive. Starting after the last pick holds even when the shown card is behind (send mode).
        let parents = f.childOption.map { owned in options.filter { $0.id != owned } }
            ?? options.filter { !(c.optionChildren[$0.id] ?? []).isEmpty }
        guard !parents.isEmpty else { skipped += 1; return }
        let start = lastPick.flatMap { last in parents.firstIndex { $0.id == last } }.map { $0 + 1 } ?? 0
        var pick = parents[start % parents.count]
        if lastPick == nil, abs(pick.position - c.position) < 1e-9 { pick = parents[(start + 1) % parents.count] }
        lastPick = pick.id
        f.app.send(.menuMove(identity, epoch, c.address, c.optionGesture, .scalar(pick.position)))
    }

    func nudge() {
        guard let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let s = dragged(on: card) else { skipped += 1; return }
        f.app.send(.menuMove(identity, epoch, s.address, s.option, nextValue()))
    }

    func select(_ definition: UUID?) {
        let coordinator = f.app.coordinator
        if coordinator.isDragging { f.counter.whileDragging[definition == nil ? "remove" : "select", default: 0] += 1 }
        let task = coordinator.submitSelect(definition, on: draggedApp)
        // The app requests a refresh when a select finishes; do the same so later events see current cards.
        Task { @MainActor in _ = await task.value; coordinator.requestRefresh() }
        inFlight.append { _ = await task.value }
    }

    func perform(_ e: CountEvent) async {
        switch e {
        case .move: sample(gestureG)
        case .click: click()
        case .nudge: nudge()
        case .selectDragged:
            selectedOther.toggle()
            select(selectedOther ? f.filters : f.everyday)
            return
        case .removeDragged: select(nil); return
        case .lane: f.app.coordinator.playbackDidChange(.lane); return
        case .end: f.surface.view?.endGesture()
        case .beginH:
            gestureH = begin()
            if mode == .awaitEach { await quiet() }
            sample(gestureH)
        }
        if mode == .awaitEach { await quiet() }
    }

    func settle() async {
        for wait in inFlight {
            let ok = await watched("select or remove", wait)
            if !ok { watchdogs += 1 }
        }
        inFlight = []
        f.surface.view?.endGesture()
        for _ in 0..<3 {
            await quiet()
            let coordinator = f.app.coordinator
            let ok = await watched("issued saves") { await coordinator.waitForIssuedSaves() }
            if !ok { watchdogs += 1 }
            for _ in 0..<16 { await Task.yield() }
        }
        await quiet()
    }
}

enum CommitOutcomeCount {
    static func sequences(length: Int) -> [[CountEvent]] {
        var all: [[CountEvent]] = [[]]
        for _ in 0..<length { all = all.flatMap { prefix in CountEvent.allCases.map { prefix + [$0] } } }
        return all
    }

    @MainActor static func run(mode: CountMode, target: DragTarget, length: Int) async -> ModeTotals {
        var t = ModeTotals()
        let all = sequences(length: length), started = Date()
        for (index, sequence) in all.enumerated() {
            let counter = OutcomeCounter()
            let f: CountFixture
            do { f = try await CountFixture(counter: counter, target: target) }
            catch { t.fixtureFailures += 1; if t.firstFixtureError == nil { t.firstFixtureError = "\(error)" }; continue }
            let d = CountDriver(f, mode: mode)
            d.gestureG = d.begin()
            await d.quiet()
            d.sample(d.gestureG)
            await d.quiet()
            for e in sequence { await d.perform(e) }
            await d.settle()
            f.close()

            t.sequences += 1
            t.watchdogs += d.watchdogs; t.skippedEvents += d.skipped
            t.dragStarted += counter.dragStarted; t.unfinished += counter.unfinished
            t.drag.add(counter.drag); t.other.add(counter.other)
            for (k, v) in counter.admitted { t.admitted[k, default: 0] += v }
            for (k, v) in counter.refused { t.refused[k, default: 0] += v }
            for (k, v) in counter.failed { t.failed[k, default: 0] += v }
            for (k, v) in counter.whileDragging { t.whileDragging[k, default: 0] += v }
            let text = "[begin move " + sequence.map(\.rawValue).joined(separator: " ") + " end]"
            if counter.drag.superseded > 0, t.examples["superseded"] == nil { t.examples["superseded"] = text }
            if counter.drag.threw > 0, t.examples["threw"] == nil { t.examples["threw"] = text }
            if counter.unfinished > 0, t.examples["unfinished"] == nil { t.examples["unfinished"] = text }
            if counter.other.threw > 0, t.examples["other threw"] == nil { t.examples["other threw"] = text }
            if d.watchdogs > 0 {
                // A hang fails the run anyway; stop here so the result line prints before the step timeout.
                t.aborted = true
                print("COMMIT-OUTCOMES-ABORT mode=\(mode.rawValue) target=\(target.rawValue) at=\(index + 1) sequence=\(text)")
                break
            }
            if (index + 1) % 128 == 0 {
                print(String(format: "COUNT-PROGRESS mode=%@ target=%@ done=%ld/%ld seconds=%.0f", mode.rawValue, target.rawValue, index + 1, all.count, Date().timeIntervalSince(started)))
            }
        }
        let seconds = Date().timeIntervalSince(started)
        func kinds(_ d: [String: Int]) -> String { ["move", "click", "nudge"].map { "\($0):\(d[$0] ?? 0)" }.joined(separator: ",") }
        let perRun = t.sequences == 0 ? 0 : seconds * 1000 / Double(t.sequences)
        var line = "COMMIT-OUTCOMES mode=\(mode.rawValue) target=\(target.rawValue) length=\(length) sequences=\(t.sequences)"
        line += " drag_commits=\(t.dragStarted) ok=\(t.drag.ok) superseded=\(t.drag.superseded) threw=\(t.drag.threw)"
        line += " unfinished=\(t.unfinished) nochange=\(t.drag.noChange)"
        line += " change_moves=\(t.other.total) change_ok=\(t.other.ok)"
        line += " change_superseded=\(t.other.superseded) change_threw=\(t.other.threw)"
        line += " admitted=\(kinds(t.admitted)) refused=\(kinds(t.refused)) failed=\(kinds(t.failed))"
        let held = ["click", "nudge", "move", "select", "remove"].map { "\($0):\(t.whileDragging[$0] ?? 0)" }.joined(separator: ",")
        line += " while_dragging=\(held)"
        line += " skipped_events=\(t.skippedEvents) watchdogs=\(t.watchdogs) fixture_failures=\(t.fixtureFailures) aborted=\(t.aborted ? 1 : 0)"
        line += String(format: " seconds=%.0f ms_per_run=%.0f", seconds, perRun)
        print(line)
        for (k, v) in t.examples.sorted(by: { $0.key < $1.key }) { print("COMMIT-OUTCOMES-EXAMPLE mode=\(mode.rawValue) target=\(target.rawValue) outcome=\(k) sequence=\(v)") }
        if let e = t.firstFixtureError { print("COMMIT-OUTCOMES-FIXTURE-ERROR mode=\(mode.rawValue) target=\(target.rawValue) first=\(e)") }
        return t
    }

    /// One run with a fault armed on the drag commit at release. The counter must report exactly that one outcome.
    @MainActor static func selfCheck(_ fault: OutcomeCounter.Fault, target: DragTarget = .top) async -> Bool {
        let name = fault == .throwNext ? "throw" : "supersede"
        let counter = OutcomeCounter()
        guard let f = try? await CountFixture(counter: counter, target: target) else {
            print("COMMIT-OUTCOMES-SELFCHECK fault=\(name) target=\(target.rawValue) result=fail reason=fixture"); return false
        }
        let d = CountDriver(f, mode: .awaitEach)
        d.gestureG = d.begin()
        await d.quiet()
        d.sample(d.gestureG)
        await d.quiet()
        counter.fault = fault
        await d.perform(.end)
        await d.settle()
        f.close()
        let expected = fault == .throwNext ? (superseded: 0, threw: 1) : (superseded: 1, threw: 0)
        let pass = counter.dragStarted == 1 && counter.drag.superseded == expected.superseded && counter.drag.threw == expected.threw
            && counter.fault == .off && d.watchdogs == 0
        let consumed = counter.fault == .off
        var line = "COMMIT-OUTCOMES-SELFCHECK fault=\(name) target=\(target.rawValue) drag_commits=\(counter.dragStarted) ok=\(counter.drag.ok)"
        line += " superseded=\(counter.drag.superseded) threw=\(counter.drag.threw) unfinished=\(counter.unfinished)"
        line += " clicked_choice=\(f.choiceTitle) child_owning_options=\(f.choiceParentOptions)"
        line += " fault_consumed=\(consumed) watchdogs=\(d.watchdogs) result=" + (pass ? "pass" : "fail")
        print(line)
        return pass
    }

    /// Fails only when the run cannot be believed: a fault the counter missed, a fixture that did not build, a hang,
    /// a commit that never finished, or no drag commit at all. A non-zero superseded or threw count is the result
    /// and never fails the run.
    @MainActor static func runAll(length: Int) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        var problems: [String] = []
        let checks: [(OutcomeCounter.Fault, DragTarget)] = [(.throwNext, .top), (.supersedeNext, .top), (.throwNext, .child)]
        for (fault, target) in checks {
            let counted = await selfCheck(fault, target: target)
            if !counted { problems.append("self-check \(fault) on \(target) did not count the injected fault") }
        }
        for target in DragTarget.allCases {
          for mode in CountMode.allCases {
            let t = await run(mode: mode, target: target, length: length)
            let label = "\(mode.rawValue) \(target.rawValue)"
            let expected = sequences(length: length).count
            if t.fixtureFailures > 0 { problems.append("\(label): \(t.fixtureFailures) fixtures did not build") }
            if t.aborted { problems.append("\(label): stopped at the first hang") }
            if t.sequences != expected { problems.append("\(label): ran \(t.sequences) of \(expected) sequences") }
            if t.watchdogs > 0 { problems.append("\(label): \(t.watchdogs) watchdog firings") }
            if t.unfinished != 0 { problems.append("\(label): \(t.unfinished) drag commits never finished") }
            if t.dragStarted == 0 { problems.append("\(label): no drag commit happened, so a zero would be vacuous") }
          }
        }
        if !problems.isEmpty {
            for p in problems { print("COMMIT-OUTCOMES-RUN-PROBLEM \(p)") }
            throw CountError(description: problems.joined(separator: "; "))
        }
    }
}

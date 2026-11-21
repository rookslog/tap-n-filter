// The healthy-path count: with no fault armed, a drag's ordered commit never comes back superseded or throws, the
// discard epoch never moves, no value write is dropped as stale, and no activation is left pending at rest.
//
// Each run opens a fresh fixture, begins drag G with one admitted sample, plays one sequence of the alphabet below,
// ends any drag still held and settles. Every sequence of length 3 is played in two send modes and for two drag
// targets:
//   await  menu actions (sample, click, keyboard step, end, begin H) each wait for the session to go quiet; select,
//          remove and the lane callback are left in flight, so each overlaps the next event.
//   send   nothing waits until the run settles.
//   top    G holds the Softer slider; a click moves Place to another option that owns a child control.
//   child  G holds the child slider of Place's current option; every click moves Place off that option.

import Foundation
import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

enum ResetEvent: String, CaseIterable { case move, click, nudge, selectDragged, removeDragged, lane, end, beginH }

enum ResetMode: String, CaseIterable { case awaitEach = "await", send }

@MainActor final class ResetDriver {
    let f: ResetFixture
    let mode: ResetMode
    var gestureG: UUID?
    var gestureH: UUID?
    var valueStep = 0
    private(set) var lastValue: Double?
    var lastPick: UUID?
    var selectedOther = false
    var inFlight: [@MainActor () async -> Void] = []
    var skipped = 0
    var watchdogs = 0

    init(_ f: ResetFixture, mode: ResetMode) { self.f = f; self.mode = mode }

    /// Distinct slider values that never equal the starting value (0) or the children's starting value (0.5).
    func nextValue() -> LibraryPosition {
        valueStep += 1
        let value = Double(valueStep % 35 + 1) / 37
        lastValue = value
        return .scalar(value)
    }

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

    /// The dragged control. The child target keeps the child it began on, as a held pointer would.
    func dragged(on card: MenuSoundCard) -> (address: LibraryControlAddress, option: LibraryOptionGesture?)? {
        if let child = f.childControl { return (child.address, child.optionGesture) }
        return ResetFixture.slider(on: card).map { ($0.address, $0.optionGesture) }
    }
    var draggedAddress: LibraryControlAddress? { f.observer.draggedAddress }

    func sample(_ gesture: UUID?) {
        guard let gesture, let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let s = dragged(on: card) else { skipped += 1; return }
        f.app.send(.gestureMove(gesture, identity, epoch, s.address, s.option, nextValue()))
    }

    /// A drag sample on another top-level slider of the same card, under the same gesture.
    func sample(_ gesture: UUID?, on title: String) {
        guard let gesture, let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let s = ResetFixture.slider(on: card, title: title) else { skipped += 1; return }
        f.app.send(.gestureMove(gesture, identity, epoch, s.address, s.optionGesture, nextValue()))
    }

    func click() {
        guard let card = f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch,
              let c = ResetFixture.choice(on: card), case .choice(let options) = c.face else { skipped += 1; return }
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

    func select(_ definition: UUID?, on target: String = draggedApp) {
        let coordinator = f.app.coordinator
        if target == draggedApp, coordinator.isDragging {
            f.observer.whileDragging[definition == nil ? "remove" : "select", default: 0] += 1
        }
        let task = coordinator.submitSelect(definition, on: target)
        // The app requests a refresh when a select finishes; do the same so later events see current cards.
        Task { @MainActor in _ = await task.value; coordinator.requestRefresh() }
        inFlight.append { _ = await task.value }
    }

    func perform(_ e: ResetEvent) async {
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

    /// Begins G and sends its first sample. Returns whether that sample went live.
    func beginG() async -> Bool {
        gestureG = begin()
        await quiet()
        let before = f.observer.liveSamples
        sample(gestureG)
        await quiet()
        return f.observer.liveSamples > before
    }
}

struct ResetTotals {
    var sequences = 0, fixtureFailures = 0, watchdogs = 0, skippedEvents = 0
    var commits = Tally(), ordered = Tally()
    var thrownResets = 0, supersededResets = 0, staleDrops = 0
    var epochMoved = 0, activationLeftPending = 0, firstSampleLive = 0, withoutCommit = 0
    var orderedSupersededDragged = 0, orderedSupersededChoice = 0, orderedSupersededOther = 0
    var admitted: [String: Int] = [:], refused: [String: Int] = [:], whileDragging: [String: Int] = [:]
    var examples: [String: String] = [:]
    var firstFixtureError: String?
    var aborted = false
}

enum ResetCount {
    static func sequences(length: Int) -> [[ResetEvent]] {
        var all: [[ResetEvent]] = [[]]
        for _ in 0..<length { all = all.flatMap { prefix in ResetEvent.allCases.map { prefix + [$0] } } }
        return all
    }

    @MainActor static func run(mode: ResetMode, target: DragTarget, length: Int) async -> ResetTotals {
        var t = ResetTotals()
        let all = sequences(length: length), started = Date()
        for (index, sequence) in all.enumerated() {
            let observer = ResetObserver()
            let f: ResetFixture
            do { f = try await ResetFixture(target: target, observer: observer, fault: FaultArm()) }
            catch { t.fixtureFailures += 1; if t.firstFixtureError == nil { t.firstFixtureError = "\(error)" }; continue }
            let d = ResetDriver(f, mode: mode)
            if await d.beginG() { t.firstSampleLive += 1 }
            for e in sequence { await d.perform(e) }
            await d.settle()
            let unmoved = f.epochUnmoved
            let pending = f.app.coordinator.activationPendingForTesting
            f.close()

            t.sequences += 1
            t.watchdogs += d.watchdogs; t.skippedEvents += d.skipped
            t.commits.add(observer.commits); t.ordered.add(observer.ordered)
            t.thrownResets += observer.thrownResets; t.supersededResets += observer.supersededResets
            t.staleDrops += observer.staleDrops
            if !unmoved { t.epochMoved += 1 }
            if pending { t.activationLeftPending += 1 }
            if observer.commits.total + observer.thrownResets == 0 { t.withoutCommit += 1 }
            t.orderedSupersededDragged += observer.orderedSupersededDragged
            t.orderedSupersededChoice += observer.orderedSupersededChoice
            t.orderedSupersededOther += observer.orderedSupersededOther
            for (k, v) in observer.admitted { t.admitted[k, default: 0] += v }
            for (k, v) in observer.refused { t.refused[k, default: 0] += v }
            for (k, v) in observer.whileDragging { t.whileDragging[k, default: 0] += v }
            let text = "[begin move " + sequence.map(\.rawValue).joined(separator: " ") + " end]"
            func example(_ key: String, _ hit: Bool) { if hit, t.examples[key] == nil { t.examples[key] = text } }
            example("superseded", observer.commits.superseded > 0)
            example("threw", observer.thrownResets > 0)
            example("epoch moved", !unmoved)
            example("stale drop", observer.staleDrops > 0)
            example("activation pending", pending)
            if d.watchdogs > 0 {
                t.aborted = true
                print("COMMIT-RESET-ABORT mode=\(mode.rawValue) target=\(target.rawValue) at=\(index + 1) sequence=\(text)")
                break
            }
        }
        let seconds = Date().timeIntervalSince(started)
        print(line(t, mode: mode, target: target, length: length, seconds: seconds))
        for (k, v) in t.examples.sorted(by: { $0.key < $1.key }) {
            print("COMMIT-RESET-EXAMPLE mode=\(mode.rawValue) target=\(target.rawValue) outcome=\(k) sequence=\(v)")
        }
        if let e = t.firstFixtureError { print("COMMIT-RESET-FIXTURE-ERROR mode=\(mode.rawValue) target=\(target.rawValue) first=\(e)") }
        return t
    }

    static func line(_ t: ResetTotals, mode: ResetMode, target: DragTarget, length: Int, seconds: Double) -> String {
        func kinds(_ d: [String: Int], _ keys: [String]) -> String { keys.map { "\($0):\(d[$0] ?? 0)" }.joined(separator: ",") }
        // Drag commits reach the session through the override too; the rest of the ordered moves are the changes' own.
        let changeSupersededDragged = t.orderedSupersededDragged - t.commits.superseded
        let perRun = t.sequences == 0 ? 0 : seconds * 1000 / Double(t.sequences)
        var s = "COMMIT-RESET mode=\(mode.rawValue) target=\(target.rawValue) length=\(length) sequences=\(t.sequences)"
        s += " drag_commits=\(t.commits.total + t.thrownResets) ok=\(t.commits.ok)"
        s += " superseded=\(t.commits.superseded) threw=\(t.thrownResets)"
        s += " resets=\(t.thrownResets + t.supersededResets) epoch_moved=\(t.epochMoved) stale_drops=\(t.staleDrops)"
        s += " activation_left_pending=\(t.activationLeftPending)"
        s += " change_superseded_dragged=\(changeSupersededDragged) change_superseded_choice=\(t.orderedSupersededChoice)"
        s += " change_superseded_other=\(t.orderedSupersededOther)"
        s += " g_first_sample_live=\(t.firstSampleLive) sequences_without_drag_commit=\(t.withoutCommit)"
        s += " admitted=\(kinds(t.admitted, ["move", "click", "nudge"])) refused=\(kinds(t.refused, ["move", "click", "nudge"]))"
        s += " while_dragging=\(kinds(t.whileDragging, ["click", "nudge", "move", "select", "remove"]))"
        s += " skipped_events=\(t.skippedEvents) watchdogs=\(t.watchdogs) fixture_failures=\(t.fixtureFailures)"
        s += " aborted=\(t.aborted ? 1 : 0)"
        s += String(format: " seconds=%.0f ms_per_run=%.0f", seconds, perRun)
        return s
    }

    /// The test for one mode and target: every healthy-path invariant, and a run that can be believed.
    @MainActor static func check(mode: ResetMode, target: DragTarget, length: Int = 3) async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let t = await run(mode: mode, target: target, length: length)
        var problems: [String] = []
        let expected = sequences(length: length).count
        if t.commits.superseded != 0 { problems.append("\(t.commits.superseded) drag commits came back superseded with no fault armed") }
        if t.thrownResets != 0 { problems.append("\(t.thrownResets) drag commits threw with no fault armed") }
        if t.epochMoved != 0 { problems.append("the discard epoch moved in \(t.epochMoved) runs with no fault armed") }
        if t.staleDrops != 0 { problems.append("\(t.staleDrops) value writes were dropped as stale with no fault armed") }
        if t.activationLeftPending != 0 { problems.append("an activation was still pending at rest in \(t.activationLeftPending) runs") }
        if t.fixtureFailures > 0 { problems.append("\(t.fixtureFailures) fixtures did not build") }
        if t.aborted || t.watchdogs > 0 { problems.append("a run hung (\(t.watchdogs) watchdog firings)") }
        if t.sequences != expected { problems.append("ran \(t.sequences) of \(expected) sequences") }
        if t.commits.total == 0 { problems.append("no drag commit happened, so the zeros would be vacuous") }
        if !problems.isEmpty { throw ResetError(description: "\(mode.rawValue) \(target.rawValue): " + problems.joined(separator: "; ")) }
    }

    /// One run with a fault armed on the drag commit at release. The observers must report exactly that one outcome
    /// and one reset. A sample that never went live holds nothing to commit, which is reported as its own result.
    @MainActor static func selfCheck(_ kind: FaultArm.Kind, target: DragTarget) async throws {
        let name = kind == .throwIt ? "throw" : "supersede"
        let observer = ResetObserver(), fault = FaultArm()
        let f = try await ResetFixture(target: target, observer: observer, fault: fault)
        let d = ResetDriver(f, mode: .awaitEach)
        let live = await d.beginG()
        if let address = d.draggedAddress, let value = d.lastValue { fault.arm(kind, address: address, value: value) }
        await d.perform(.end)
        await d.settle()
        let moved = f.epochMovedOnce
        f.close()
        let thrown = kind == .throwIt
        let pass = live && fault.fired == 1 && observer.resets == 1 && moved && d.watchdogs == 0
            && observer.thrownResets == (thrown ? 1 : 0) && observer.commits.superseded == (thrown ? 0 : 1)
        var s = "COMMIT-RESET-SELFCHECK fault=\(name) target=\(target.rawValue) first_sample_live=\(live)"
        s += " fired=\(fault.fired) resets=\(observer.resets) thrown=\(observer.thrownResets)"
        s += " superseded=\(observer.commits.superseded) epoch_moved_once=\(moved) watchdogs=\(d.watchdogs)"
        s += " result=" + (pass ? "pass" : live ? "fail" : "no_drag_commit reason=sample_not_live")
        print(s)
        if live && !pass { throw ResetError(description: "self-check \(name) on \(target.rawValue) did not see the injected fault") }
    }
}

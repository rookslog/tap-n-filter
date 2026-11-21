// Cases for what happens when a drag's ordered commit throws or comes back superseded (a fault injected into that one
// commit by the fixture's override), and for what a refused value write does on the healthy path.

import Foundation
import SoundModel
@testable import EverydayMenu
import PlaybackRenderBridge
@testable import tap_n_filter

struct Expect {
    let name: String
    private(set) var failures: [String] = []
    init(_ name: String) { self.name = name }
    mutating func that(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }
    func done() throws {
        print("COMMIT-RESET-CASE \(name) " + (failures.isEmpty ? "pass" : "fail: " + failures.joined(separator: "; ")))
        if !failures.isEmpty { throw ResetError(description: "\(name): " + failures.joined(separator: "; ")) }
    }
}

/// A fixture with drag G begun on the Softer slider and one live sample, and the values it started from.
@MainActor final class ResetScene {
    let observer: ResetObserver
    let fault: FaultArm
    let f: ResetFixture
    let d: ResetDriver
    let dragged: LibraryControlAddress
    let choice: LibraryControlAddress
    let volume: LibraryControlAddress
    let binding: LibraryBinding
    let startDragged: Double?, startChoice: Double?, startVolume: Double?

    init(target: DragTarget = .top) async throws {
        let observer = ResetObserver(), fault = FaultArm()
        let f = try await ResetFixture(target: target, observer: observer, fault: fault)
        let d = ResetDriver(f, mode: .awaitEach)
        guard let dragged = observer.draggedAddress, let card = f.shownCard, let binding = card.binding,
              let volume = ResetFixture.slider(on: card, title: "Volume")?.address else {
            throw ResetError(description: "scene setup: the card lacks a dragged slider, a binding or Volume")
        }
        let startDragged = await f.documentValue(dragged)
        let startChoice = await f.documentValue(f.choiceAddress)
        let startVolume = await f.documentValue(volume)
        guard await d.beginG() else { throw ResetError(description: "scene setup: drag G's first sample did not go live") }
        self.observer = observer; self.fault = fault; self.f = f; self.d = d
        self.dragged = dragged; self.binding = binding; self.volume = volume; choice = f.choiceAddress
        self.startDragged = startDragged; self.startChoice = startChoice; self.startVolume = startVolume
    }

    /// Arms one fault on G's commit, which will write G's last live sample.
    func armCommit(_ kind: FaultArm.Kind) {
        if let value = d.lastValue { fault.arm(kind, address: dragged, value: value) }
    }
    func shown(_ address: LibraryControlAddress) -> Double? {
        guard let card = f.shownCard else { return nil }
        return (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.address == address }?.position
    }
    /// What playback holds last equals the document the menu now presents.
    var playbackMatchesDocument: Bool {
        guard let last = observer.deliveries.last?.snapshot, let document = f.app.neutral else { return false }
        return last == document
    }
    var applyProblemShown: Bool { f.app.problem?.hasPrefix("The change could not be saved") == true }
    /// The document, the saved bytes and the menu all still hold the value a control started with.
    func unchanged(_ address: LibraryControlAddress, _ start: Double?, _ label: String, into e: inout Expect) async {
        let live = await f.documentValue(address), saved = await f.savedValue(address)
        e.that(live == start, "\(label): the document holds \(String(describing: live)), not \(String(describing: start))")
        e.that(saved == start, "\(label): the saved bytes hold \(String(describing: saved)), not \(String(describing: start))")
        if let start { e.that(shown(address).map { abs($0 - start) < 1e-9 } ?? false, "\(label): the menu shows \(String(describing: shown(address)))") }
    }
    func close() { f.close() }
}

enum ResetRules {
    /// A pick admitted before the flush it causes; the flush's drag commit throws.
    @MainActor static func thrownCommitAtAPick() async throws {
        var e = Expect("thrown-commit-at-a-pick")
        let s = try await ResetScene()
        s.armCommit(.throwIt)
        let completed = s.observer.completed.count, debounces = s.observer.debounces, activations = s.observer.activations
        s.d.click()
        await s.d.settle()
        e.that(s.fault.fired == 1, "the fault was not consumed by the drag commit")
        e.that(s.observer.thrownResets == 1 && s.observer.supersededResets == 0, "resets: thrown \(s.observer.thrownResets), superseded \(s.observer.supersededResets)")
        e.that(s.f.epochMovedOnce, "the discard epoch did not move exactly once")
        e.that(s.observer.staleDrops >= 1, "the pick was not dropped as stale")
        e.that(!s.f.app.coordinator.isDragging, "the drag is still open")
        await s.unchanged(s.dragged, s.startDragged, "dragged slider", into: &e)
        await s.unchanged(s.choice, s.startChoice, "picked choice", into: &e)
        e.that(s.observer.problemAppearances == 1, "the problem appeared \(s.observer.problemAppearances) times")
        e.that(s.applyProblemShown, "the problem shown is \(String(describing: s.f.app.problem))")
        let after = Array(s.observer.completed.dropFirst(completed))
        e.that(after == [.superseded], "the refused pick reported \(after), not one superseded")
        e.that(s.observer.debounces == debounces, "the refused pick armed a debounced save")
        e.that(s.observer.activations > activations, "no activation reached playback after the reset")
        e.that(s.playbackMatchesDocument, "playback does not hold the document")
        e.that(!s.f.app.coordinator.activationPendingForTesting, "an activation is still pending at rest")
        // The held pointer moves nothing until it is pressed again.
        let refusedMoves = s.observer.refused["move"] ?? 0
        s.d.sample(s.d.gestureG)
        await s.d.quiet()
        e.that((s.observer.refused["move"] ?? 0) == refusedMoves + 1, "a sample from the held pointer was admitted")
        await s.unchanged(s.dragged, s.startDragged, "dragged slider after the held sample", into: &e)
        // An apply problem clears on the next change that goes through.
        s.f.app.send(.compare(true))
        await s.d.quiet()
        e.that(s.f.app.problem == nil, "the apply problem did not clear after a compare went through")
        s.f.app.send(.compare(false))
        await s.d.settle()
        s.close()
        try e.done()
    }

    /// The same pick; the drag commit comes back superseded. Nothing is shown and the pick is still dropped.
    @MainActor static func supersededCommitAtAPick() async throws {
        var e = Expect("superseded-commit-at-a-pick")
        let s = try await ResetScene()
        s.armCommit(.supersede)
        let activations = s.observer.activations
        s.d.click()
        await s.d.settle()
        e.that(s.fault.fired == 1, "the fault was not consumed by the drag commit")
        e.that(s.observer.supersededResets == 1 && s.observer.thrownResets == 0, "resets: superseded \(s.observer.supersededResets), thrown \(s.observer.thrownResets)")
        e.that(s.observer.commits.superseded == 1, "the commit callback saw \(s.observer.commits.superseded) superseded commits")
        e.that(s.f.epochMovedOnce, "the discard epoch did not move exactly once")
        e.that(s.observer.staleDrops >= 1, "the pick was not dropped as stale")
        e.that(s.observer.problemAppearances == 0 && s.f.app.problem == nil, "a problem was shown: \(String(describing: s.f.app.problem))")
        await s.unchanged(s.dragged, s.startDragged, "dragged slider", into: &e)
        await s.unchanged(s.choice, s.startChoice, "picked choice", into: &e)
        e.that(s.observer.activations > activations, "no activation reached playback after the reset")
        e.that(s.playbackMatchesDocument, "playback does not hold the document")
        s.close()
        try e.done()
    }

    /// Samples on another slider under the same drag, queued behind a flush whose commit throws.
    ///
    /// All three are sent in one main-actor turn, before the batch task runs. The first creates the batch with itself
    /// pending; each later one replaces the pending request, which completes as coalesced and is never written. The batch
    /// task then takes only the last sample: its flush commits G (the fault throws), the reset moves the epoch, and the
    /// sample is dropped as stale after that await. So the product's count is two coalesced, one dropped: one stale drop
    /// and one superseded completion (coalesced requests report nothing to the session's measurement callback).
    @MainActor static func queuedSamplesAfterAThrownCommit() async throws {
        var e = Expect("queued-samples-after-a-thrown-commit")
        // Through the session, as the menu sends them: what the session does with each outcome.
        do {
            let s = try await ResetScene()
            s.armCommit(.throwIt)
            let completed = s.observer.completed.count, debounces = s.observer.debounces, live = s.observer.liveSamples
            s.d.sample(s.d.gestureG, on: "Volume"); s.d.sample(s.d.gestureG, on: "Volume"); s.d.sample(s.d.gestureG, on: "Volume")
            await s.d.settle()
            e.that(s.fault.fired == 1 && s.observer.thrownResets == 1, "session: the commit did not throw once (fired \(s.fault.fired))")
            e.that(s.observer.staleDrops == 1, "session: \(s.observer.staleDrops) stale drops, expected 1 (two samples coalesced, one dropped)")
            let after = Array(s.observer.completed.dropFirst(completed))
            e.that(after == [.superseded], "session: the measurement callback saw \(after), expected one superseded")
            e.that(s.observer.liveSamples == live, "session: a queued sample was delivered live")
            await s.unchanged(s.volume, s.startVolume, "session: Volume", into: &e)
            await s.unchanged(s.dragged, s.startDragged, "session: dragged slider", into: &e)
            e.that(s.observer.debounces == debounces, "session: a queued sample armed a debounced save")
            e.that(s.observer.problemAppearances == 1, "session: the problem appeared \(s.observer.problemAppearances) times")
            e.that(s.playbackMatchesDocument, "session: playback does not hold the document")
            s.close()
        }
        // Straight to the coordinator, keeping each sample's own task: every queued sample is accounted for by outcome.
        do {
            let s = try await ResetScene()
            s.armCommit(.throwIt)
            let live = s.observer.liveSamples
            guard let card = s.f.shownCard, let identity = card.menuIdentity, let epoch = card.menuEpoch, let gesture = s.d.gestureG else {
                throw ResetError(description: "direct: the card has no menu identity or the drag has no identity")
            }
            let coordinator = s.f.app.coordinator
            var tasks: [Task<LibrarySliderResult, Error>] = []
            for _ in 0..<3 {
                tasks.append(try coordinator.submitSliderMove(s.volume, expected: s.binding, to: s.d.nextValue(),
                    menuIdentity: identity, expectedEpoch: epoch, gestureIdentity: gesture))
            }
            var outcomes: [String] = []
            for task in tasks {
                switch await task.result {
                case .success(.coalesced): outcomes.append("coalesced")
                case .success(.dropped): outcomes.append("dropped")
                case .success(let other): outcomes.append("other(\(other))")
                case .failure(let error): outcomes.append("threw(\(error))")
                }
            }
            await s.d.settle()
            e.that(s.fault.fired == 1 && s.observer.thrownResets == 1, "direct: the commit did not throw once (fired \(s.fault.fired))")
            e.that(outcomes == ["coalesced", "coalesced", "dropped"], "direct: the queued samples ended \(outcomes)")
            e.that(s.observer.staleDrops == 1, "direct: \(s.observer.staleDrops) stale drops, expected 1")
            e.that(s.observer.liveSamples == live, "direct: a queued sample was delivered live")
            await s.unchanged(s.volume, s.startVolume, "direct: Volume", into: &e)
            e.that(s.playbackMatchesDocument, "direct: playback does not hold the document")
            s.close()
        }
        try e.done()
    }

    /// An ordered move (the binding-only `move`) admitted before the flush it causes; that flush's commit throws.
    @MainActor static func orderedMoveAfterAThrownCommit() async throws {
        var e = Expect("ordered-move-after-a-thrown-commit")
        let s = try await ResetScene()
        s.armCommit(.throwIt)
        let coordinator = s.f.app.coordinator, address = s.volume, binding = s.binding
        let move = Task { @MainActor () -> Bool in
            do { _ = try await coordinator.move(address, expected: binding, to: .scalar(0.9)); return false }
            catch is LibraryFlushRefusal { return true }
            catch { return false }
        }
        let refusedAsStale = await move.value
        await s.d.settle()
        e.that(s.fault.fired == 1 && s.observer.thrownResets == 1, "the commit did not throw once (fired \(s.fault.fired))")
        e.that(refusedAsStale, "the ordered move was not refused as stale")
        e.that(s.observer.staleDrops >= 1, "no stale drop was reported")
        await s.unchanged(s.volume, s.startVolume, "Volume", into: &e)
        s.close()
        try e.done()
    }

    /// Power, compare and quit go through when the flush they cause throws.
    @MainActor static func powerCompareAndQuitAfterAThrownCommit() async throws {
        var e = Expect("power-compare-quit-after-a-thrown-commit")
        do {
            let s = try await ResetScene()
            s.armCommit(.throwIt)
            s.f.app.send(.setEnabled(false))
            await s.d.settle()
            let enabled = try? await s.observer.owner?.liveState().isEnabled
            e.that(s.observer.thrownResets == 1, "power: the commit did not throw once")
            e.that(enabled == false, "power: OFF did not take effect")
            e.that(s.observer.problemAppearances == 1, "power: the problem appeared \(s.observer.problemAppearances) times")
            s.close()
        }
        do {
            let s = try await ResetScene()
            s.armCommit(.throwIt)
            s.f.app.send(.compare(true))
            await s.d.settle()
            let comparing = try? await s.observer.owner?.liveState().compareOriginal
            e.that(s.observer.thrownResets == 1, "compare: the commit did not throw once")
            e.that(comparing == true, "compare: the press did not take effect")
            s.close()
        }
        do {
            let s = try await ResetScene()
            s.armCommit(.throwIt)
            s.f.app.beginDrain()
            let result = await s.f.app.finishDrain(.save)
            if case .saved = result {} else { e.that(false, "quit: the drain ended \(result)") }
            e.that(s.observer.thrownResets == 1, "quit: the commit did not throw once")
            let saved = await s.f.savedValue(s.dragged)
            e.that(saved == s.startDragged, "quit: the saved bytes hold \(String(describing: saved)), not the committed value")
            s.close()
        }
        try e.done()
    }

    /// A structural command is refused when its flush throws and proceeds when it is superseded.
    @MainActor static func structuralCommandAfterAFailedCommit() async throws {
        var e = Expect("structural-command-after-a-failed-commit")
        for kind in [FaultArm.Kind.throwIt, .supersede] {
            let label = kind == .throwIt ? "thrown" : "superseded"
            let s = try await ResetScene()
            s.armCommit(kind)
            let result = await s.f.app.coordinator.submitSelect(s.f.everyday, on: otherApp).value
            s.f.app.coordinator.requestRefresh()
            await s.d.settle()
            let shown = s.f.surface.view?.snapshot.assignments.first { $0.bundleIdentifier == otherApp }?.definitionID
            e.that(s.fault.fired == 1, "\(label): the fault was not consumed")
            if kind == .throwIt {
                e.that(result.flushRefused, "thrown: the select was not refused")
                e.that(shown == s.f.filters, "thrown: the other app's sound changed")
                e.that(s.observer.problemAppearances == 1, "thrown: the problem appeared \(s.observer.problemAppearances) times")
            } else {
                if case .accepted = result.outcome {} else { e.that(false, "superseded: the select ended \(result.outcome)") }
                e.that(!result.flushRefused, "superseded: the select was marked refused")
                e.that(shown == s.f.everyday, "superseded: the other app's sound did not change")
                e.that(s.observer.problemAppearances == 0, "superseded: a problem was shown")
            }
            s.close()
        }
        try e.done()
    }

    /// On the healthy path, a value write refused at admission reports superseded to the measurement callback and does
    /// nothing else: no read, no debounce, no save, no problem.
    @MainActor static func refusedWriteDoesNothingElse() async throws {
        var e = Expect("refused-write-does-nothing-else")
        let s = try await ResetScene()
        await s.d.perform(.end)
        await s.d.settle()
        let completed = s.observer.completed.count, reads = s.observer.reads, debounces = s.observer.debounces
        let writes = await s.f.port.writes
        s.d.sample(s.d.gestureG)        // the pointer was released: this sample is refused
        await s.d.quiet()
        for _ in 0..<32 { await Task.yield() }
        let after = Array(s.observer.completed.dropFirst(completed))
        e.that(after == [.superseded], "the refused sample reported \(after)")
        e.that(s.observer.reads == reads, "the refused sample caused \(s.observer.reads - reads) reads")
        e.that(s.observer.debounces == debounces, "the refused sample armed a debounced save")
        let writesAfter = await s.f.port.writes
        e.that(writesAfter == writes, "the refused sample caused \(writesAfter - writes) writes")
        e.that(s.f.app.problem == nil, "a problem was shown")
        e.that(s.f.epochUnmoved && s.observer.staleDrops == 0, "the healthy path moved the epoch or dropped a write as stale")
        s.close()
        try e.done()
    }

    /// A superseded commit during a structural command whose write is held: the correction's read lands while that
    /// command's barrier is up, so playback is only restricted; the activation is asked for again when the last barrier
    /// ends, and reaches playback once.
    @MainActor static func activationAskedAgainWhenTheLastBarrierEnds() async throws {
        var e = Expect("activation-asked-again-when-the-last-barrier-ends")
        let s = try await ResetScene()
        s.armCommit(.supersede)
        await s.f.port.holdNextWrite()
        let activations = s.observer.activations, reads = s.observer.reads
        let select = s.f.app.coordinator.submitSelect(s.f.everyday, on: otherApp)
        // Wait for the fault, the held write and the reset's own read; nothing here can use quiescence while a write is held.
        var parked = 0
        for _ in 0..<2000 {
            await Task.yield()
            parked = await s.f.port.parked
            if s.fault.fired == 1, parked == 1, s.observer.reads > reads { break }
        }
        for _ in 0..<64 { await Task.yield() }
        e.that(s.fault.fired == 1 && parked == 1 && s.observer.reads > reads,
               "setup: fired \(s.fault.fired), parked \(parked), reads \(s.observer.reads - reads)")
        e.that(s.observer.activations == activations, "an activation reached playback while the barrier was up")
        e.that(s.f.app.coordinator.activationPendingForTesting, "the activation was not left pending while the barrier was up")
        await s.f.port.release()
        _ = await select.value
        await s.d.settle()
        e.that(s.observer.activations == activations + 1, "\(s.observer.activations - activations) activations reached playback after the barrier ended")
        e.that(!s.f.app.coordinator.activationPendingForTesting, "an activation is still pending at rest")
        e.that(s.playbackMatchesDocument, "playback does not hold the document")
        s.close()
        try e.done()
    }
}

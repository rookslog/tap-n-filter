// S5, lane life through the coordinator: user actions (power, slider steps) go through the real
// session and coordinator; the coordinator's playback deliveries reach the real PlaybackController
// with the App's wiring (activation -> apply, positions -> updatePositions, a full-delivery request
// or any controller change -> playbackDidChange). Starts and stops are held in the fakes as in S4.
//
// Every delivery is recorded and translated into the lane model's events, so the run says which
// delivery orders the coordinator really produces. In particular it says whether a positions-only
// power ON reaches the controller after an OFF with no activation ON in between (B3/B-F10).

import Foundation
import SoundModel
@testable import EverydayMenu
import PlaybackLifecycle
import PlaybackRuntime
@testable import PlaybackOutput
@testable import tap_n_filter

enum S5Action: Hashable, CustomStringConvertible {
    case powerOn, powerOff, slider, startOk, startFail, stopDone, retry
    /// The document returns to an earlier snapshot (the slider goes back to its starting value, an outside revision),
    /// and the coordinator delivers it through the other mode than the last delivery (an A/B/A order).
    case returnEarlier
    var description: String {
        switch self {
        case .powerOn: return "powerON"
        case .powerOff: return "powerOFF"
        case .slider: return "slider"
        case .startOk: return "startOk"
        case .startFail: return "startFail"
        case .stopDone: return "stopDone"
        case .retry: return "retry"
        case .returnEarlier: return "returnEarlier"
        }
    }
    /// What the model expects the action to deliver (power OFF arrives as positions, then activation).
    var macro: [BEvent] {
        switch self {
        case .powerOn: return [.activation(on: true)]
        case .powerOff: return [.positions(on: false), .activation(on: false)]
        case .slider: return [.parameters]
        case .startOk: return [.startCompletes(ok: true)]
        case .startFail: return [.startCompletes(ok: false)]
        case .stopDone: return [.stopCompletes]
        case .retry: return [.retry]
        case .returnEarlier: return [.parameters]           // a value change: it must not start or stop sound
        }
    }
}
let s5Alphabet: [S5Action] = [.powerOn, .powerOff, .slider, .startOk, .startFail, .stopDone, .retry, .returnEarlier]

func enumerateS5(length: Int) -> [[S5Action]] {
    var out: [[S5Action]] = []
    func visit(_ model: LaneModel, _ prefix: [S5Action]) {
        if prefix.count == length { out.append(prefix); return }
        for a in s5Alphabet {
            var next = model, ok = true
            for e in a.macro { if next.isEnabled(e) { _ = next.apply(e) } else { ok = false; break } }
            if ok { visit(next, prefix + [a]) }
        }
    }
    visit(LaneModel(), [])
    return out
}

struct S5Result {
    var translated: [BEvent] = []
    var observation = LaneObservation()
    var positionsOnWithoutActivation = false
    var notes: [String] = []
    /// Once settled, what playback last received differs from the document (parts of the first app, or compare).
    var playbackStale: String?
}

/// `saveDuringPowerOn` holds the activation refresh that follows the first power ON, lets the debounced
/// save start, then releases the refresh: the order of the named race case.
/// `holdOffRefresh`: power OFF's activation refresh is held once positions OFF has
/// arrived, and released only after the next power ON is sent.
@MainActor func runS5(_ actions: [S5Action], hold: Int, saveDuringPowerOn: Bool = false, holdOffRefresh: Bool = false) async -> S5Result {
    var result = S5Result()
    guard let f = try? await TableFixture(attachCounter: false) else { result.notes.append("fixture"); return result }
    // Saves stay behind the debounce gate until settling, as with the App's 200 ms delay.
    await f.reads.menuGate.setOpen(true); await f.port.gate.setOpen(true)
    // The model covers one app's lane. The fixture's second app gets a lane of its own that never holds and isn't counted.
    let trace = LaneTrace(), other = LaneTrace()
    trace.phase = hold; other.autoRelease = true
    var observed: UUID?
    let controller = PlaybackController(testingLane: { assignment, observe in
        let t = assignment.bundleIdentifier == "com.apple.Safari" ? trace : other
        if t === trace { observed = assignment.id }
        let factory = PlaybackCaptureFactory(inner: LaneCaptureFactory(trace: t), assignment: assignment) { _, _ in LaneSink(t) }
        return (factory, PlaybackRuntime(resolver: LaneResolver(), factory: factory,
            leases: InputGuardLeaseCoordinator(port: LaneGuard(), settingEnabled: false), observe: observe))
    })
    controller.startedForTesting = { id, state in if id == observed { trace.completions.append(state) } }
    controller.stoppedForTesting = { id, state in if id == observed { trace.completions.append(state) } }
    // Both apps on: a positions delivery with an app off clears the last activation (LibraryListeningCoordinator,
    // deliver), which would hide the returnEarlier order. The second app's lane auto-releases and isn't counted.
    try? await f.owner.setEnabled(true, on: "test.other")
    let coordinator = f.app.coordinator
    Seams.wireApp(controller, to: coordinator)                               // as the App wires it
    var pending: [BEvent] = []
    var lastPower: Bool?
    let verbose = ProcessInfo.processInfo.environment["S5_VERBOSE"] != nil
    var lastDelivered: (snapshot: ListeningRenderSnapshot, original: Bool, mode: LibraryDeliveryMode)?
    _ = await coordinator.attachPlayback { snapshot, original, mode in       // as the App attaches playback
        lastDelivered = (snapshot, original, mode)
        let on = snapshot.isEnabled
        if verbose { print("  DELIVER \(mode) power \(on) assignments \(snapshot.assignments.map { "\($0.bundleIdentifier)=\($0.isEnabled)" }) prepares \(trace.prepares)") }
        switch mode {
        case .activation:
            pending.append(.activation(on: on)); controller.apply(snapshot, original: original)
        case .positions:
            pending.append(lastPower != on ? .positions(on: on) : .parameters)
            if controller.updatePositions(snapshot, original: original) == .requiresFull { coordinator.playbackDidChange() }
        }
        lastPower = on
    }
    func settle() async {
        var stable = 0
        for _ in 0..<60 {
            let before = [trace.prepares, trace.outputStarts, trace.captureStops, trace.completions.count, trace.heldStarts, trace.heldStops, pending.count]
            await f.quiet(rounds: 20)
            if before == [trace.prepares, trace.outputStarts, trace.captureStops, trace.completions.count, trace.heldStarts, trace.heldStops, pending.count] {
                stable += 1; if stable >= 2 { return }
            } else { stable = 0 }
        }
        result.notes.append("did not settle")
    }
    var model = LaneModel()
    var authorized = false, offSeen = false, offRefreshHeld = false
    func take(_ events: [BEvent]) {
        for e in events {
            guard model.isEnabled(e) else { result.notes.append("delivered \(e) where the model has none enabled"); continue }
            _ = model.apply(e)
            result.translated.append(e)
            result.observation.outputStarts.append(trace.sounds)
            switch e {
            case .activation(let on): authorized = on; if !on { offSeen = true }
            case .positions(let on):
                if !on { authorized = false; offSeen = true }
                else if offSeen && !authorized { result.positionsOnWithoutActivation = true }
            default: break
            }
        }
    }
    await settle()
    take(pending); pending = []
    let startCard = f.shownCard
    let startValue = f.slider(on: startCard)?.position
    var k = 0
    for a in actions {
        k += 1
        let stepStart = result.observation.outputStarts.count
        var own: [BEvent] = []
        switch a {
        case .powerOn:
            if verbose { print("  ACTION powerON") }
            if saveDuringPowerOn {
                let arrivals = await f.reads.menuGate.arrivals
                await f.reads.menuGate.setOpen(false)
                f.app.send(.setEnabled(true))
                _ = await watched("power ON refresh") { await f.reads.menuGate.arrived(after: arrivals) }
                await f.debounce.releaseAll()
                await f.quiet(rounds: 20)
                await f.reads.menuGate.setOpen(true)
            } else {
                f.app.send(.setEnabled(true))
                if offRefreshHeld {
                    await f.quiet(rounds: 20)
                    offRefreshHeld = false
                    await f.reads.menuGate.setOpen(true)
                }
            }
        case .powerOff where holdOffRefresh && !offRefreshHeld:
            await f.reads.menuGate.setOpen(false)
            var arrivals = await f.reads.menuGate.arrivals
            f.app.send(.setEnabled(false))
            for _ in 0..<4 {
                _ = await watched("power OFF read") { await f.reads.menuGate.arrived(after: arrivals) }
                arrivals = await f.reads.menuGate.arrivals
                await f.quiet(rounds: 20)
                if pending.contains(.positions(on: false)) { offRefreshHeld = true; break }
                await f.reads.menuGate.releaseAll()                // a read before positions OFF: let it through
            }
            if !offRefreshHeld { result.notes.append("positions OFF never arrived with a read held") }
        case .powerOff: f.app.send(.setEnabled(false))
        case .slider:
            let card = f.shownCard
            if let identity = card.menuIdentity, let epoch = card.menuEpoch, let s = f.slider(on: card) {
                f.app.send(.menuMove(identity, epoch, s.address, s.optionGesture, .scalar(Double(k) / 37)))
            } else { result.notes.append("slider step \(k): card has no identity") }
        case .startOk, .startFail:
            if trace.releaseStart(ok: a == .startOk) { own = [.startCompletes(ok: a == .startOk)] }
            else { result.notes.append("step \(k): no start held") }
        case .stopDone:
            if trace.releaseStop() { own = [.stopCompletes] } else { result.notes.append("step \(k): no stop held") }
        case .returnEarlier:
            if let s = f.slider(on: startCard), let binding = startCard.binding, let startValue {
                _ = try? await f.owner.move(s.address, expected: binding, to: .scalar(startValue))
                if lastDelivered?.mode == .activation { await coordinator.refresh(mode: .positions) } else { await coordinator.refresh() }
            } else { result.notes.append("step \(k): no slider to return") }
        case .retry:
            controller.retry()
            own = [model.state == .failed ? .retry : .activation(on: lastPower ?? false)]
        }
        take(own)
        await settle()
        take(pending); pending = []
        // A sound that started during this step belongs to its first event (the start completion, when there is one).
        for i in stepStart..<result.observation.outputStarts.count { result.observation.outputStarts[i] = trace.sounds }
    }
    trace.releaseAll()
    await f.debounce.setOpen(true)
    await settle()
    take(pending); pending = []
    if let doc = try? await f.owner.snapshot(), let live = try? await f.owner.liveState() {
        let want = ListeningRenderSnapshot(library: doc)
        if let got = lastDelivered, got.snapshot != want || got.original != live.compareOriginal {
            result.playbackStale = "playback last received a \(got.mode) snapshot that differs from the document"
        }
    }
    result.observation.finalStarts = trace.sounds
    result.observation.problem = controller.problem != nil
    let last = trace.completions.last ?? "idle"
    result.observation.finalState = last == "failed" && !result.observation.problem ? "idle" : last
    await controller.shutdown()
    await f.close()
    return result
}

/// Controller level: the controller against the model fed the deliveries that really arrived.
/// User level: the final result against the model of what the user did (power OFF = positions then activation).
func s5Verdict(_ actions: [S5Action], _ r: S5Result) -> [String] {
    var out = laneVerdict(r.translated, r.observation)
    var model = LaneModel()
    for e in actions.flatMap(\.macro) where model.isEnabled(e) { _ = model.apply(e) }
    let settled = model.settle()
    if r.observation.finalStarts != settled.outputStarts { out.append("S5 user: \(r.observation.finalStarts) sound starts, the user's actions call for \(settled.outputStarts)") }
    if r.observation.finalState != settled.state.rawValue { out.append("S5 user: lane ends \(r.observation.finalState), the user's actions call for \(settled.state.rawValue)") }
    if let stale = r.playbackStale { out.append("S5 values: \(stale)") }
    return out
}

/// One slice of the coordinator lane suite (S5). A run whose fixture could not be built counts as unsupported,
/// never green. "Order reached" counts a delivery order worth knowing about; it is reported, not a failure.
@MainActor func runS5Slice(length: Int, hold: Int, from: Int, count: Int) async -> SliceResult {
    let all = enumerateS5(length: length)
    let slice = all.dropFirst(from).prefix(count)
    var result = SliceResult(suite: "S5", length: length, hold: hold, from: from, count: slice.count, total: all.count)
    let start = Date()
    var reached = 0
    var keys: [String: (Int, [S5Action])] = [:]
    for (offset, actions) in slice.enumerated() {
        let r = await runS5(actions, hold: hold)
        let text = actions.map(\.description).joined(separator: " ")
        if r.notes.contains("fixture") {
            result.unsupported += 1
            print("UNSUPPORTED S5 L\(length) hold \(hold) #\(from + offset) [\(text)]: fixture could not be built")
            continue
        }
        if r.positionsOnWithoutActivation {
            reached += 1
            print("ORDER S5 L\(length) hold \(hold) #\(from + offset) positions ON after OFF without activation ON: [\(text)] -> [\(r.translated.map(\.description).joined(separator: " "))]")
        }
        let v = s5Verdict(actions, r)
        if ProcessInfo.processInfo.environment["S5_VERBOSE"] != nil {
            print("RUN #\(from + offset) [\(text)] delivered [\(r.translated.map(\.description).joined(separator: " "))] sounds \(r.observation.outputStarts) final \(r.observation.finalState) notes \(r.notes + r.observation.notes)")
        }
        if v.isEmpty { result.green += 1; continue }
        result.red += 1
        result.redSequences.append(text)
        let key = normalizeCause(v[0])
        if keys[key] == nil { keys[key] = (0, actions) }
        keys[key]!.0 += 1
        print("RED S5 L\(length) hold \(hold) #\(from + offset) [\(text)] delivered [\(r.translated.map(\.description).joined(separator: " "))]")
        for x in v.prefix(3) { print("    violates: \(x)") }
        for n in (r.notes + r.observation.notes).prefix(3) { print("    note: \(n)") }
    }
    result.seconds = Date().timeIntervalSince(start)
    for (k, value) in keys.sorted(by: { $0.value.0 > $1.value.0 }) {
        print("CAUSE S5 hold \(hold) \"\(k)\" \(value.0) first [\(value.1.map(\.description).joined(separator: " "))]")
    }
    print("S5 L\(length) hold \(hold) slice \(from)+\(slice.count): order reached \(reached)")
    return result
}

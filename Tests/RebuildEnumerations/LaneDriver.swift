// Lane life, controller direct: the real PlaybackController with fake capture and output, every
// start held at one hold point (capture prepare, output prepare or capture start) until the
// sequence says it completes. Nothing here touches audio hardware.
//
// Per-event outcomes come from the controller's test hooks: controller quiescence, the lane state
// readback, the held stop step and the source-gone injection. The observable checks (output starts,
// the final state, the problem, and sound after OFF) run on top of them.

import Foundation
import SoundModel
@testable import EverydayMenu
import PlaybackLifecycle
import PlaybackRuntime
@testable import PlaybackOutput
@testable import tap_n_filter

enum LaneFailure: Error { case injected }

@MainActor final class LaneTrace {
    var phase = 0
    var autoRelease = false
    /// When the controller's own stop step is held, the capture fake no longer holds stops.
    var stopsViaSeam = false
    /// A failed start tears down through capture stop; that teardown is not a model stop.
    var passTeardowns = 0
    private var held: [CheckedContinuation<Bool, Never>] = []
    private var stopsHeld: [CheckedContinuation<Void, Never>] = []
    var prepares = 0, captureStarts = 0, outputStarts = 0, captureStops = 0
    var completions: [String] = []
    /// A lane sounds only once both its capture and its output have started.
    var sounds: Int { min(captureStarts, outputStarts) }
    /// Called whenever a start or stop parks, so a quiescence wait can stop waiting for it.
    var onHold: (() -> Void)?
    var heldStarts: Int { held.count }
    var heldStops: Int { stopsHeld.count }
    func point(_ p: Int) async throws {
        guard p == phase, !autoRelease else { return }
        let ok = await withCheckedContinuation { held.append($0); onHold?() }
        if !ok { throw LaneFailure.injected }
    }
    func stopPoint() async {
        captureStops += 1
        if passTeardowns > 0 { passTeardowns -= 1; return }
        guard !autoRelease else { return }
        await withCheckedContinuation { stopsHeld.append($0); onHold?() }
    }
    @discardableResult func releaseStart(ok: Bool) -> Bool {
        guard !held.isEmpty else { return false }
        if !ok && !stopsViaSeam { passTeardowns += 1 }   // with the stop step held, a failed start's teardown isn't a controller stop
        held.removeFirst().resume(returning: ok); return true
    }
    @discardableResult func releaseStop() -> Bool {
        guard !stopsHeld.isEmpty else { return false }
        stopsHeld.removeFirst().resume(); return true
    }
    func releaseAll() {
        autoRelease = true
        while releaseStart(ok: true) {}
        while releaseStop() {}
    }
}
@MainActor struct LaneResolver: ProcessResolving {
    func resolve(binding: AppBinding, preferredPID: Int32?) async throws -> ResolvedProcess { ResolvedProcess(binding: binding, pid: 1, audioProcessID: 1, path: .preferredPID) }
    func revalidate(_ process: ResolvedProcess) async throws {}
}
@MainActor struct LaneGuard: InputGuardPort {
    func recoverIfStranded() async -> GuardRestoration { .noMarker }
    func engage(settingEnabled: Bool) async -> GuardEngagement { .declined(reason: "inert lifecycle fake") }
    func restore() async -> GuardRestoration { .noMarker }
}
@MainActor final class LaneCapture: CaptureSession {
    let trace: LaneTrace
    init(_ trace: LaneTrace) { self.trace = trace }
    func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
        trace.prepares += 1
        try await trace.point(0)
        return CapturePreparation(format: try StreamFormat(sampleRate: 48000, channels: 2))
    }
    func start() async throws { try await trace.point(2); try Task.checkCancellation(); trace.captureStarts += 1 }
    func stop() async -> TeardownOutcome { if !trace.stopsViaSeam { await trace.stopPoint() }; return .completed }
}
@MainActor struct LaneCaptureFactory: CaptureSessionFactory {
    let trace: LaneTrace
    func makeSession() -> any CaptureSession { LaneCapture(trace) }
}
@MainActor final class LaneSink: PlaybackSink {
    let trace: LaneTrace
    init(_ trace: LaneTrace) { self.trace = trace }
    func prepare(_ capture: CapturePreparation) async throws { try await trace.point(1) }
    func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {}
    func start() throws { trace.outputStarts += 1 }
    func stop() async {}
}

/// Render snapshots for power ON and OFF at several parameter versions, from a real library session.
@MainActor final class LaneSnapshots {
    var on: [ListeningRenderSnapshot] = [], off: [ListeningRenderSnapshot] = []
    static func make(versions: Int = 10) async throws -> LaneSnapshots {
        let result = LaneSnapshots()
        let limits = try LibraryAppSession.normalLimits(), port = TablePort()
        guard case .fresh(let owner) = await SoundLibrarySession.open(persistence: port, limits: limits, builtins: .quickMenu) else { throw TableError.setup("lane seed") }
        let definitions = try await owner.snapshot().definitions
        _ = try await owner.select(definitions.first { $0.name == "Everyday" }!.id, on: "com.apple.Safari")
        let data = MenuSoundData(library: try await owner.snapshot())
        guard let card = data.assignments.first(where: { $0.bundleIdentifier == "com.apple.Safari" }), let binding = card.binding,
              let slider = card.controls.first(where: { $0.title == "Softer" }) else { throw TableError.setup("lane card") }
        for k in 0..<versions {
            _ = try await owner.move(slider.address, expected: binding, to: .scalar(0.05 + 0.09 * Double(k)))
            await owner.setEnabled(true)
            result.on.append(ListeningRenderSnapshot(library: try await owner.snapshot()))
            await owner.setEnabled(false)
            result.off.append(ListeningRenderSnapshot(library: try await owner.snapshot()))
        }
        return result
    }
}

struct LaneObservation {
    var outputStarts: [Int] = []     // cumulative output starts after each event
    var finalState = "idle"
    var finalStarts = 0
    var problem = false
    var notes: [String] = []
}

/// LANE_MODEL_MUTANT=<name> compares the real controller with a deliberately wrong model, to show
/// the comparison can go red (it should, wherever the mutant's behaviour is reachable).
let laneExpectationMutant = BMutant(rawValue: ProcessInfo.processInfo.environment["LANE_MODEL_MUTANT"] ?? "none") ?? .none

func laneModelRun(_ events: [BEvent]) -> (outcomes: [BOutcome], settled: BSettled, power: [Bool]) {
    var model = LaneModel(mutant: laneExpectationMutant)
    var outcomes: [BOutcome] = [], power: [Bool] = []
    var on = false
    for e in events {
        precondition(model.isEnabled(e), "not enabled: \(e)")
        outcomes.append(model.apply(e))
        if let p = e.power { on = p }
        power.append(on)
    }
    return (outcomes, model.settle(), power)
}

/// Compares the observable lane results with the model.
func laneVerdict(_ events: [BEvent], _ real: LaneObservation) -> [String] {
    let model = laneModelRun(events)
    var out: [String] = []
    var previous = 0
    for (i, starts) in real.outputStarts.enumerated() {
        if starts > previous && !model.power[i] { out.append("B1 sound during step \(i + 1) \(events[i]) with power OFF") }
        if starts > previous && !model.outcomes[i].outputStarted { out.append("B2 output started at step \(i + 1) \(events[i]); the model starts none there") }
        previous = starts
    }
    if real.finalStarts > (real.outputStarts.last ?? 0) && !(model.power.last ?? false) { out.append("B1 sound while settling with power OFF") }
    if real.finalStarts != model.settled.outputStarts { out.append("B2 \(real.finalStarts) output starts, model \(model.settled.outputStarts)") }
    if real.finalState != model.settled.state.rawValue { out.append("B2 settled \(real.finalState), model \(model.settled.state.rawValue)") }
    if real.problem != model.settled.problem { out.append("B9 problem \(real.problem), model \(model.settled.problem)") }
    return out
}

let laneAlphabet: [BEvent] = [.activation(on: true), .activation(on: false), .positions(on: true), .positions(on: false), .parameters,
                              .startCompletes(ok: true), .startCompletes(ok: false), .stopCompletes, .sourceGone, .retry]

// MARK: Lane run through the controller's test hooks: per-event outcomes and the lane invariants on the real trace

struct LaneSeamRun {
    var outcomes: [BOutcome] = []
    var observation = LaneObservation()
}

@MainActor func runLaneSeamed(_ events: [BEvent], hold: Int, snapshots: LaneSnapshots) async -> LaneSeamRun {
    var run = LaneSeamRun()
    let trace = LaneTrace()
    trace.phase = hold; trace.stopsViaSeam = true
    var laneID: UUID?
    let controller = PlaybackController(testingLane: { assignment, observe in
        laneID = assignment.id
        let factory = PlaybackCaptureFactory(inner: LaneCaptureFactory(trace: trace), assignment: assignment) { _, _ in LaneSink(trace) }
        return (factory, PlaybackRuntime(resolver: LaneResolver(), factory: factory,
            leases: InputGuardLeaseCoordinator(port: LaneGuard(), settingEnabled: false), observe: observe))
    })
    controller.startedForTesting = { _, state in trace.completions.append(state) }
    controller.stoppedForTesting = { _, state in trace.completions.append(state) }
    Seams.holdStops(controller) { _ in await trace.stopPoint() }                       // held stop step
    var power = false, version = 0
    func current() -> ListeningRenderSnapshot { power ? snapshots.on[version] : snapshots.off[version] }
    func state() -> LaneState { laneID.flatMap { Seams.laneState(controller, $0) } ?? .idle }   // lane state readback
    /// Controller quiescence, unless a start or stop is or becomes held (quiescence waits for those): then until
    /// the fakes stop moving.
    // SETTLE=heuristic settles by yields only, without controller quiescence (for comparison).
    let heuristicOnly = ProcessInfo.processInfo.environment["SETTLE"] == "heuristic"
    func settleLane() async {
        if !heuristicOnly && trace.heldStarts == 0 && trace.heldStops == 0 {
            let box = WatchBox<Bool>()
            let quiet = await withCheckedContinuation { (c: CheckedContinuation<Bool?, Never>) in
                box.continuation = c
                trace.onHold = { _ = box.finish(false) }
                Task { @MainActor in await Seams.controllerQuiescent(controller); _ = box.finish(true) }
            }
            trace.onHold = nil
            if quiet == true { return }
        }
        var stable = 0
        for _ in 0..<60 {
            let before = [trace.prepares, trace.outputStarts, trace.captureStops, trace.completions.count, trace.heldStarts, trace.heldStops]
            for _ in 0..<10 { await Task.yield() }
            if before == [trace.prepares, trace.outputStarts, trace.captureStops, trace.completions.count, trace.heldStarts, trace.heldStops] {
                stable += 1; if stable >= 3 { return }
            } else { stable = 0 }
        }
        run.observation.notes.append("controller did not settle")
    }
    for (i, e) in events.enumerated() {
        let prepares = trace.prepares, sounds = trace.sounds, before = state()
        switch e {
        case .activation(let on): power = on; controller.apply(current(), original: false)
        case .positions(let on): power = on; _ = controller.updatePositions(current(), original: false)
        case .parameters:
            version = min(version + 1, snapshots.on.count - 1)
            _ = controller.updatePositions(current(), original: false)
        case .startCompletes(let ok):
            if !trace.releaseStart(ok: ok) { run.observation.notes.append("step \(i + 1): no start was held at hold point \(hold)") }
        case .stopCompletes:
            if !trace.releaseStop() { run.observation.notes.append("step \(i + 1): no stop was held") }
        case .sourceGone:
            // The invalidation's own stop passes the held stop step: losing the source isn't a user stop (B-R9, B-S9).
            if let laneID { trace.passTeardowns += 1; Seams.sourceGone(controller, assignment: laneID) }
            else { run.observation.notes.append("step \(i + 1): no lane to lose its source") }
        case .retry:
            controller.retry()
        }
        await settleLane()
        if case .sourceGone = e { trace.passTeardowns = 0 }
        // The held stop step runs when a stop completes, so a stop's issue is read from the lane state: starting or
        // running to stopping.
        let after = state()
        run.outcomes.append(BOutcome(startIssued: trace.prepares > prepares, outputStarted: trace.sounds > sounds,
                                     stopIssued: (before == .starting || before == .running) && after == .stopping,
                                     state: after, problem: controller.problem != nil))
        run.observation.outputStarts.append(trace.sounds)
    }
    trace.releaseAll()
    await settleLane()
    run.observation.finalStarts = trace.sounds
    run.observation.problem = controller.problem != nil
    run.observation.finalState = state().rawValue
    if heuristicOnly {
        // Late or lost: after the heuristic's verdict, wait for controller quiescence and read the state again.
        let settled = state(), starts = trace.sounds
        let quiet = await watched("late probe", seconds: 5) { await Seams.controllerQuiescent(controller) } != nil
        if state() != settled || trace.sounds != starts {
            print("LATE heuristic settled \(settled.rawValue) sounds \(starts); after quiescence (quiet \(quiet)) \(state().rawValue) sounds \(trace.sounds)")
        }
    }
    await controller.shutdown()
    return run
}

/// Per-event comparison with the model, the lane invariants on the real trace, then the observable checks.
/// A start or stop the model says completes here, but nothing is held: the real runtime can't produce
/// that order (for example a stop finishing while its start is still held). Listed, never counted green.
func unreachableOrder(_ run: LaneSeamRun) -> String? {
    run.observation.notes.first { $0.contains("no start was held") || $0.contains("no stop was held") }
}

func laneSeamVerdict(_ events: [BEvent], _ run: LaneSeamRun) -> [String] {
    let model = laneModelRun(events)
    var out: [String] = []
    for (i, e) in events.enumerated() where run.outcomes[i] != model.outcomes[i] {
        out.append("diverges at \(i + 1) \(e): model \(model.outcomes[i]), real \(run.outcomes[i])")
    }
    let settled = BSettled(state: LaneState(rawValue: run.observation.finalState) ?? .idle, outputStarts: run.observation.finalStarts,
                           laneParameters: model.settled.laneParameters, parameters: model.settled.parameters, steps: 0, problem: run.observation.problem)
    out += LaneInvariants.violations(events, run.outcomes, settled: settled)
    out += laneVerdict(events, run.observation)
    return out
}

func enumerateLane(length: Int) -> [[BEvent]] {
    var out: [[BEvent]] = []
    func visit(_ model: LaneModel, _ prefix: [BEvent]) {
        if prefix.count == length { out.append(prefix); return }
        for e in laneAlphabet where model.isEnabled(e) { var next = model; _ = next.apply(e); visit(next, prefix + [e]) }
    }
    visit(LaneModel(), [])
    return out
}

/// One slice of the lane suite (S4). An order the real runtime can't produce (`unreachableOrder`) counts as
/// unsupported: it is listed, never counted green.
@MainActor func runLaneSlice(length: Int, hold: Int, from: Int, count: Int) async -> SliceResult {
    let all = enumerateLane(length: length)
    let slice = all.dropFirst(from).prefix(count)
    var result = SliceResult(suite: "S4", length: length, hold: hold, from: from, count: slice.count, total: all.count)
    guard let snapshots = try? await LaneSnapshots.make() else { result.setupFailure = "lane snapshots could not be built"; return result }
    let start = Date()
    var keys: [String: (Int, [BEvent])] = [:]
    for (offset, events) in slice.enumerated() {
        let run = await runLaneSeamed(events, hold: hold, snapshots: snapshots)
        let real = run.observation
        let text = events.map(\.description).joined(separator: " ")
        if let why = unreachableOrder(run) {
            result.unsupported += 1
            print("UNREACHABLE S4 L\(length) hold \(hold) #\(from + offset) [\(text)]: \(why)")
            continue
        }
        let v = laneSeamVerdict(events, run)
        if v.isEmpty { result.green += 1; continue }
        result.red += 1
        result.redSequences.append(text)
        let key = normalizeCause(v[0])
        if keys[key] == nil { keys[key] = (0, events) }
        keys[key]!.0 += 1
        print("RED S4 L\(length) hold \(hold) #\(from + offset) [\(text)]")
        for x in v.prefix(3) { print("    violates: \(x)") }
        for n in real.notes.prefix(2) { print("    note: \(n)") }
    }
    result.seconds = Date().timeIntervalSince(start)
    for (k, value) in keys.sorted(by: { $0.value.0 > $1.value.0 }) {
        print("CAUSE S4 hold \(hold) \"\(k)\" \(value.0) first [\(value.1.map(\.description).joined(separator: " "))]")
    }
    return result
}

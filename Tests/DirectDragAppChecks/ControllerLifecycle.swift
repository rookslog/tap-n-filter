import Foundation
import PlaybackLifecycle
import PlaybackRuntime
import SoundModel
@testable import PlaybackOutput

@MainActor private final class StopGate {
    var waiter: CheckedContinuation<Void, Never>?
    var arrivals: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { waiter = $0; for arrival in arrivals { arrival.resume() }; arrivals = [] }
    }
    func entered() async { if waiter == nil { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}
@MainActor private final class ControllerTrace {
    var starts: [String: Int] = [:]
    var startWaiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
    let gate = StopGate()
    var hold = false
    var holdPrepare = false
    var holdOutputPrepare = false
    var holdStart = false
    let prepareGate = StopGate()
    let outputGate = StopGate()
    let startGate = StopGate()
    var captureStarts = 0
    var stopped: [UUID: String] = [:]
    var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func started(_ bundle: String) {
        starts[bundle, default: 0] += 1
        let ready = startWaiters.filter { starts[$0.0, default: 0] >= $0.1 }
        startWaiters.removeAll { starts[$0.0, default: 0] >= $0.1 }
        for value in ready { value.2.resume() }
    }
    func awaitStart(_ bundle: String, _ count: Int) async {
        if starts[bundle, default: 0] < count { await withCheckedContinuation { startWaiters.append((bundle, count, $0)) } }
    }
    func completed(_ id: UUID, state: String) { stopped[id] = state; stopWaiters.removeValue(forKey: id)?.resume() }
    func awaitStop(_ id: UUID) async { if stopped[id] == nil { await withCheckedContinuation { stopWaiters[id] = $0 } } }
}
@MainActor private struct ControllerResolver: ProcessResolving {
    func resolve(binding: AppBinding, preferredPID: Int32?) async throws -> ResolvedProcess {
        ResolvedProcess(binding: binding, pid: 1, audioProcessID: 1, path: .preferredPID)
    }
    func revalidate(_ process: ResolvedProcess) async throws {}
}
@MainActor private struct ControllerGuard: InputGuardPort {
    func recoverIfStranded() async -> GuardRestoration { .noMarker }
    func engage(settingEnabled: Bool) async -> GuardEngagement { .declined(reason: "inert lifecycle fake") }
    func restore() async -> GuardRestoration { .noMarker }
}
@MainActor private final class ControllerCapture: CaptureSession {
    let trace: ControllerTrace?
    init(_ trace: ControllerTrace?) { self.trace = trace }
    func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
        if let trace, trace.holdPrepare { trace.holdPrepare = false; await trace.prepareGate.pause() }
        return CapturePreparation(format: try StreamFormat(sampleRate: 48000, channels: 2))
    }
    func start() async throws {
        if let trace, trace.holdStart { trace.holdStart = false; await trace.startGate.pause() }
        try Task.checkCancellation()
        trace?.captureStarts += 1
    }
    func stop() async -> TeardownOutcome { .completed }
}
@MainActor private struct ControllerFactory: CaptureSessionFactory {
    let trace: ControllerTrace?
    init(trace: ControllerTrace? = nil) { self.trace = trace }
    func makeSession() -> any CaptureSession { ControllerCapture(trace) }
}
@MainActor private final class ControllerSink: PlaybackSink {
    let trace: ControllerTrace
    let bundle: String
    init(_ trace: ControllerTrace, bundle: String) { self.trace = trace; self.bundle = bundle }
    func prepare(_ capture: CapturePreparation) async throws {
        if trace.holdOutputPrepare { trace.holdOutputPrepare = false; await trace.outputGate.pause() }
    }
    func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {}
    func start() throws { trace.started(bundle) }
    func stop() async { if bundle == "test.A", trace.hold { trace.hold = false; await trace.gate.pause() } }
}

extension DirectDragAppChecks {
    @MainActor static func controllerAsyncLifecycle(orders: [Int] = [0, 1, 2, 3, 4, 5]) async throws {
        for order in orders {
            let trace = ControllerTrace(), a = UUID(), b = UUID()
            let controller = PlaybackController(testingLane: { assignment, observe in
                let factory = PlaybackCaptureFactory(inner: ControllerFactory(), assignment: assignment) { value, _ in ControllerSink(trace, bundle: value.bundleIdentifier) }
                let runtime = PlaybackRuntime(resolver: ControllerResolver(), factory: factory,
                    leases: InputGuardLeaseCoordinator(port: ControllerGuard(), settingEnabled: false), observe: observe)
                return (factory, runtime)
            })
            controller.stoppedForTesting = { trace.completed($0, state: $1) }
            func snapshot(_ aOn: Bool, _ bOn: Bool, bundle: String = "test.A") -> ListeningRenderSnapshot {
                ListeningRenderSnapshot(isEnabled: true, assignments: [
                    ListeningRenderAssignment(id: a, bundleIdentifier: bundle, isEnabled: aOn, parts: []),
                    ListeningRenderAssignment(id: b, bundleIdentifier: "test.B", isEnabled: bOn, parts: [])])
            }
            controller.apply(snapshot(true, true), original: false)
            await trace.awaitStart("test.A", 1); await trace.awaitStart("test.B", 1)
            trace.hold = true
            controller.apply(snapshot(false, true), original: false)
            await trace.gate.entered()
            if order == 0 {
                controller.apply(snapshot(true, true), original: false)
                _ = controller.updatePositions(snapshot(true, false), original: false)
            } else if order == 1 {
                _ = controller.updatePositions(snapshot(false, false), original: false)
                controller.apply(snapshot(true, false), original: false)
            } else if order == 2 {
                _ = controller.updatePositions(snapshot(true, false), original: false)
            } else if order == 3 {
                controller.apply(snapshot(true, true), original: false)
                _ = controller.updatePositions(snapshot(true, false, bundle: "test.C"), original: false)
            } else if order == 4 {
                _ = controller.updatePositions(snapshot(true, false, bundle: "test.C"), original: false)
                controller.apply(snapshot(true, false, bundle: "test.C"), original: false)
            } else {
                controller.apply(snapshot(true, true), original: false)
                _ = controller.updatePositions(snapshot(false, false), original: false)
            }
            trace.gate.release()
            await trace.awaitStop(a)
            if [0, 1, 4].contains(order) {
                guard trace.stopped[a] == "starting" || trace.stopped[a] == "running" else {
                    throw NSError(domain: "ControllerLifecycle", code: 1, userInfo: [NSLocalizedDescriptionKey: "authorized A stranded after unrelated B OFF, order\(order), state=\(trace.stopped[a] ?? "missing")"])
                }
                await trace.awaitStart(order == 4 ? "test.C" : "test.A", order == 4 ? 1 : 2)
            } else {
                guard trace.stopped[a] == "idle", trace.starts["test.A"] == 1, trace.starts["test.C", default: 0] == 0 else {
                    throw NSError(domain: "ControllerLifecycle", code: 2, userInfo: [NSLocalizedDescriptionKey: "positions update granted unauthorized restart, order\(order)"])
                }
            }
            precondition(trace.starts["test.B"] == 1)
            print("PASS actual async controller held-stop completion, event order/source/authority case\(order)")
            await controller.shutdown()
        }
    }
    @MainActor static func controllerStartingOff(cases: [Int] = Array(0..<8)) async throws {
        for mode in cases {
            let trace = ControllerTrace(), id = UUID()
            let gate: StopGate
            if mode < 2 || mode >= 6 { trace.holdPrepare = true; gate = trace.prepareGate }
            else if mode < 4 { trace.holdOutputPrepare = true; gate = trace.outputGate }
            else { trace.holdStart = true; gate = trace.startGate }
            let controller = PlaybackController(testingLane: { assignment, observe in
                let factory = PlaybackCaptureFactory(inner: ControllerFactory(trace: trace), assignment: assignment) { value, _ in ControllerSink(trace, bundle: value.bundleIdentifier) }
                return (factory, PlaybackRuntime(resolver: ControllerResolver(), factory: factory,
                    leases: InputGuardLeaseCoordinator(port: ControllerGuard(), settingEnabled: false), observe: observe))
            })
            controller.stoppedForTesting = { trace.completed($0, state: $1) }
            controller.startedForTesting = { if $1 != "stopping" { trace.completed($0, state: $1) } }
            let a = ListeningRenderAssignment(id: id, bundleIdentifier: "test.A", isEnabled: true, parts: [])
            controller.apply(ListeningRenderSnapshot(isEnabled: true, assignments: [a]), original: false)
            await gate.entered()
            let outputBefore = trace.starts["test.A", default: 0], captureBefore = trace.captureStarts
            let assignments: [ListeningRenderAssignment]
            if mode == 6 { assignments = [] }
            else { assignments = [ListeningRenderAssignment(id: id, bundleIdentifier: mode == 7 ? "test.C" : "test.A", isEnabled: mode % 2 == 0 || mode == 7, parts: [])] }
            _ = controller.updatePositions(ListeningRenderSnapshot(isEnabled: mode % 2 != 0 || mode >= 6, assignments: assignments), original: false)
            gate.release(); await trace.awaitStop(id)
            let outputAfter = trace.starts["test.A", default: 0], captureAfter = trace.captureStarts
            print("STARTING mode=\(mode) output \(outputBefore)->\(outputAfter) capture \(captureBefore)->\(captureAfter) completion=\(trace.stopped[id] ?? "missing")")
            guard outputBefore == outputAfter, captureBefore == captureAfter, trace.stopped[id] == "idle" else {
                throw NSError(domain: "StartingOff", code: mode, userInfo: [NSLocalizedDescriptionKey: "starting lane produced output/capture after OFF/removal/source replacement"])
            }
            print("PASS actual starting lane cancellation mode\(mode), no post-OFF output/capture start")
            await controller.shutdown()
        }
    }

}

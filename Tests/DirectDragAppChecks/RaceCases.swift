import Foundation
import AppKit
import SoundModel
@testable import EverydayMenu
import PlaybackLifecycle
import PlaybackRuntime
@testable import PlaybackOutput
@testable import tap_n_filter

private enum RaceError: Error { case setup(String) }
@MainActor private final class RaceSignal {
    var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func send() { count += 1; let ready = waiters.filter { count >= $0.0 }; waiters.removeAll { count >= $0.0 }; for item in ready { item.1.resume() } }
    func wait(_ value: Int = 1) async { if count < value { await withCheckedContinuation { waiters.append((value, $0)) } } }
}
private actor RaceGate {
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
private actor RacePort: LibraryPersistence {
    var bytes: Data?
    var writes = 0
    var held = false
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func awaitWrite(_ count: Int) async { if writes < count { await withCheckedContinuation { observers.append((count, $0)) } } }
    let gate = RaceGate()
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func load() -> Data? { bytes }
    func arm() { held = true }
    func commit(_ value: Data) async -> LibraryWriteOutcome {
        writes += 1
        let ready = observers.filter { writes >= $0.0 }; observers.removeAll { writes >= $0.0 }; for o in ready { o.1.resume() }
        if held { held = false; await gate.pause() }
        bytes = value
        return .committed
    }
}
private actor RaceReads {
    var owner: SoundLibrarySession?
    var hold = false
    let gate = RaceGate()
    func arm() { hold = true }
    func read(_ owner: SoundLibrarySession) async throws -> LibraryMenuState {
        self.owner = owner
        if hold { hold = false; await gate.pause() }
        return try await owner.menuState()
    }
}
@MainActor private final class RaceReply {
    var result: String?
    let signal = RaceSignal()
    func finish(_ value: String) { guard result == nil else { return }; result = value; signal.send() }
    func value() async -> String { await signal.wait(); return result! }
}
@MainActor private final class RaceFixture {
    var app: LibraryAppSession!
    var view: MenuPresentation!
    var actions: [EverydayMenuAction] = []
    let reads = RaceReads(), delay = RaceGate()
    var port: RacePort!
    var owner: SoundLibrarySession!
    var playback: [ListeningRenderSnapshot] = []
    init(attachConsumer: Bool = true) async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = RacePort()
        guard case .fresh(let opened) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else { throw RaceError.setup("seed") }
        let defs = try await opened.snapshot().definitions
        _ = try await opened.select(defs.first { $0.name == "Everyday" }!.id, on: "com.apple.Safari")
        _ = try await opened.checkpoint()
        port = RacePort(await seed.bytes)
        app = LibraryAppSession(changed: { [weak self] in self?.refresh() }, read: { [reads] in try await reads.read($0) },
            checkpointDelay: { [delay] in await delay.pause(); try Task.checkCancellation() })
        await app.start(persistence: port, limits: limits)
        owner = await reads.owner!
        if attachConsumer { _ = await app.coordinator.attachPlayback { [weak self] snapshot, _, _ in self?.playback.append(snapshot) } }
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
        guard case .beginMenuGesture(let id) = actions.last else { throw RaceError.setup("begin producer") }
        return id
    }
    func issue(_ value: Double, token: UUID?, card: MenuSoundCard, control: MenuSoundControl? = nil) -> RaceReply {
        let c = control ?? slider, reply = RaceReply()
        app.perfMutationCompleted = { reply.finish(String(describing: $0)) }
        app.perfMutationFailed = { reply.finish("failure") }
        app.coordinator.perfParameterEvaluated = { _, _ in reply.finish("live") }
        if let token { app.send(.gestureMove(token, card.menuIdentity!, card.menuEpoch!, c.address, c.optionGesture, .scalar(value))) }
        else { app.send(.menuMove(card.menuIdentity!, card.menuEpoch!, c.address, c.optionGesture, .scalar(value))) }
        return reply
    }
    func move(_ value: Double, token: UUID?, card: MenuSoundCard, control: MenuSoundControl? = nil) async -> String { await issue(value, token: token, card: card, control: control).value() }
    func end() { view.endGesture() }
    func finish() async throws -> LibrarySnapshot {
        _ = await app.flushSave()?.value
        await delay.release()
        let reopened = try await SoundLibrarySession(persistence: RacePort(await port.bytes), limits: LibraryAppSession.normalLimits())
        return try await reopened.snapshot()
    }
    func close() async { app.close(); await delay.release() }
}

struct PR39RaceCases {
    @MainActor private static var failures = 0
    @MainActor private static func check(_ yes: Bool, _ message: String) {
        if !yes { failures += 1 }
        print("RACE \(yes ? "PASS" : "FAIL") \(message)")
    }
    @MainActor static func run(_ selected: String = "all") async throws {
        failures = 0
        if selected == "all" || selected == "1" { try await choiceTwice() }
        if selected == "all" || selected == "2" { try await retiredCallbacks() }
        if selected == "all" || selected == "2-pending" { try await pendingAtEnd() }
        if selected == "all" || selected == "3" { try await clickThenDrag() }
        for variant in ["query", "read", "playback", "structural"] where selected == "all" || selected == "4-" + variant { try await editorBarrier(variant) }
        for variant in ["off", "restart", "parameters"] where selected == "all" || selected == "5-" + variant {
            for phase in 0..<3 { try await starting(variant, phase: phase) }
        }
        if failures > 0 { throw RaceError.setup("\(failures) race assertions") }
    }
    @MainActor private static func choiceTwice() async throws {
        let f = try await RaceFixture(), card = f.card, slider = f.slider, choice = f.choice
        guard case .choice(let options) = choice.face, options.count >= 3 else { throw RaceError.setup("three choices") }
        let token = try f.begin()
        _ = await f.move(0.3, token: token, card: card); _ = await f.move(0.6, token: token, card: card)
        await f.port.arm(); f.end(); let first = f.app.gestureSave!
        await f.port.gate.entered()
        let b = await f.move(options[1].position, token: nil, card: card, control: choice)
        let c = await f.move(options[2].position, token: nil, card: card, control: choice)
        check(b != "superseded" && c != "superseded", "1 both held-save choice clicks admitted: \(b),\(c)")
        await f.port.gate.release(); _ = await first.value
        let saved = try await f.finish(), use = saved.uses.first { $0.id == card.binding!.use }!
        check(use.positions[slider.id] == .scalar(0.6) && use.positions[choice.id] == .scalar(options[2].position), "1 reopen preserves slider0.6 and second choice")
        check(await f.port.writes == 2, "1 one gesture write plus combined click write")
        let delayCalls = await f.delay.arrivals, writesBeforeOrdinary = await f.port.writes
        let laterOption = options.first { $0.id != f.card.effectiveOption(f.choice)?.id }!
        let later = await f.move(laterOption.position, token: nil, card: f.card, control: f.choice)
        await f.delay.entered(after: delayCalls); await f.delay.release()
        await f.port.awaitWrite(writesBeforeOrdinary + 1); await f.app.coordinator.waitForIssuedSaves()
        let laterWrites = await f.port.writes
        check(later != "superseded" && laterWrites == writesBeforeOrdinary + 1, "1 later ordinary edit still schedules save")
        await f.close()
    }
    @MainActor private static func retiredCallbacks() async throws {
        let f = try await RaceFixture(), card = f.card, control = f.slider
        let g1 = try f.begin()
        for value in [0.2, 0.4, 0.6] { _ = await f.move(value, token: g1, card: card) }
        f.playback = []
        await f.port.arm(); f.end(); let first = f.app.gestureSave!
        // No await between end and the old callback: the save Task has not executed.
        let immediate = f.issue(0.1, token: g1, card: card)
        let result = await immediate.value()
        check(result == "superseded", "2 old callback immediately after end is superseded: \(result)")
        await f.port.gate.entered()
        let freshCard = f.card, g2 = try f.begin()
        let a = await f.move(0.7, token: g2, card: freshCard)
        let stale = await f.move(0.15, token: g1, card: card)
        let b = await f.move(0.8, token: g2, card: freshCard), c = await f.move(0.9, token: g2, card: freshCard)
        let raw = await f.move(0.05, token: nil, card: card)
        f.end(); let second = f.app.gestureSave!
        let late = f.issue(0.25, token: g2, card: freshCard)
        let afterEnd = await late.value()
        check([a,b,c].allSatisfy { $0 != "superseded" }, "2 all three fresh held-save samples admitted: \(a),\(b),\(c)")
        check(stale == "superseded" && raw == "superseded" && afterEnd == "superseded", "2 old identity, raw old epoch and late fresh callback refused")
        await f.port.gate.release(); _ = await first.value; _ = await second.value
        let saved = try await f.finish()
        check(saved.uses.first { $0.id == card.binding!.use }!.positions[control.id] == .scalar(0.9), "2 reopen final0.9")
        let reference = try await SoundLibrarySession(persistence: RacePort(await f.port.bytes), limits: LibraryAppSession.normalLimits())
        _ = try await reference.move(control.address, expected: card.binding!, to: .scalar(0.9))
        let expected = ListeningRenderSnapshot(library: try await reference.snapshot())
        check(f.playback.last == expected, "2 real playback consumer final complete program equals independently expected0.9")
        var forbiddenDelivered = false
        for value in [0.1, 0.15, 0.05, 0.25] {
            _ = try await reference.move(control.address, expected: card.binding!, to: .scalar(value))
            let forbidden = ListeningRenderSnapshot(library: try await reference.snapshot())
            forbiddenDelivered = forbiddenDelivered || f.playback.contains(forbidden)
        }
        check(!forbiddenDelivered, "2 playback never receives any retired callback complete program")
        await f.close()
    }
    @MainActor private static func pendingAtEnd() async throws {
        let f = try await RaceFixture(), card = f.card, control = f.slider, token = try f.begin()
        _ = await f.move(0.2, token: token, card: card)
        // Actual request admitted before end, intentionally not awaited until after end and stale callback submission.
        let pending = try f.app.coordinator.submitSliderMove(control.address, expected: card.binding!, to: .scalar(0.6),
            optionGesture: control.optionGesture, menuIdentity: card.menuIdentity, expectedEpoch: card.menuEpoch, gestureIdentity: token)
        f.end()
        let late = try f.app.coordinator.submitSliderMove(control.address, expected: card.binding!, to: .scalar(0.1),
            optionGesture: control.optionGesture, menuIdentity: card.menuIdentity, expectedEpoch: card.menuEpoch, gestureIdentity: token)
        let beforeEnd = try await pending.value, afterEnd = try await late.value
        _ = await f.app.gestureSave?.value
        let saved = try await f.finish()
        let admitted: Bool
        switch beforeEnd { case .executed(.superseded), .fenced(.superseded): admitted = false; default: admitted = true }
        let refused: Bool
        switch afterEnd { case .executed(.superseded), .fenced(.superseded): refused = true; default: refused = false }
        check(admitted && refused && saved.uses.first { $0.id == card.binding!.use }!.positions[control.id] == .scalar(0.6),
            "2-pending valid pre-end latest drains; immediate post-end callback refuses")
        await f.close()
    }
    @MainActor private static func clickThenDrag() async throws {
        let f = try await RaceFixture(), card = f.card, slider = f.slider, choice = f.choice
        guard case .choice(let options) = choice.face else { throw RaceError.setup("choice") }
        let g1 = try f.begin()
        _ = await f.move(0.3, token: g1, card: card); _ = await f.move(0.5, token: g1, card: card)
        await f.port.arm(); f.end(); let first = f.app.gestureSave!
        await f.port.gate.entered(); await f.reads.arm()
        let clicked = await f.move(options[1].position, token: nil, card: card, control: choice)
        await f.reads.gate.entered()
        let g2 = try f.begin()
        var outcomes: [String] = []
        for value in [0.6, 0.7, 0.8] { outcomes.append(await f.move(value, token: g2, card: card)) }
        f.end(); let second = f.app.gestureSave!
        await f.reads.gate.release(); await f.port.gate.release()
        _ = await first.value; _ = await second.value
        let saved = try await f.finish(), use = saved.uses.first { $0.id == card.binding!.use }!
        check(clicked != "superseded" && outcomes.allSatisfy { $0 != "superseded" }, "3 choice and all fresh samples during held follow-up read admitted: \(outcomes)")
        check(use.positions[slider.id] == .scalar(0.8) && use.positions[choice.id] == .scalar(options[1].position), "3 reopen preserves choice and fresh slider0.8")
        await f.close()
    }
    @MainActor private static func editorBarrier(_ variant: String) async throws {
        let f = try await RaceFixture(), card = f.card, slider = f.slider
        let commands = TNFEditorCommands(app: f.app)
        try await commands.select(.use(card.binding!)); await f.app.editor.displaySettled()
        try await commands.refresh(); await f.app.editor.displaySettled()
        await f.app.menuOpened().value
        let captured = f.card, token = try f.begin()
        let initialA = await f.move(0.3, token: token, card: captured), initialB = await f.move(0.4, token: token, card: captured)
        print("RACE SETUP 4-\(variant) firstMoves=\(initialA),\(initialB) cardEpoch=\(String(describing: captured.menuEpoch)) contextEpoch=\(String(describing: f.app.coordinator.positionContext?.epoch))")
        if variant == "query" { _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() } }
        else if variant == "read" { _ = try await f.app.coordinator.editorRead(f.app.editor.state.edit!.handle) }
        else if variant == "playback" { f.app.coordinator.playbackDidChange(); _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() } }
        else { _ = await f.app.coordinator.submitSelect(card.menuIdentity!.reference.definition, on: "test.other").value }
        let flushed = try await f.owner.snapshot().uses.first { $0.id == card.binding!.use }!.positions[slider.id]
        check(flushed == .scalar(0.4), "4-\(variant) honest barrier flushes0.4 actual=\(String(describing: flushed))")
        let a = await f.move(0.6, token: token, card: captured), b = await f.move(0.8, token: token, card: captured)
        f.end(); _ = await f.app.gestureSave?.value
        if variant == "playback" || variant == "structural" {
            let saved = try await f.finish()
            check(a == "superseded" && b == "superseded" && saved.uses.first { $0.id == card.binding!.use }!.positions[slider.id] == .scalar(0.4), "4-\(variant) real semantic barrier retires old gesture")
        } else {
            guard case .choice(let options) = f.choice.face else { throw RaceError.setup("choice") }
            let choice = f.choice
            let click = await f.move(options[1].position, token: nil, card: f.card, control: choice)
            let first = try await f.finish().uses.first { $0.id == card.binding!.use }!
            check(a != "superseded" && b != "superseded" && click != "superseded" && first.positions[slider.id] == .scalar(0.8) && first.positions[choice.id] == .scalar(options[1].position), "4-\(variant) same identified gesture continues0.8 and choice saves")
            await f.app.menuOpened().value
            #if PR39_LEGACY_EDITOR_READ
            print("RACE ADAPTER 4-\(variant) legacy editorQuery has no completion projection read to hold; original fresh-drag order retained")
            #else
            await f.reads.arm()
            let followup = Task { _ = try await f.app.coordinator.editorQuery { try await $0.snapshot() } }
            await f.reads.gate.entered()
            #endif
            let current = f.card
            print("RACE FRESH 4-\(variant) cardEpoch=\(String(describing: current.menuEpoch)) contextEpoch=\(String(describing: f.app.coordinator.positionContext?.epoch))")
            let next = try f.begin()
            let moved = await f.move(0.5, token: next, card: current)
            f.end()
            #if !PR39_LEGACY_EDITOR_READ
            await f.reads.gate.release(); try await followup.value
            #endif
            _ = await f.app.gestureSave?.value
            let saved = try await f.finish()
            let final = saved.uses.first { $0.id == card.binding!.use }!.positions[slider.id]
            check(moved != "superseded" && final == .scalar(0.5), "4-\(variant) menu reopen fresh drag0.5 saves result=\(moved) final=\(String(describing: final))")
        }
        await f.close()
    }
}

@MainActor private final class RaceLaneTrace {
    let gate = RaceGate(), completed = RaceSignal(), running = RaceSignal()
    var phase = 0
    var hold = true
    var outputStarts = 0, captureStarts = 0, stops = 0
    var lastParts: [ListeningRenderPart] = []
    var states: [String] = []
    func pause(_ point: Int) async { if hold && phase == point { hold = false; await gate.pause() } }
    func finished(_ state: String) { states.append(state); completed.send(); if state == "running" { running.send() } }
}
@MainActor private struct RaceResolver: ProcessResolving {
    func resolve(binding: AppBinding, preferredPID: Int32?) async throws -> ResolvedProcess { ResolvedProcess(binding: binding, pid: 1, audioProcessID: 1, path: .preferredPID) }
    func revalidate(_ process: ResolvedProcess) async throws {}
}
@MainActor private struct RaceGuard: InputGuardPort {
    func recoverIfStranded() async -> GuardRestoration { .noMarker }
    func engage(settingEnabled: Bool) async -> GuardEngagement { .declined(reason: "inert lifecycle fake") }
    func restore() async -> GuardRestoration { .noMarker }
}
@MainActor private final class RaceCapture: CaptureSession {
    let trace: RaceLaneTrace
    init(_ trace: RaceLaneTrace) { self.trace = trace }
    func prepare(source: ResolvedProcess) async throws -> CapturePreparation { await trace.pause(0); return CapturePreparation(format: try StreamFormat(sampleRate: 48000, channels: 2)) }
    func start() async throws { await trace.pause(2); try Task.checkCancellation(); trace.captureStarts += 1 }
    func stop() async -> TeardownOutcome { .completed }
}
@MainActor private struct RaceCaptureFactory: CaptureSessionFactory {
    let trace: RaceLaneTrace
    func makeSession() -> any CaptureSession { RaceCapture(trace) }
}
@MainActor private final class RaceSink: PlaybackSink {
    let trace: RaceLaneTrace
    init(_ trace: RaceLaneTrace, assignment: ListeningRenderAssignment) { self.trace = trace; trace.lastParts = assignment.parts }
    func prepare(_ capture: CapturePreparation) async throws { await trace.pause(1) }
    func update(_ assignment: ListeningRenderAssignment, original: Bool) throws { trace.lastParts = assignment.parts }
    func start() throws { trace.outputStarts += 1 }
    func stop() async { trace.stops += 1 }
}
extension PR39RaceCases {
    @MainActor fileprivate static func starting(_ variant: String, phase: Int) async throws {
        let f = try await RaceFixture(attachConsumer: false), trace = RaceLaneTrace()
        trace.phase = phase
        let controller = PlaybackController(testingLane: { assignment, observe in
            let factory = PlaybackCaptureFactory(inner: RaceCaptureFactory(trace: trace), assignment: assignment) { value, _ in RaceSink(trace, assignment: value) }
            return (factory, PlaybackRuntime(resolver: RaceResolver(), factory: factory,
                leases: InputGuardLeaseCoordinator(port: RaceGuard(), settingEnabled: false), observe: observe))
        })
        controller.startedForTesting = { _, state in trace.finished(state) }
        controller.stoppedForTesting = { _, state in trace.finished(state) }
        var deliveries = 0
        _ = await f.app.coordinator.attachPlayback { snapshot, original, mode in
            deliveries += 1
            switch mode { case .positions: _ = controller.updatePositions(snapshot, original: original); default: controller.apply(snapshot, original: original) }
        }
        _ = try await f.app.coordinator.submitEnabled(true).value
        await f.app.coordinator.refresh()
        await trace.gate.entered()
        let outputBefore = trace.outputStarts, captureBefore = trace.captureStarts
        if variant == "parameters" {
            _ = try await f.app.coordinator.submitMove(f.slider.address, expected: f.card.binding!, to: .scalar(0.9)).value
            await f.app.coordinator.refresh(mode: .positions)
        } else {
            _ = try await f.app.coordinator.submitEnabled(false).value
            let offDeliveries = deliveries
            await f.app.coordinator.refresh()
            check(deliveries == offDeliveries, "5-\(variant)/\(phase) identical OFF activation deduplicated by real coordinator")
            if variant == "restart" { _ = try await f.app.coordinator.submitEnabled(true).value; await f.app.coordinator.refresh() }
        }
        await trace.gate.release()
        if variant == "off" {
            await trace.completed.wait()
            check(trace.outputStarts == outputBefore && trace.captureStarts == captureBefore && trace.states.last == "idle", "5-off/\(phase) no post-OFF output/capture and idle completion")
        } else {
            await trace.running.wait()
            let expected = ListeningRenderSnapshot(library: try await f.owner.snapshot()).assignments[0]
            if variant == "restart" {
                check(trace.outputStarts == outputBefore + 1 && trace.captureStarts == captureBefore + 1 && trace.running.count == 1,
                    "5-restart/\(phase) explicit ON produces exactly one new running lane")
            } else {
                check(trace.outputStarts == 1 && trace.captureStarts == 1 && trace.stops == 0 && trace.lastParts == expected.parts,
                    "5-parameters/\(phase) one uninterrupted start receives latest complete parameters")
            }
        }
        await controller.shutdown(); await f.close()
    }
}

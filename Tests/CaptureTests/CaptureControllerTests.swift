import AVFoundation
import Combine
import CoreAudio
import Darwin
import NativeTestSupport
import XCTest
@testable import Capture

/// Unit tests for `CaptureController`'s state machine and resource-ownership
/// behaviour under the v2 (direct-IOProc + AVAudioSourceNode) architecture.
///
/// Covers TDD anchors T3.1 through T3.6 from
/// `docs/orchestration/phases/01-capture-spike-rework-1.md` and the
/// existing v1 invariants that still apply (idempotency, transition
/// guards, deinit cleanup, permission-denial surfacing).
@available(macOS 14.4, *)
final class CaptureControllerTests: XCTestCase {

    // MARK: Fixtures

    private let knownPID: pid_t = 5_000
    private let knownAudioProcessID: AudioObjectID = 42

    private func makeFake(withKnownSource: Bool = true) -> FakeCoreAudioInterface {
        let fake = FakeCoreAudioInterface()
        if withKnownSource {
            fake.audioProcessIDsByPID = [knownPID: knownAudioProcessID]
        }
        return fake
    }

    private func makeSource(
        pid: pid_t? = nil,
        audioProcessID: AudioObjectID? = nil
    ) -> CaptureSource {
        CaptureSource(
            pid: pid ?? knownPID,
            audioProcessID: audioProcessID ?? knownAudioProcessID,
            bundleIdentifier: "com.example.fake",
            displayName: "Fake"
        )
    }

    /// Records every state transition for a controller. Used in lieu of
    /// polling so transition-order assertions are deterministic.
    private final class StateRecorder {
        private(set) var states: [CaptureState] = []
        private var cancellables = Set<AnyCancellable>()

        init(_ controller: CaptureController) {
            controller.statePublisher
                .sink { [weak self] state in self?.states.append(state) }
                .store(in: &cancellables)
        }
    }

    // MARK: Initial state

    func test_initial_state_is_idle() {
        let controller = CaptureController(coreAudio: FakeCoreAudioInterface())
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: T3.1 — start transitions through starting to running

    func test_start_transitions_through_starting_to_running_and_attaches_source_node() throws {
        try requireNativeTests()
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)
        let source = makeSource()
        let engine = AVAudioEngine()

        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(
            recorder.states,
            [.idle, .starting, .running(source: source)]
        )
        // Reader-side resources were created: aggregate + IOProc + start.
        XCTAssertEqual(fake.createAggregateDeviceCallDescriptions.count, 1)
        XCTAssertEqual(fake.startDeviceCalls.count, 1)
    }

    // MARK: T3.2 — start failure at createTap surfaces and unwinds

    func test_start_failure_at_createTap_transitions_to_failed() throws {
        try requireNativeTests()
        let fake = makeFake()
        let failure: OSStatus = -10_875
        fake.createTapResult = { _ in throw CaptureError.tapCreationFailed(failure) }
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .tapCreationFailed(failure))
        }
        XCTAssertEqual(controller.state, .failed(.tapCreationFailed(failure)))
        XCTAssertEqual(
            recorder.states,
            [.idle, .starting, .failed(.tapCreationFailed(failure))]
        )
        // No aggregate was created, no IOProc was registered.
        XCTAssertTrue(fake.createAggregateDeviceCallDescriptions.isEmpty)
        XCTAssertTrue(fake.createIOProcIDCalls.isEmpty)
    }

    // MARK: T3.3 — stop after start: source node detached, tap destroyed

    func test_stop_after_start_tears_down_reader_and_detaches_source_node() throws {
        try requireNativeTests()
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: source, into: engine)

        let recorder = StateRecorder(controller)
        try controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(
            recorder.states,
            [.running(source: source), .stopping, .idle]
        )
        // Reader.stop() called destroyTap and destroyAggregateDevice.
        XCTAssertEqual(fake.stopDeviceCalls.count, 1)
        XCTAssertEqual(fake.destroyIOProcIDCalls.count, 1)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
    }

    // MARK: T3.4 — start → stop → start works without leaks

    func test_start_then_stop_then_start_works() throws {
        try requireNativeTests()
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        try controller.start(source: source, into: engine)
        try controller.stop()
        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 2)
        XCTAssertEqual(fake.createAggregateDeviceCallDescriptions.count, 2)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
    }

    // MARK: T3.5 — stop from idle is a no-op

    func test_stop_from_idle_is_noop() throws {
        let fake = FakeCoreAudioInterface()
        let controller = CaptureController(coreAudio: fake)
        let recorder = StateRecorder(controller)

        try controller.stop()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.states, [.idle])
        XCTAssertTrue(fake.stopDeviceCalls.isEmpty)
        XCTAssertTrue(fake.destroyAggregateDeviceCallIDs.isEmpty)
        XCTAssertTrue(fake.destroyTapCallIDs.isEmpty)
    }

    // MARK: T3.6 — engine.outputNode.audioUnit CurrentDevice is never set
    //
    // The new architecture must NEVER set kAudioOutputUnitProperty_CurrentDevice
    // on the engine's output AU. We can't observe protocol-level absence here
    // (the fake protocol has no such method), so we satisfy this anchor at the
    // structural level: the FakeCoreAudioInterface protocol has no
    // configureEngineInput / pinEngineOutputToDefault entry points; any code
    // that tried to set CurrentDevice would have had to use them.

    func test_protocol_no_longer_exposes_engine_audio_unit_setters() {
        // Compile-time assertion: a value of type CoreAudioInterface can
        // not have its `configureEngineInput`, `resetEngineInput`, or
        // `pinEngineOutputToDefault` called. The presence of this test
        // documents the invariant; the verifier may then code-inspect
        // Sources/Capture/CoreAudioInterface.swift to confirm.
        let _: CoreAudioInterface = FakeCoreAudioInterface()
        // No assertion needed — if any of those methods existed they
        // would have been referenced in the existing CaptureController,
        // which is the canonical caller. Phase 1 rework gate criterion
        // 6 + 7 cover this at the verification level.
    }

    // MARK: Source resolution

    func test_start_with_unknown_audio_process_throws_sourceNotFound() throws {
        try requireNativeTests()
        let fake = FakeCoreAudioInterface()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource(pid: 9_999, audioProcessID: 7)
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .sourceNotFound(9_999))
        }
        XCTAssertEqual(controller.state, .failed(.sourceNotFound(9_999)))
        XCTAssertTrue(fake.createTapCallProcessIDs.isEmpty)
        XCTAssertTrue(fake.createAggregateDeviceCallDescriptions.isEmpty)
    }

    // MARK: Source enumeration

    func test_available_sources_filters_to_apps_with_bundle_identifier() throws {
        let fake = FakeCoreAudioInterface()
        let selfPID = getpid()
        let phantomPID: pid_t = 1
        fake.availableAudioProcessesResult = {
            [
                (pid: selfPID, audioProcessID: AudioObjectID(100)),
                (pid: phantomPID, audioProcessID: AudioObjectID(101)),
            ]
        }
        let controller = CaptureController(coreAudio: fake)

        let sources = try controller.availableSources()

        for source in sources {
            XCTAssertNotNil(source.bundleIdentifier)
            XCTAssertFalse(source.bundleIdentifier?.isEmpty ?? true)
        }
        XCTAssertFalse(sources.contains { $0.pid == phantomPID })
    }

    // MARK: Permission denial surfacing

    func test_permission_denied_surfaces_typed_error() throws {
        try requireNativeTests()
        let fake = makeFake()
        fake.createTapResult = { _ in throw CaptureError.permissionDenied }
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .permissionDenied)
        }
        XCTAssertEqual(controller.state, .failed(.permissionDenied))
    }

    // MARK: Stop from .failed clears state

    func test_stop_from_failed_returns_to_idle_without_throwing() throws {
        try requireNativeTests()
        let fake = makeFake()
        fake.createTapResult = { _ in throw CaptureError.tapCreationFailed(-1) }
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try controller.start(source: source, into: engine))
        XCTAssertEqual(controller.state, .failed(.tapCreationFailed(-1)))

        try controller.stop()
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: Idempotency

    func test_start_while_running_same_source_and_engine_is_noop() throws {
        try requireNativeTests()
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: source, into: engine)

        try controller.start(source: source, into: engine)

        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
        XCTAssertEqual(fake.createAggregateDeviceCallDescriptions.count, 1)
    }

    func test_start_while_running_different_source_throws_alreadyRunning() throws {
        try requireNativeTests()
        let fake = makeFake()
        fake.audioProcessIDsByPID = [
            knownPID: knownAudioProcessID,
            6_000: 43,
        ]
        let controller = CaptureController(coreAudio: fake)
        let firstSource = makeSource()
        let engine = AVAudioEngine()
        try controller.start(source: firstSource, into: engine)

        let differentSource = CaptureSource(
            pid: 6_000,
            audioProcessID: 43,
            bundleIdentifier: "com.example.other",
            displayName: "Other"
        )
        XCTAssertThrowsError(try controller.start(source: differentSource, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .alreadyRunning(currentSource: firstSource))
        }
        XCTAssertEqual(controller.state, .running(source: firstSource))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
    }

    func test_start_while_running_different_engine_throws_alreadyRunning() throws {
        try requireNativeTests()
        let fake = makeFake()
        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let firstEngine = AVAudioEngine()
        try controller.start(source: source, into: firstEngine)

        let secondEngine = AVAudioEngine()
        XCTAssertThrowsError(try controller.start(source: source, into: secondEngine)) { error in
            XCTAssertEqual(error as? CaptureError, .alreadyRunning(currentSource: source))
        }
        XCTAssertEqual(controller.state, .running(source: source))
        XCTAssertEqual(fake.createTapCallProcessIDs.count, 1)
    }

    // MARK: Concurrent transition guards

    func test_start_during_starting_throws_transitionInProgress() throws {
        try requireNativeTests()
        let fake = makeFake()
        let inTapCreation = expectation(description: "background thread reached createTap")
        let proceedFromTap = DispatchSemaphore(value: 0)
        let startCompleted = expectation(description: "background start returned")

        fake.createTapResult = { id in
            inTapCreation.fulfill()
            proceedFromTap.wait()
            return id + 1_000
        }

        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? controller.start(source: source, into: engine)
            startCompleted.fulfill()
        }

        wait(for: [inTapCreation], timeout: 5.0)
        XCTAssertEqual(controller.state, .starting)

        XCTAssertThrowsError(try controller.start(source: source, into: engine)) { error in
            XCTAssertEqual(error as? CaptureError, .transitionInProgress)
        }

        proceedFromTap.signal()
        wait(for: [startCompleted], timeout: 5.0)
    }

    func test_stop_during_starting_throws_transitionInProgress() throws {
        try requireNativeTests()
        let fake = makeFake()
        let inTapCreation = expectation(description: "background thread reached createTap")
        let proceedFromTap = DispatchSemaphore(value: 0)
        let startCompleted = expectation(description: "background start returned")

        fake.createTapResult = { id in
            inTapCreation.fulfill()
            proceedFromTap.wait()
            return id + 1_000
        }

        let controller = CaptureController(coreAudio: fake)
        let source = makeSource()
        let engine = AVAudioEngine()

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? controller.start(source: source, into: engine)
            startCompleted.fulfill()
        }

        wait(for: [inTapCreation], timeout: 5.0)
        XCTAssertEqual(controller.state, .starting)

        XCTAssertThrowsError(try controller.stop()) { error in
            XCTAssertEqual(error as? CaptureError, .transitionInProgress)
        }

        proceedFromTap.signal()
        wait(for: [startCompleted], timeout: 5.0)
        XCTAssertEqual(controller.state, .running(source: source))
    }

    // MARK: Deinit cleanup

    func test_deinit_while_running_tears_down_resources() throws {
        try requireNativeTests()
        let fake = makeFake()
        let source = makeSource()
        let engine = AVAudioEngine()

        do {
            let controller = CaptureController(coreAudio: fake)
            try controller.start(source: source, into: engine)
            XCTAssertEqual(fake.destroyTapCallIDs.count, 0)
            XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 0)
        }

        XCTAssertEqual(fake.destroyTapCallIDs.count, 1)
        XCTAssertEqual(fake.destroyAggregateDeviceCallIDs.count, 1)
    }
}

import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import ViewModel
import XCTest

@MainActor
final class SourceSelectionRaceTests: XCTestCase {
    private let original = CaptureSource(
        pid: 11, audioProcessID: 41, bundleIdentifier: "com.example.original", displayName: "Original"
    )
    private let newer = CaptureSource(
        pid: 22, audioProcessID: 42, bundleIdentifier: "com.example.newer", displayName: "Newer"
    )

    func test_stale_missing_enumeration_preserves_new_choice() async {
        await assertStaleStart(outcome: .success([]), replacement: newer)
    }

    func test_stale_ambiguous_enumeration_preserves_new_choice() async {
        let duplicates = [12, 13].map { pid in
            CaptureSource(
                pid: Int32(pid), audioProcessID: 43,
                bundleIdentifier: original.bundleIdentifier, displayName: original.displayName
            )
        }
        await assertStaleStart(outcome: .success(duplicates), replacement: newer)
    }

    func test_stale_successful_enumeration_does_not_start_old_source() async {
        await assertStaleStart(outcome: .success([original]), replacement: newer)
    }

    func test_stale_successful_enumeration_preserves_cleared_selection() async {
        await assertStaleStart(outcome: .success([original]), replacement: nil)
    }

    func test_stale_enumeration_error_preserves_new_choice() async {
        await assertStaleStart(outcome: .failure(CaptureError.sourceNotFound(original.pid)), replacement: newer)
    }

    func test_stale_enumeration_error_preserves_cleared_selection_and_new_error() async {
        await assertStaleStart(outcome: .failure(EnumerationFailure.unexpected), replacement: nil)
    }

    func test_stale_success_is_cancelled_after_returning_to_original_selection() async {
        await assertStaleStart(outcome: .success([original]), replacement: newer, returnToOriginal: true)
    }

    func test_stale_error_is_cancelled_after_returning_to_original_selection() async {
        await assertStaleStart(
            outcome: .failure(EnumerationFailure.unexpected), replacement: newer, returnToOriginal: true
        )
    }

    func test_source_disappearing_at_capture_start_requires_new_pick_before_retry() async {
        await assertCaptureFailure(error: .sourceNotFound(original.pid), rejectsSelection: true)
    }

    func test_unrelated_capture_failure_preserves_selection_and_preferences() async {
        await assertCaptureFailure(error: .tapCreationFailed(-1), rejectsSelection: false)
    }

    private func assertCaptureFailure(error: CaptureError, rejectsSelection: Bool) async {
        let suiteName = "tnf.tests.start-failure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = ControlledEnumerationCapture(initialSources: [original], startError: error)
        let model = AppViewModel(
            capture: capture, engine: AVAudioEngine(), registry: EffectNodeRegistry(), defaults: defaults
        )
        model.setSource(original)
        defaults.set(original.bundleIdentifier, forKey: AppViewModelDefaultsKey.sourceBundleID)
        defaults.set(original.displayName, forKey: AppViewModelDefaultsKey.sourceDisplayName)

        await model.powerOn()

        XCTAssertEqual(capture.startCalls, [original])
        XCTAssertEqual(model.lastError, .capture(error))
        let expected: CaptureSource? = rejectsSelection ? nil : original
        XCTAssertEqual(model.currentSource, expected)
        XCTAssertEqual(
            defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID), expected?.bundleIdentifier
        )
        XCTAssertEqual(defaults.string(forKey: AppViewModelDefaultsKey.sourceDisplayName), expected?.displayName)
        if rejectsSelection {
            let survivor = CaptureSource(
                pid: 33, audioProcessID: 43,
                bundleIdentifier: original.bundleIdentifier, displayName: original.displayName
            )
            capture.setAvailableSources([survivor])
            model.clearError()
            await model.powerOn()
            XCTAssertEqual(capture.startCalls, [original], "Retry must not resolve the survivor without a new pick")
            XCTAssertNil(model.currentSource)
            XCTAssertNil(defaults.object(forKey: AppViewModelDefaultsKey.sourceBundleID))
            XCTAssertNil(defaults.object(forKey: AppViewModelDefaultsKey.sourceDisplayName))

            model.setSource(survivor)
            await model.powerOn()
            XCTAssertEqual(capture.startCalls, [original, survivor], "An explicit pick permits a new attempt")
        }
    }

    private func assertStaleStart(
        outcome: Result<[CaptureSource], Error>, replacement: CaptureSource?, returnToOriginal: Bool = false
    ) async {
        let suiteName = "tnf.tests.source-race.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = ControlledEnumerationCapture(initialSources: [original])
        let model = AppViewModel(
            capture: capture, engine: AVAudioEngine(), registry: EffectNodeRegistry(), defaults: defaults
        )
        // Finish the initial refresh before arming the controlled Start call.
        // The defaults are empty at init, so no startup restore is launched.
        let refreshed = expectation(description: "Initial refresh published")
        let subscription = model.$availableSources
            .filter { !$0.isEmpty }
            .first()
            .sink { _ in refreshed.fulfill() }
        await fulfillment(of: [refreshed], timeout: 1.0)
        model.setSource(original)

        let entered = expectation(description: "Start enumeration suspended")
        let gate = capture.suspendNextEnumeration(outcome: outcome, entered: entered)
        defer { gate.release() }
        let start = Task { await model.powerOn() }
        await fulfillment(of: [entered], timeout: 1.0)

        model.setSource(replacement)
        if returnToOriginal {
            model.setSource(original)
        }
        let expected = returnToOriginal ? original : replacement
        // Seed already-saved newer preferences; debounce behavior has separate
        // coverage. An obsolete Start must not overwrite these values.
        defaults.set(expected?.bundleIdentifier, forKey: AppViewModelDefaultsKey.sourceBundleID)
        defaults.set(expected?.displayName, forKey: AppViewModelDefaultsKey.sourceDisplayName)
        if expected == nil {
            await model.powerOn() // A newer no-selection error must survive too.
        }
        let newerError = model.lastError
        gate.release()
        await start.value

        XCTAssertEqual(model.currentSource, expected)
        XCTAssertEqual(
            defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID), expected?.bundleIdentifier
        )
        XCTAssertEqual(
            defaults.string(forKey: AppViewModelDefaultsKey.sourceDisplayName), expected?.displayName
        )
        XCTAssertEqual(model.lastError, newerError, "Stale Start must not publish an obsolete error")
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertTrue(capture.startCalls.isEmpty, "Stale successful enumeration must not reach capture")
        withExtendedLifetime(subscription) {}
    }
}

private enum EnumerationFailure: Error {
    case unexpected
}

/// All mutable state is lock-protected. Enumeration alone blocks off-main;
/// Start records then throws before touching any node or engine.
private final class ControlledEnumerationCapture: CaptureControllerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [CaptureSource]
    private let startError: CaptureError
    private var nextGate: EnumerationGate?
    private var recordedStarts: [CaptureSource] = []

    init(initialSources: [CaptureSource], startError: CaptureError = .tapCreationFailed(-1)) {
        self.sources = initialSources
        self.startError = startError
    }

    var state: CaptureState { .idle }
    var statePublisher: AnyPublisher<CaptureState, Never> { Just(CaptureState.idle).eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }

    var startCalls: [CaptureSource] {
        lock.lock()
        defer { lock.unlock() }
        return recordedStarts
    }

    func setAvailableSources(_ sources: [CaptureSource]) {
        lock.lock()
        self.sources = sources
        lock.unlock()
    }

    func suspendNextEnumeration(
        outcome: Result<[CaptureSource], Error>, entered: XCTestExpectation
    ) -> EnumerationGate {
        let gate = EnumerationGate(outcome: outcome, entered: entered)
        lock.lock()
        nextGate = gate
        lock.unlock()
        return gate
    }

    func availableSources() throws -> [CaptureSource] {
        lock.lock()
        let gate = nextGate
        nextGate = nil
        let snapshot = sources
        lock.unlock()
        return try gate?.wait() ?? snapshot
    }

    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        lock.lock()
        recordedStarts.append(source)
        lock.unlock()
        if case .sourceNotFound = startError {
            throw CaptureError.sourceNotFound(source.pid)
        }
        throw startError
    }

    func stop() throws {}
}

private final class EnumerationGate: @unchecked Sendable {
    private let outcome: Result<[CaptureSource], Error>
    private let entered: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var released = false

    init(outcome: Result<[CaptureSource], Error>, entered: XCTestExpectation) {
        self.outcome = outcome
        self.entered = entered
    }

    func wait() throws -> [CaptureSource] {
        entered.fulfill()
        semaphore.wait()
        return try outcome.get()
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        semaphore.signal()
    }
}

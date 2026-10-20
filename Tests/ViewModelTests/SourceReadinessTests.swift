import AVFoundation
import Capture
import Effects
import Foundation
import Graph
import ViewModel
import XCTest

/// Proposed Stage B seam: `isPowerActionEnabled` and
/// `sourceReadinessMessage` are computed AppViewModel properties, not present
/// at Stage A. Until implemented, this file is a structural red only.
/// PowerToggle must consume this policy; these tests do not inspect SwiftUI
/// rendering, help modifiers, or VoiceOver delivery.
@MainActor
final class SourceReadinessTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "tnf.source-readiness.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func test_idle_without_source_disables_start_and_explains_how_to_select_one() async throws {
        let model = try await makeModel(capture: MockCaptureController())

        XCTAssertFalse(model.isPowerActionEnabled)
        assertPickerGuidance(model.sourceReadinessMessage)
    }

    func test_idle_with_chosen_source_enables_start_without_starting_automatically() async throws {
        let capture = MockCaptureController()
        let model = try await makeModel(capture: capture)
        let source = makeSource()

        model.setSource(source)

        XCTAssertTrue(model.isPowerActionEnabled)
        XCTAssertNil(model.sourceReadinessMessage)
        XCTAssertEqual(model.currentSource, source)
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertTrue(capture.startCalls.isEmpty)
    }

    func test_starting_and_stopping_remain_locked_with_or_without_a_source() async throws {
        for state in [CaptureState.starting, .stopping] {
            let capture = MockCaptureController(initialState: state)
            let model = try await makeModel(capture: capture)

            XCTAssertFalse(model.isPowerActionEnabled, "Transition without source: \(state)")
            model.currentSource = makeSource()
            XCTAssertFalse(model.isPowerActionEnabled, "Transition with source: \(state)")
            XCTAssertTrue(capture.startCalls.isEmpty)
            XCTAssertEqual(capture.stopCallCount, 0)
        }
    }

    func test_failed_without_source_disables_retry_and_explains_how_to_select_one() async throws {
        let capture = MockCaptureController(initialState: .failed(.permissionDenied))
        let model = try await makeModel(capture: capture)

        XCTAssertFalse(model.isPowerActionEnabled)
        assertPickerGuidance(model.sourceReadinessMessage)
        XCTAssertEqual(model.lastError, .capture(.permissionDenied), "Readiness must not clear the failure")
    }

    func test_failed_with_chosen_source_enables_retry_without_clearing_error_or_starting() async throws {
        let capture = MockCaptureController(initialState: .failed(.permissionDenied))
        let model = try await makeModel(capture: capture)
        model.setSource(makeSource())

        XCTAssertTrue(model.isPowerActionEnabled)
        XCTAssertNil(model.sourceReadinessMessage)
        XCTAssertEqual(model.lastError, .capture(.permissionDenied))
        XCTAssertTrue(capture.startCalls.isEmpty)
    }

    func test_running_without_current_selection_keeps_stop_enabled() async throws {
        let capture = MockCaptureController(initialState: .running(source: makeSource()))
        let model = try await makeModel(capture: capture)

        XCTAssertNil(model.currentSource)
        XCTAssertTrue(model.isPowerActionEnabled)
        XCTAssertNil(model.sourceReadinessMessage, "Do not tell the user to select a source before stopping")
        XCTAssertEqual(capture.stopCallCount, 0)
    }

    func test_running_after_selected_source_disappears_from_refresh_keeps_stop_enabled() async throws {
        let source = makeSource()
        let capture = MockCaptureController(initialState: .running(source: source))
        capture.availableSourcesResult = [source]
        let model = try await makeModel(capture: capture)
        model.currentSource = source
        try await waitUntil { model.availableSources == [source] }

        capture.availableSourcesResult = []
        model.refreshAvailableSources()
        try await waitUntil { model.availableSources.isEmpty }

        XCTAssertEqual(model.captureState, .running(source: source))
        XCTAssertTrue(model.isPowerActionEnabled)
        XCTAssertNil(model.sourceReadinessMessage)
        XCTAssertTrue(capture.startCalls.isEmpty)
        XCTAssertEqual(capture.stopCallCount, 0)
    }

    func test_source_refresh_does_not_select_or_start_an_available_source() async throws {
        let capture = MockCaptureController()
        capture.availableSourcesResult = [makeSource()]
        let model = try await makeModel(capture: capture)
        try await waitUntil { !model.availableSources.isEmpty }

        XCTAssertNil(model.currentSource)
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertFalse(model.isPowerActionEnabled)
        assertPickerGuidance(model.sourceReadinessMessage)
        XCTAssertTrue(capture.startCalls.isEmpty)
    }

    // MARK: Helpers

    private func makeModel(capture: MockCaptureController) async throws -> AppViewModel {
        let model = AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
        // State arrives through receive(on: DispatchQueue.main). Wait for
        // the publisher rather than relying on a single Task.yield().
        try await waitUntil { model.captureState == capture.state }
        return model
    }

    private func makeSource() -> CaptureSource {
        CaptureSource(
            pid: 1234,
            audioProcessID: 42,
            bundleIdentifier: "com.example.source-readiness",
            displayName: "Test Audio"
        )
    }

    private func assertPickerGuidance(
        _ message: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let message else {
            XCTFail("Missing visible/help/spoken source-readiness reason", file: file, line: line)
            return
        }
        XCTAssertNotNil(
            message.range(of: #"\b(select|choose|pick)\b"#, options: [.regularExpression, .caseInsensitive]),
            file: file,
            line: line
        )
        XCTAssertTrue(message.lowercased().contains("source picker"), file: file, line: line)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !predicate() {
            guard Date() < deadline else {
                XCTFail("Expected state or source refresh was not delivered within one second")
                throw ReadinessWaitError.timedOut
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum ReadinessWaitError: Error {
        case timedOut
    }
}

import AVFoundation
import Capture
import Effects
import Foundation
import Graph
import ViewModel
import XCTest

/// Existing-API behavioral expectations, kept separate from the proposed
/// readiness-helper tests so root can publish this baseline independently.
final class AppErrorPresentationTests: XCTestCase {

    func test_domain_errors_use_plain_wording_and_preserve_the_reason() {
        let reason = "Could not restore the filter with identifier tnf.example."
        let cases: [(AppError, String)] = [
            (.graph(reason), "Graph error:"),
            (.parameter(reason), "Parameter error:"),
            (.preset(reason), "Preset error:"),
            (.engine(reason), "Engine error:"),
            (.persistence(reason), "Persistence error:"),
        ]

        for (error, developerPrefix) in cases {
            XCTAssertFalse(error.userMessage.hasPrefix(developerPrefix), "\(error)")
            XCTAssertTrue(error.userMessage.contains(reason), "Keep the useful failure detail: \(error)")
        }
    }

    func test_capture_errors_preserve_useful_failure_details() {
        let cases: [(AppError, String)] = [
            (.capture(.tapCreationFailed(-50)), "-50"),
            (.capture(.aggregateDeviceCreationFailed(-108)), "-108"),
            (.capture(.engineConfigurationFailed("Unsupported stereo format")), "Unsupported stereo format"),
            (.capture(.captureInterrupted(reason: "The source app quit")), "The source app quit"),
        ]

        for (error, detail) in cases {
            XCTAssertTrue(error.userMessage.contains(detail), "Keep the useful failure detail: \(error)")
        }
    }

    func test_permission_error_keeps_settings_recovery_guidance() {
        let message = AppError.capture(.permissionDenied).userMessage
        XCTAssertTrue(message.contains("System Settings"))
        XCTAssertTrue(message.contains("Privacy & Security"))
    }

    @MainActor
    func test_powerOn_without_source_directs_to_picker_without_starting_capture() async throws {
        let suiteName = "tnf.source-readiness-error.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let capture = MockCaptureController()
        let model = AppViewModel(
            capture: capture,
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )

        // This is the only powerOn call in these new tests. With no source,
        // the existing guard returns before engine preparation or start.
        await model.powerOn()

        let message = try XCTUnwrap(model.lastError).userMessage
        XCTAssertNotNil(
            message.range(of: #"\b(select|choose|pick)\b"#, options: [.regularExpression, .caseInsensitive])
        )
        XCTAssertTrue(
            message.lowercased().contains("source picker"),
            "Name the control that resolves the problem"
        )
        XCTAssertFalse(message.hasPrefix("Engine error:"))
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertNil(model.currentSource)
        XCTAssertTrue(capture.startCalls.isEmpty)
        XCTAssertEqual(capture.stopCallCount, 0)
    }
}

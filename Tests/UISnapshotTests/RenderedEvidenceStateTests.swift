import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import ViewModel
import XCTest

/// Existing-API prerequisites for the CI renderer. These tests do not render,
/// power on, or assert MenuBarExtra lifecycle or native-control visibility.
@MainActor
final class RenderedEvidenceStateTests: XCTestCase {
    func test_idle_fixture_has_isolated_defaults_and_no_running_engine() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(fixture.model.captureState, .idle)
        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.expandedEffectID)
        XCTAssertFalse(fixture.model.showSettings)
        XCTAssertFalse(fixture.model.showDebugPanel)
        XCTAssertFalse(fixture.engine.isRunning)
        XCTAssertNil(fixture.defaults.object(forKey: AppViewModelDefaultsKey.debugPanel))
    }

    func test_running_fixture_waits_for_fake_publisher_without_power_on() async throws {
        let fixture = try makeFixture()
        fixture.model.currentSource = fixture.capture.source
        fixture.capture.publish(.running(source: fixture.capture.source))
        try await waitUntil {
            fixture.model.captureState == .running(source: fixture.capture.source)
        }
        XCTAssertEqual(fixture.model.currentSource, fixture.capture.source)
        XCTAssertNil(fixture.model.lastError)
        XCTAssertFalse(fixture.engine.isRunning)
    }

    func test_multiline_banner_is_driven_by_fake_failure_not_a_private_setter() async throws {
        let fixture = try makeFixture()
        let reason = "Fake capture cannot start.\nSelect the example source and try again."
        let error = CaptureError.engineConfigurationFailed(reason)
        fixture.capture.publish(.failed(error))
        try await waitUntil {
            fixture.model.captureState == .failed(error) && fixture.model.lastError == .capture(error)
        }
        let message = try XCTUnwrap(fixture.model.lastError?.userMessage)
        XCTAssertTrue(message.contains(reason))
        XCTAssertGreaterThanOrEqual(message.components(separatedBy: "\n").count, 2)
        XCTAssertFalse(fixture.engine.isRunning)
    }

    func test_expanded_eq_keeps_the_graph_node_identity_in_the_observed_model() throws {
        let fixture = try makeFixture()
        while !fixture.model.graph.nodes.isEmpty {
            fixture.model.removeEffect(at: 0)
        }
        fixture.model.addEffect(of: "tnf.eq")
        let eq = try XCTUnwrap(fixture.model.graph.nodes.first as? EQNode)
        fixture.model.expandedEffectID = eq.id
        XCTAssertEqual(fixture.model.graph.nodes.count, 1)
        XCTAssertEqual(fixture.model.expandedEffectID, fixture.model.graph.nodes.first?.id)
        XCTAssertFalse(fixture.model.showSettings)
        XCTAssertFalse(fixture.engine.isRunning)
    }

    func test_settings_fixture_does_not_leak_into_an_independent_idle_fixture() throws {
        let settings = try makeFixture()
        settings.model.toggleSettings()
        settings.model.toggleDebugPanel()
        let idle = try makeFixture()
        XCTAssertTrue(settings.model.showSettings)
        XCTAssertTrue(settings.model.showDebugPanel)
        XCTAssertFalse(idle.model.showSettings)
        XCTAssertFalse(idle.model.showDebugPanel)
        XCTAssertNil(idle.defaults.object(forKey: AppViewModelDefaultsKey.debugPanel))
        settings.model.toggleDebugPanel()
        XCTAssertFalse(settings.model.showDebugPanel)
        XCTAssertFalse(settings.engine.isRunning)
        XCTAssertFalse(idle.engine.isRunning)
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "tnf.rendered-evidence-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let capture = RenderedEvidenceFakeCapture()
        let engine = AVAudioEngine()
        let model = AppViewModel(
            capture: capture,
            engine: engine,
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
        return Fixture(model: model, capture: capture, engine: engine, defaults: defaults)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard predicate() else {
            XCTFail("Fake capture state/error did not propagate within two seconds")
            throw FixtureError.statePropagationTimeout
        }
    }

    private struct Fixture {
        let model: AppViewModel
        let capture: RenderedEvidenceFakeCapture
        let engine: AVAudioEngine
        let defaults: UserDefaults
    }

    private enum FixtureError: Error {
        case statePropagationTimeout
    }
}

private final class RenderedEvidenceFakeCapture: CaptureControllerProtocol, @unchecked Sendable {
    let source = CaptureSource(
        pid: 1234,
        audioProcessID: 42,
        bundleIdentifier: "com.example.rendered-evidence",
        displayName: "Example Audio App"
    )
    private let subject = CurrentValueSubject<CaptureState, Never>(.idle)

    var state: CaptureState { subject.value }
    var statePublisher: AnyPublisher<CaptureState, Never> { subject.eraseToAnyPublisher() }
    var captureSourceNode: AVAudioSourceNode? { nil }

    func publish(_ state: CaptureState) { subject.send(state) }
    func availableSources() throws -> [CaptureSource] { [source] }
    func start(source: CaptureSource, into engine: AVAudioEngine) throws {
        XCTFail("Rendering fixtures must not call capture.start or model.powerOn")
        throw CaptureError.engineConfigurationFailed("Unexpected fake capture start")
    }
    func stop() throws {
        XCTFail("Rendering fixtures must not call capture.stop or model.powerOff")
    }
}

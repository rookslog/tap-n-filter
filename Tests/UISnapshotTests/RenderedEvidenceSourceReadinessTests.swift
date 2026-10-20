import Capture
import Combine
import Foundation
import XCTest
@testable import tap_n_filter_render_evidence

/// Stage A contracts for the actual exporter fixture; no view/window is created.
///
/// CI-only injection seams materialized for root's behavioral-red baseline:
/// - EvidenceFakeCapture(availableSources: @Sendable (CaptureSource) throws -> [CaptureSource])
/// - EvidenceFixture(state:capture:), retaining the existing default fake.
/// Root approved the existing test target's exporter-module dependency.
/// Readiness/validation behavior is deliberately unchanged at this checkpoint.
@MainActor
final class RenderedEvidenceSourceReadinessTests: XCTestCase {
    func test_running_state_does_not_make_fixture_ready_before_source_enumeration() async throws {
        try await assertReadinessWaitsForEnumeration(state: .running)
    }

    func test_failed_state_and_banner_do_not_make_fixture_ready_before_source_enumeration() async throws {
        try await assertReadinessWaitsForEnumeration(state: .multilineError)
    }

    func test_completed_empty_enumeration_is_rejected_by_validation_and_observation() async throws {
        let returned = expectation(description: "Fake enumeration returned no sources")
        let capture = EvidenceFakeCapture(availableSources: { _ in
            returned.fulfill()
            return []
        })
        let fixture = try EvidenceFixture(state: .running, capture: capture)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let propagated = stateExpectation(for: fixture)
        await fulfillment(of: [returned, propagated.expectation], timeout: 1)
        withExtendedLifetime(propagated.subscription) {}
        XCTAssertEqual(fixture.model.captureState, fixture.expectedState)
        XCTAssertTrue(fixture.model.availableSources.isEmpty)
        XCTAssertEqual(fixture.model.currentSource, capture.source)
        XCTAssertThrowsError(try fixture.validate(), "A picker with no matching source is not render-ready")
        XCTAssertThrowsError(try fixture.observation(), "Do not emit a selected name absent from the picker")
        XCTAssertFalse(fixture.engine.isRunning)
        XCTAssertFalse(capture.operationAttempted)
    }

    private func assertReadinessWaitsForEnumeration(state: EvidenceFixture.State) async throws {
        let entered = expectation(description: "Detached fake source enumeration entered")
        let gate = SourceEnumerationGate(entered: entered)
        let capture = EvidenceFakeCapture(availableSources: { source in try gate.enumerate(source) })
        let fixture = try EvidenceFixture(state: state, capture: capture)
        defer {
            gate.release()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }

        let propagated = stateExpectation(for: fixture)
        await fulfillment(of: [entered, propagated.expectation], timeout: 1)
        withExtendedLifetime(propagated.subscription) {}
        XCTAssertEqual(fixture.model.captureState, fixture.expectedState)
        if state == .multilineError { XCTAssertNotNil(fixture.model.lastError) }
        XCTAssertTrue(fixture.model.availableSources.isEmpty)
        XCTAssertThrowsError(try fixture.validate(), "Published capture state does not establish source readiness")
        XCTAssertThrowsError(try fixture.observation(), "Incomplete fixtures must not emit render observations")

        let premature = expectation(description: "Readiness must remain pending while enumeration is gated")
        premature.isInverted = true
        let readiness = Task { @MainActor in
            do {
                try await fixture.waitForState()
            } catch {
                if !gate.isReleased {
                    XCTFail("Readiness threw before enumeration completed instead of waiting: \(error)")
                }
                throw error
            }
            if !gate.isReleased { premature.fulfill() }
        }
        defer { readiness.cancel() }
        // Only this bounded pending assertion uses elapsed time. Source delivery
        // itself is controlled by the gate, never by a guessed refresh delay.
        await fulfillment(of: [premature], timeout: 0.1)
        gate.release()
        try await readiness.value

        XCTAssertTrue(fixture.model.availableSources.contains { $0.pid == capture.source.pid })
        XCTAssertTrue(fixture.model.availableSources.contains(capture.source))
        XCTAssertEqual(fixture.model.currentSource, capture.source)
        XCTAssertNoThrow(try fixture.validate())
        let observed = try fixture.observation()
        XCTAssertEqual(observed.sourceDisplayName.value, capture.source.displayName)
        XCTAssertEqual(observed.captureState, state == .running ? "running" : "failed")
        XCTAssertFalse(observed.engineRunning)
        XCTAssertFalse(fixture.engine.isRunning)
        XCTAssertFalse(capture.operationAttempted)
    }

    private func stateExpectation(
        for fixture: EvidenceFixture
    ) -> (expectation: XCTestExpectation, subscription: AnyCancellable) {
        let arrived = expectation(description: "Desired capture state and error propagated")
        let subscription = fixture.model.$captureState
            .combineLatest(fixture.model.$lastError)
            .filter { state, error in
                state == fixture.expectedState && (fixture.state != .multilineError || error != nil)
            }
            .prefix(1)
            .sink { _ in arrived.fulfill() }
        return (arrived, subscription)
    }
}

/// Blocks only the model's detached enumeration worker, never the main actor.
/// A bounded condition wait and deferred release prevent a leaked test worker.
private final class SourceEnumerationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: XCTestExpectation
    private var released = false
    private var announced = false

    init(entered: XCTestExpectation) { self.entered = entered }

    var isReleased: Bool {
        condition.lock()
        defer { condition.unlock() }
        return released
    }

    func enumerate(_ source: CaptureSource) throws -> [CaptureSource] {
        condition.lock()
        defer { condition.unlock() }
        if !announced {
            announced = true
            entered.fulfill()
        }
        let deadline = Date(timeIntervalSinceNow: 3)
        while !released {
            guard condition.wait(until: deadline) || released else {
                throw GateError.releaseDeadlineExceeded
            }
        }
        return [source]
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private enum GateError: Error {
        case releaseDeadlineExceeded
    }
}

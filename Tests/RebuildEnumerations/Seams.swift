// The one place the checks touch the app's inert test hooks. Outcome and state values are matched
// by their description, so a renamed case shows up as a divergence, never as a silent refusal.

import Foundation
import SoundModel
@testable import EverydayMenu
import PlaybackRuntime
@testable import PlaybackOutput
@testable import tap_n_filter

enum Seams {
    // MARK: Admission receipt: synchronous inside send at the decision; .failed later from the apply task
    @MainActor static func observeAdmissions(_ app: LibraryAppSession, _ record: @escaping @MainActor (EverydayMenuAction, AOutcome) -> Void) {
        app.admissionDecided = { action, outcome in record(action, Seams.outcome(outcome)) }
    }
    @MainActor static func stopObservingAdmissions(_ app: LibraryAppSession) { app.admissionDecided = nil }
    static func outcome(_ value: Any) -> AOutcome {
        switch String(describing: value) {
        case let s where s.hasPrefix("admitted"): return .admitted
        case let s where s.hasPrefix("failed"): return .failed
        case let s where s.hasPrefix("superseded"): return .superseded
        default: return .none     // an unknown receipt name shows up as a divergence, never as a silent refusal
        }
    }

    // MARK: Publication gate (not used: reads are held before they are taken, by task-local tag; see Fixture)

    // MARK: Coordinator and session quiescence
    /// Only valid when nothing is held: a held write, read, editor operation or debounce keeps it waiting.
    @MainActor static func sessionQuiescent(_ app: LibraryAppSession) async { await app.quiescent() }

    // MARK: Lane condition injection
    @MainActor static func sourceGone(_ controller: PlaybackController, assignment: UUID) {
        controller.injectConditionForTesting(assignment, .sourceDisappeared)
    }

    // MARK: Playback change with its cause
    /// A lane finishing a start or stop: not a barrier (A-LC).
    @MainActor static func lanePublished(_ coordinator: LibraryListeningCoordinator) { coordinator.playbackDidChange(.lane) }
    /// Source or format change: a real barrier (A-SEM).
    @MainActor static func sourceOrFormatChanged(_ coordinator: LibraryListeningCoordinator) { coordinator.playbackDidChange(.sourceOrFormat) }
    /// The App wiring: controller changes are lane publications, invalidations are source or format changes.
    @MainActor static func wireApp(_ controller: PlaybackController, to coordinator: LibraryListeningCoordinator) {
        controller.changed = { coordinator.playbackDidChange(.lane) }
        controller.sourceOrFormatChanged = { coordinator.playbackDidChange(.sourceOrFormat) }
    }

    // MARK: Apply-failure injection on the live parameter path
    /// One failure, shared with the fixture's ordered-route injection: whichever route the next admitted change
    /// takes consumes it. `applyFailureForTesting` covers the fast parameter path; `moveFailureForTesting` covers
    /// `executeMove` (identity-less moves, editor rows).
    @MainActor static func failNextApply(_ coordinator: LibraryListeningCoordinator, _ next: FailNext) {
        next.armed = true
        coordinator.applyFailureForTesting = { try next.fire() }
        coordinator.moveFailureForTesting = { try next.fire() }
    }
    @MainActor static func disarmApplyFailure(_ coordinator: LibraryListeningCoordinator, _ next: FailNext) {
        next.armed = false
        coordinator.applyFailureForTesting = nil; coordinator.moveFailureForTesting = nil
    }

    // MARK: Hold "stop completes" at the controller's own stop step
    @MainActor static func holdStops(_ controller: PlaybackController, _ step: @escaping @MainActor (UUID) async -> Void) {
        controller.beforeStopCompletesForTesting = { id in await step(id) }
    }

    // MARK: Controller quiescence (waits for held starts and stops, so only when none is held)
    @MainActor static func controllerQuiescent(_ controller: PlaybackController) async { await controller.quiescent() }

    // MARK: Lane state readback ("stopping+restart" is the model's stopping with a restart authorized)
    @MainActor static func laneState(_ controller: PlaybackController, _ assignment: UUID) -> LaneState? {
        guard let text = controller.laneStateForTesting(assignment) else { return nil }
        return LaneState(rawValue: String(text.prefix { $0 != "+" }))
    }
}

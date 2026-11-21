@testable import tap_n_filter

// Problems clear, and a failed start quits cleanly: behaviour checks.
// The only file that names the product code these checks reach. If those names change,
// change this file and nothing else. Names below follow the product code as read
// on 2026-11-20; the seams are internal accessors on the session
// 

/// The quit outcome the cases expect, independent of the product's own type.
enum UnitAQuit: Equatable { case terminate, confirmUnsaved }

/// Seam 1: `LibraryAppSession.receive(_:)`, made internal, body otherwise as the unit changes it.
@MainActor func unitAReceive(_ app: LibraryAppSession, _ event: LibraryConsumerEvent) {
    app.receive(event)
}

/// Seam 2a: what `App.showProblem()` asks for when it builds the alert (the library text it shows).
@MainActor func unitAPresent(_ app: LibraryAppSession) -> String? {
    app.presentProblem()
}

/// Seam 2b: what `App.showProblem()` calls once `runModal()` returns, whichever button.
@MainActor func unitADismiss(_ app: LibraryAppSession) {
    app.problemDismissed()
}

/// Seam 3: the pure quit decision `requestTermination()` uses instead of its inline switch.
@MainActor func unitAQuit(after result: LibraryDrainResult) -> UnitAQuit {
    LibraryAppSession.drainNeedsDecision(result) ? .confirmUnsaved : .terminate
}

/// Text the source check requires inside App.swift's `requestTermination()` and `showProblem()`.
let unitAQuitDecisionCall = "drainNeedsDecision("
let unitAPresentCall = "presentProblem("
let unitADismissCall = "problemDismissed("

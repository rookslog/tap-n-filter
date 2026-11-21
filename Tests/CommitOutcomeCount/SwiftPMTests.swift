import XCTest

/// Diagnostic only, run by a dedicated CI step. Skipped unless COMMIT_OUTCOME_COUNT=1, so the ordinary test step
/// does not play the enumeration. COMMIT_OUTCOME_LENGTH sets the sequence length (default 3).
final class CommitOutcomeCountTests: XCTestCase {
    func test_drag_commit_outcomes_without_a_fault() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["COMMIT_OUTCOME_COUNT"] != "1", "Diagnostic count; set COMMIT_OUTCOME_COUNT=1 to run")
        let length = Int(environment["COMMIT_OUTCOME_LENGTH"] ?? "") ?? 3
        try await CommitOutcomeCount.runAll(length: length)
    }
}

import WaitingStateCheckCore
import XCTest

/// Runs every waiting-state case under `swift test`. A case that fails fails this test, with the list of
/// failed case ids and each failure's line. Pending cases are listed in the log and do not run.
final class WaitingStateTests: XCTestCase {
  @MainActor func test_waiting_state_cases() async {
    let report = await WaitingStateChecks.run(includePending: false, watchdogSeconds: 300)
    if !report.pending.isEmpty { print("waiting-state pending cases (not run): \(report.pending.joined(separator: ", "))") }
    XCTAssertFalse(report.passed.isEmpty, "no waiting-state case ran")
    if !report.failed.isEmpty {
      let details = report.lines.filter { $0.hasPrefix("FAIL case ") }.joined(separator: "\n")
      XCTFail("waiting-state cases failed: \(report.failed.joined(separator: ", "))\n\(details)")
    }
  }
}

// tnf-waiting-check: runs the waiting-state cases without XCTest.
//
//   swift run tnf-waiting-check              every case; pending cases are listed, not run
//   swift run tnf-waiting-check --pending    also runs the pending cases and reports them,
//                                            without letting them change the exit code
//   swift run tnf-waiting-check --only 4,7   run only these case ids
//
// Exit code: 0 when every non-pending case passed, 1 when any failed, 2 when the watchdog fired.

import Foundation
import WaitingStateCheckCore

@main struct WaitingCheck {
  @MainActor static func main() async {
    let arguments = CommandLine.arguments
    var only: Set<String>?
    if let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count {
      only = Set(arguments[index + 1].split(separator: ",").map(String.init))
    }
    let report = await WaitingStateChecks.run(includePending: arguments.contains("--pending"), only: only)
    exit(report.failed.isEmpty ? 0 : 1)
  }
}

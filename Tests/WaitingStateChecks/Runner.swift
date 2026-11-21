// The waiting-state cases, run in order. Fakes only; no hardware, app launch, window or sound.
// Used by the `tnf-waiting-check` executable and by the `WaitingStateTests` XCTest target.
//
// One line per case:
//   PASS case <id>: <title>
//   FAIL case <id>: <title>: <what was observed>
//   PENDING case <id>: <title> (not built yet, not run)
//   PENDING-PASS / PENDING-FAIL case <id>: ...   (only when pending cases are asked for)
// and a last line, "PASS waiting-state checks; ..." or "FAIL waiting-state cases: <ids>".

import Foundation

private struct Case {
  let id: String
  let title: String
  let pending: Bool
  let body: @MainActor () async throws -> Void
}

@MainActor private let cases: [Case] = [
  Case(id: "1", title: "start with the app absent: waiting, no problem", pending: false) { try await Cases.case1() },
  Case(id: "2", title: "process appears, list changes: runs, one start", pending: false) { try await Cases.case2() },
  Case(id: "3", title: "quit while running ends waiting; relaunch runs new pid", pending: true) { try await Cases.case3() },
  Case(id: "4", title: "launch with no audio: five attempts at 0.5,1,2,4,8 s, then none", pending: false) { try await Cases.case4() },
  Case(id: "4c", title: "burst cancels its remaining steps at once on success", pending: false) { try await Cases.case4c() },
  Case(id: "5", title: "menu open: one attempt per waiting lane only", pending: false) { try await Cases.case5() },
  Case(id: "6", title: "nothing waiting: list change reads nothing, no timer", pending: false) { try await Cases.case6() },
  Case(id: "7", title: "twenty list changes inside 250 ms: one attempt", pending: false) { try await Cases.case7() },
  Case(id: "8", title: "vanish at revalidation mid-start: waiting, nothing stranded", pending: false) { try await Cases.case8() },
  Case(id: "8c", title: "quit while starting (termination path) ends waiting", pending: true) { try await Cases.case8c() },
  Case(id: "9", title: "two (or >8) audio processes: still the existing problem", pending: false) { try await Cases.case9() },
  Case(id: "10", title: "compare ignores waiting lanes only", pending: false) { try await Cases.case10() },
  Case(id: "11", title: "switch off while waiting: idle, no later attempts", pending: false) { try await Cases.case11() },
  Case(id: "12", title: "icon: grey after 0.6 s not running, colour at once", pending: false) { try Cases.case12() },
  Case(id: "13", title: "running cards keep today's presentation values", pending: false) { try await Cases.case13() },
  Case(id: "14", title: "accessibility value: waiting card says \"not playing\"", pending: false) { try await Cases.case14() },
  Case(id: "15", title: "a wake-up during an attempt makes exactly one more attempt", pending: false) { try await Cases.case15() },
  Case(id: "16", title: "replaced at revalidation: waiting, launch burst", pending: false) { try await Cases.case16() },
]

public enum WaitingStateChecks {
  public struct Report: Sendable {
    public let passed: [String]
    /// Ids of non-pending cases that failed. Pending cases never appear here.
    public let failed: [String]
    public let pending: [String]
    public let lines: [String]
  }

  /// Runs every case (or only `only`). Pending cases are listed and, unless `includePending`, not run.
  /// A watchdog turns a case that waits forever into a reported failure and exit code 2, not a hang.
  @MainActor public static func run(
    includePending: Bool = false, only: Set<String>? = nil, watchdogSeconds: Double = 120
  ) async -> Report {
    let watchdog = Watchdog(seconds: watchdogSeconds)
    defer { watchdog.cancel() }
    var passed: [String] = [], failed: [String] = [], pending: [String] = [], lines: [String] = []
    func say(_ line: String) { print(line); lines.append(line) }
    for item in cases where only?.contains(item.id) ?? true {
      if item.pending { pending.append(item.id) }
      if item.pending && !includePending {
        say("PENDING case \(item.id): \(item.title) (not built yet, not run)")
        continue
      }
      do {
        try await item.body()
        say("\(item.pending ? "PENDING-PASS" : "PASS") case \(item.id): \(item.title)")
        if !item.pending { passed.append(item.id) }
      } catch {
        say("\(item.pending ? "PENDING-FAIL" : "FAIL") case \(item.id): \(item.title): \(error)")
        if !item.pending { failed.append(item.id) }
      }
    }
    if failed.isEmpty {
      say("PASS waiting-state checks; fakes only, no hardware, app windows or audio")
    } else {
      say("FAIL waiting-state cases: \(failed.joined(separator: ", "))")
    }
    return Report(passed: passed, failed: failed, pending: pending, lines: lines)
  }
}

/// Exits the process with code 2 if the run has not finished in time.
private final class Watchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  init(seconds: Double) {
    Thread.detachNewThread { [self] in
      Thread.sleep(forTimeInterval: seconds)
      lock.lock(); let stop = !cancelled; lock.unlock()
      guard stop else { return }
      print("FAIL watchdog: the waiting-state run did not finish in \(Int(seconds)) s (a case is awaiting something that never happened)")
      exit(2)
    }
  }
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

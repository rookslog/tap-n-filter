// tnf-waiting-check: the waiting-state checks . Fakes only; no hardware, app launch, window or sound.
//
//   swift run tnf-waiting-check              cases; pending cases are listed, not run
//   swift run tnf-waiting-check --pending    also runs the pending cases and reports them,
//                                            without letting them change the exit code
//   swift run tnf-waiting-check --only 4,7   run only these case ids
//
// Exit code: 0 when every non-pending case passed, 1 when any failed, 2 when the watchdog fired.

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

@main struct WaitingCheck {
  @MainActor static func main() async {
    let arguments = CommandLine.arguments
    let runPending = arguments.contains("--pending")
    var only: Set<String>?
    if let index = arguments.firstIndex(of: "--only"), index + 1 < arguments.count {
      only = Set(arguments[index + 1].split(separator: ",").map(String.init))
    }
    // A missing wake-up must fail the run, not hang it.
    Thread.detachNewThread {
      Thread.sleep(forTimeInterval: 120)
      print("FAIL watchdog: the run did not finish in 120 s (a case is awaiting something that never happened)")
      exit(2)
    }
    var failed: [String] = []
    for item in cases where only?.contains(item.id) ?? true {
      if item.pending && !runPending {
        print("PENDING case \(item.id): \(item.title) (not built yet, not run)")
        continue
      }
      do {
        try await item.body()
        print("\(item.pending ? "PENDING-PASS" : "PASS") case \(item.id): \(item.title)")
      } catch {
        print("\(item.pending ? "PENDING-FAIL" : "FAIL") case \(item.id): \(item.title): \(error)")
        if !item.pending { failed.append(item.id) }
      }
    }
    if failed.isEmpty {
      print("PASS waiting-state checks; fakes only, no hardware, app windows or audio")
      exit(0)
    }
    print("FAIL waiting-state cases: \(failed.joined(separator: ", "))")
    exit(1)
  }
}

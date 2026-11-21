// The waiting-state cases: an assigned app that is not playing yet waits quietly and starts by itself.
// Each case asserts what a person or the audio path would notice: lane state,
// whether TNF reports a problem, how many resolve attempts and starts happened and when, whether
// "Hold to hear original" is available, and the card icon's value over time.
//
// "Attempt" = one source resolution (`.resolving` from the runtime). "Start" = one capture start.

import Foundation
import PlaybackRuntime

private let A = "test.A", B = "test.B", C = "test.C", D = "test.D"

@MainActor private func toneIs(_ icon: Product.Icon, _ saturation: Double, _ opacity: Double) -> Bool {
  let tone = Product.iconTone(icon)
  return abs(tone.saturation - saturation) < 0.001 && abs(tone.opacity - opacity) < 0.001
}

@MainActor
enum Cases {
  // 1. Start with the app absent: lane waiting, `problem` nil, no attention row.
  static func case1() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    try demand(rig.state(A) == Product.waitingState, "absent app at start is waiting: \(rig.describe(A))")
    try demand(rig.problem == nil, "waiting is not a problem (the attention row is driven by problem): \(rig.describe(A))")
    try demand(rig.activity(A) == .waiting, "card activity is waiting: \(rig.describe(A))")
    let base = rig.attempts(A)  // the first attempt, and the one look after subscribing (case 18 counts it)
    try demand(base >= 1 && rig.captureStarts(A) == 0, "attempted, no capture: \(rig.describe(A))")
    try demand(rig.nothingStranded(A), "no lease or tap held while waiting: \(rig.describe(A))")
    try demand(rig.events.listListenerInstalled, "the process-list wake-up is listening while a lane waits")
    // No polling: with no event, a minute passes and nothing is tried.
    await rig.advance(to: 60)
    try demand(rig.attempts(A) == base && rig.clock.pending == 0, "no attempt or timer without a wake-up: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 2. The process appears and the list changes: the lane runs; exactly one start.
  static func case2() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    let base = rig.attempts(A)
    rig.world.appear(A, pids: [101])
    await rig.listChanged()
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.activity(A) == .running, "list change starts the waiting lane: \(rig.describe(A))")
    try demand(rig.problem == nil, "no problem once running: \(rig.describe(A))")
    try demand(rig.attempts(A) == base + 1 && rig.captureStarts(A) == 1, "exactly one start after one list change: \(rig.describe(A))")
    try demand(rig.trace.resolvedPIDs[A]?.last == 101, "the lane runs the process that appeared")
    // A running lane is not tried again by later list changes.
    for _ in 0..<3 { await rig.listChanged(); await rig.advance(by: 1) }
    try demand(rig.attempts(A) == base + 1 && rig.captureStarts(A) == 1, "running lane is not re-attempted: \(rig.describe(A))")
    try demand(rig.clock.pending == 0, "no scheduled work once nothing waits: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 3. PENDING (not built yet). Quit while running: teardown completes, lane waiting, no failure text;
  //    relaunch: runs with the new pid.
  static func case3() async throws {
    let rig = Rig()
    rig.world.appear(A, pids: [101])
    await rig.apply([(A, true)])
    try demand(rig.state(A) == "running", "setup: running: \(rig.describe(A))")
    rig.world.vanish(A)
    rig.sourceQuit(A)  // the termination path's entry
    await rig.settle()
    try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "quit while running ends waiting, no text: \(rig.describe(A))")
    try demand(rig.nothingStranded(A), "teardown completed, lease released: \(rig.describe(A))")
    rig.world.appear(A, pids: [202])
    await rig.listChanged()
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.trace.resolvedPIDs[A]?.last == 202, "relaunch runs with the new pid: \(rig.describe(A))")
    try demand(rig.captureStarts(A) == 2, "one start per launch: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 4. Launch with no audio process: exactly five attempts at the stated times, then none.
  static func case4() async throws {
    try demand(sameTimes(Product.productLaunchBurst, [0.5, 1, 2, 4, 8]), "product burst is 0.5, 1, 2, 4, 8 s: \(Product.productLaunchBurst)")
    // 4a: the app launches and never gets an audio process.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])
      await rig.advance(to: 10)
      await rig.launched(A)  // launch at t = 10
      await rig.advance(to: 40)
      let burst = rig.attemptTimes(A).filter { $0 > 10.0001 }.map { $0 - 10 }
      try demand(sameTimes(Array(burst), [0.5, 1, 2, 4, 8]), "five attempts at 0.5, 1, 2, 4, 8 s after launch: \(rig.describe(A))")
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "still waiting, quietly, after the burst: \(rig.describe(A))")
      try demand(rig.clock.pending == 0, "nothing scheduled after the burst: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 4b: the audio process appears 1.5 s after launch; the burst stops at its first success (2 s).
    do {
      let rig = Rig()
      await rig.apply([(A, true)])
      await rig.launched(A)
      await rig.advance(to: 1.5)
      rig.world.appear(A, pids: [101])
      await rig.advance(to: 2)
      try demand(rig.state(A) == "running", "burst attempt at 2 s starts the lane: \(rig.describe(A))")
      await rig.advance(to: 30)
      try demand(sameTimes(rig.attemptTimes(A).filter { $0 > 0.0001 }, [0.5, 1, 2]) && rig.captureStarts(A) == 1, "burst stops at first success: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 4d: a launch of an unrelated app, or of an app whose lane is running, starts no burst.
    do {
      let rig = Rig()
      rig.world.appear(B, pids: [202])
      await rig.apply([(A, true), (B, true)])
      let baseA = rig.attempts(A)
      await rig.launched("test.unrelated")
      await rig.launched(B)
      try demand(rig.clock.pending == 0, "no burst for an unrelated or running app: \(rig.describe(A)) \(rig.describe(B))")
      await rig.advance(to: 30)
      try demand(rig.attempts(A) == baseA && rig.attempts(B) == 1, "no attempts from unrelated launches: \(rig.describe(A)) \(rig.describe(B))")
      await rig.shutdown()
    }
  }

  // 4c. Nothing runs when nothing is waiting: once a burst has succeeded, none of its later steps is
  //     left scheduled.
  static func case4c() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    await rig.launched(A)
    await rig.advance(to: 1.5)
    rig.world.appear(A, pids: [101])
    await rig.advance(to: 2)
    try demand(rig.state(A) == "running", "setup: burst attempt at 2 s starts the lane: \(rig.describe(A))")
    try demand(rig.clock.pending == 0, "no burst steps left scheduled once the lane runs: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 5. Menu open: one attempt per waiting lane, at once (no time passes), none for running or off lanes,
  //    and nothing later.
  static func case5() async throws {
    let rig = Rig()
    rig.world.appear(C, pids: [303])
    await rig.advance(to: 2)
    await rig.apply([(A, true), (B, true), (C, true), (D, false)])
    try demand(rig.state(A) == Product.waitingState && rig.state(B) == Product.waitingState && rig.state(C) == "running", "setup: A, B waiting, C running: \(rig.describe(A)) \(rig.describe(C))")
    try demand(rig.clock.pending == 0, "setup: nothing scheduled before the menu opens: \(rig.clock.pendingDue)")
    await rig.advance(to: 3)
    let before = [A, B, C, D].map { rig.attempts($0) }
    await rig.menuOpened()  // at t = 3; the clock does not move
    let after = [A, B, C, D].map { rig.attempts($0) }
    try demand(zip(after, before).map { $0 - $1 } == [1, 1, 0, 0], "menu open: one attempt per waiting lane at once, none for running or off: before \(before) after \(after)")
    try demand(sameTimes(rig.attemptTimes(A).filter { $0 > 2.0001 }, [3]) && sameTimes(rig.attemptTimes(B).filter { $0 > 2.0001 }, [3]),
      "the attempts happen when the menu opens: \(rig.describe(A)) | \(rig.describe(B))")
    try demand(rig.clock.pending == 0, "a menu open schedules nothing: \(rig.clock.pendingDue)")
    await rig.advance(by: 30)
    let later = [A, B, C, D].map { rig.attempts($0) }
    try demand(later == after, "no attempt follows later: \(after) -> \(later)")
    try demand(rig.problem == nil, "menu-open attempts that find nothing stay quiet: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 6. Nothing waiting: a list change causes zero resolver calls; no timer exists.
  static func case6() async throws {
    let rig = Rig()
    rig.world.appear(A, pids: [101])
    await rig.apply([(A, true), (B, false)])
    let reads = rig.world.reads
    for _ in 0..<5 { rig.events.processListChanged() }
    try demand(rig.clock.pending == 0, "a list change schedules nothing when nothing waits: \(rig.describe(A))")
    await rig.settle()
    await rig.advance(to: 5)
    try demand(rig.world.reads == reads && rig.attempts(A) == 1 && rig.attempts(B) == 0, "zero resolver calls: reads \(reads) -> \(rig.world.reads)")
    try demand(rig.clock.pending == 0, "no timer exists: \(rig.describe(A))")
    await rig.shutdown()
    // With no assignments at all.
    let empty = Rig()
    await empty.apply([])
    empty.events.processListChanged()
    empty.events.launched(A)
    await empty.settle()
    try demand(empty.clock.pending == 0 && empty.world.reads.isEmpty, "empty library: nothing scheduled, nothing read")
    await empty.shutdown()
    // 6c: listener balance. Each time a lane stops waiting, no list listener is left registered and every
    //     registration made was removed exactly once (a leaked listener fails here).
    let bal = Rig()
    await bal.apply([(A, true)])  // waiting: one registration
    try demand(bal.events.activeListListeners == 1, "6c: one listener while waiting: adds \(bal.events.listInstalls) removals \(bal.events.removalsPerRegistration)")
    await bal.apply([(A, false)])  // switched off
    try demand(bal.events.activeListListeners == 0 && bal.events.removalsPerRegistration.allSatisfy { $0 == 1 },
      "6c: off leaves no listener, each removed once: removals \(bal.events.removalsPerRegistration)")
    await bal.apply([(A, true)])  // waiting again: a new registration
    bal.world.appear(A, pids: [101])
    await bal.listChanged()
    await bal.advance(by: 1)  // running
    try demand(bal.state(A) == "running", "6c: setup: running: \(bal.describe(A))")
    try demand(bal.events.activeListListeners == 0 && bal.events.listInstalls == 2
      && bal.events.removalsPerRegistration == [1, 1],
      "6c: running leaves no listener, two registrations each removed once: adds \(bal.events.listInstalls) removals \(bal.events.removalsPerRegistration)")
    await bal.shutdown()
    try demand(bal.events.removalsPerRegistration == [1, 1], "6c: shutdown removes nothing twice: \(bal.events.removalsPerRegistration)")
  }

  // 7. Twenty list changes inside 250 ms: one attempt.
  static func case7() async throws {
    try demand(abs(Product.productFoldWindow - 0.25) < 0.001, "product fold window is 250 ms: \(Product.productFoldWindow)")
    let rig = Rig()
    await rig.apply([(A, true)])  // the first attempt (and any look after subscribing) at t = 0
    let base = rig.attempts(A)
    for i in 0..<20 {
      await rig.advance(to: 1 + Double(i) * 0.01)  // changes at 1.00 ... 1.19 s
      await rig.listChanged()
    }
    await rig.advance(to: 3)
    try demand(rig.attempts(A) == base + 1, "twenty changes inside 250 ms make one attempt: \(rig.describe(A))")
    // The fold ends: a change well after it makes its own attempt.
    await rig.listChanged()
    await rig.advance(to: 5)
    try demand(rig.attempts(A) == base + 2, "a later change makes a new attempt: \(rig.describe(A))")
    try demand(rig.problem == nil && rig.clock.pending == 0, "quiet, nothing left scheduled: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 8. Process appears then vanishes mid-start: back to waiting, no failure text, no stranded lease or tap.
  static func case8() async throws {
    // 8a: gone at the revalidation before prepare (lease held, no tap yet).
    // 8b: gone at the revalidation before start (lease held, tap prepared).
    for (label, reads) in [("8a before prepare", 1), ("8b before start", 2)] {
      let rig = Rig()
      rig.world.queue[A] = Array(repeating: [rig.world.candidate(A, pid: 101)], count: reads) + [[]]
      await rig.apply([(A, true)])
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "\(label): vanished mid-start is waiting, no text: \(rig.describe(A))")
      try demand(rig.nothingStranded(A) && rig.captureStarts(A) == 0 && (rig.trace.outputStarts[A] ?? 0) == 0, "\(label): no stranded lease or tap, nothing started: \(rig.describe(A))")
      if reads == 2 { try demand((rig.trace.prepared[A] ?? 0) == 1, "\(label): the tap was prepared before the vanish (setup check): \(rig.describe(A))") }
      // It is really waiting: the next appearance starts it.
      rig.world.appear(A, pids: [102])
      await rig.listChanged()
      await rig.advance(by: 1)
      try demand(rig.state(A) == "running" && rig.trace.resolvedPIDs[A]?.last == 102, "\(label): next appearance runs: \(rig.describe(A))")
      await rig.shutdown()
    }
  }

  // 8c. PENDING (not built yet). The app quits while its lane is starting (the termination path, not revalidation).
  static func case8c() async throws {
    let rig = Rig()
    rig.world.appear(A, pids: [101])
    rig.trace.holdPrepare.insert(A)
    rig.applyWithoutSettling([(A, true)])
    await rig.trace.prepareGate.entered()
    rig.world.vanish(A)
    rig.sourceQuit(A)
    rig.trace.prepareGate.release()
    await rig.settle()
    try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "quit during start ends waiting, no text: \(rig.describe(A))")
    try demand(rig.nothingStranded(A) && rig.captureStarts(A) == 0, "no stranded lease or tap: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 9. Two audio processes for the bundle: still the existing problem, not waiting.
  static func case9() async throws {
    let rig = Rig()
    rig.world.appear(A, pids: [101, 102])
    await rig.apply([(A, true)])
    try demand(rig.state(A) == "failed" && rig.activity(A) != .waiting, "two processes is a failure, not waiting: \(rig.describe(A))")
    try demand(rig.problem == "More than one audio process matches this app.", "existing problem text unchanged: \(rig.describe(A))")
    // Wake-ups are for waiting lanes only; a failed lane waits for Try Again.
    await rig.listChanged(); await rig.advance(by: 1); await rig.menuOpened(); await rig.advance(by: 1)
    try demand(rig.attempts(A) == 1 && rig.state(A) == "failed", "no wake attempts for a failed lane: \(rig.describe(A))")
    await rig.shutdown()
    // 9b: more than eight is also still a problem.
    let many = Rig()
    many.world.appear(A, pids: Array(101...109))
    await many.apply([(A, true)])
    try demand(many.state(A) == "failed" && many.problem != nil, "more than eight processes is still a problem: \(many.describe(A))")
    await many.shutdown()
  }

  // 10. Compare: one lane running and one waiting, compare is available; none running, it is not.
  static func case10() async throws {
    let mixed = Rig()
    mixed.world.appear(A, pids: [101])
    await mixed.apply([(A, true), (B, true)])
    try demand(mixed.state(A) == "running" && mixed.state(B) == Product.waitingState, "setup: A running, B waiting: \(mixed.describe(A)) \(mixed.describe(B))")
    try demand(mixed.compare, "one running and one waiting: compare available")
    await mixed.shutdown()
    let none = Rig()
    await none.apply([(A, true), (B, true)])
    try demand(!none.compare, "none running: compare not available: \(none.describe(A))")
    await none.shutdown()
    // Only waiting lanes are left out; a lane that failed still blocks compare, as today.
    let failed = Rig()
    failed.world.appear(A, pids: [101])
    failed.world.appear(B, pids: [201, 202])
    await failed.apply([(A, true), (B, true)])
    try demand(failed.state(B) == "failed" && !failed.compare, "a failed lane still blocks compare: \(failed.describe(B))")
    await failed.shutdown()
    // All apps off: not available.
    let off = Rig()
    off.world.appear(A, pids: [101])
    await off.apply(power: false, [(A, true), (B, true)])
    try demand(!off.compare, "All apps off: compare not available")
    await off.shutdown()
  }

  // 11. Switch off while waiting: idle; a later list change causes no attempt.
  static func case11() async throws {
    // 11a full delivery, 11b positions-only delivery, 11c All apps off.
    for label in ["11a card off (full)", "11b card off (positions)", "11c All apps off"] {
      let rig = Rig()
      await rig.apply([(A, true)])
      let base = rig.attempts(A)
      if label.hasPrefix("11a") { await rig.apply([(A, false)]) }
      else if label.hasPrefix("11b") { await rig.positions([(A, false)]) }
      else { await rig.apply(power: false, [(A, true)]) }
      try demand(rig.state(A) == "idle" && rig.problem == nil, "\(label): off while waiting is idle: \(rig.describe(A))")
      try demand(rig.activity(A) != .waiting, "\(label): card no longer waiting: \(rig.describe(A))")
      rig.world.appear(A, pids: [101])
      await rig.listChanged(); await rig.launched(A); await rig.menuOpened()
      await rig.advance(by: 30)
      try demand(rig.attempts(A) == base && rig.captureStarts(A) == 0, "\(label): no attempt after off: \(rig.describe(A))")
      try demand(rig.clock.pending == 0, "\(label): nothing scheduled: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 11d: off in the middle of a launch burst cancels the rest of it.
    let rig = Rig()
    await rig.apply([(A, true)])
    await rig.launched(A)
    await rig.advance(to: 1.5)  // burst attempts at 0.5 and 1 made
    await rig.apply([(A, false)])
    await rig.advance(to: 30)
    try demand(sameTimes(rig.attemptTimes(A).filter { $0 > 0.0001 }, [0.5, 1]) && rig.clock.pending == 0, "11d: off mid-burst cancels the rest: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 12. Icon: grey only after 0.6 s not running; colour at once on running; unchanged for an off card.
  static func case12() throws {
    try demand(abs(Product.iconDelay - 0.6) < 0.001 && abs(Product.iconFade - 0.2) < 0.001, "icon delay 0.6 s and fade 0.2 s: \(Product.iconDelay), \(Product.iconFade)")
    var icon = Product.makeIcon(on: true, running: true)
    try demand(Product.isColoured(icon), "on and running: colour")
    // The lane stops running at t = 10.
    var timeline: [(TimeInterval, Bool)] = []
    for t in [10.0, 10.3, 10.59, 10.61, 11.0] {
      Product.updateIcon(&icon, on: true, running: false, now: t)
      timeline.append((t, Product.isColoured(icon)))
    }
    try demand(timeline.map { $0.1 } == [true, true, true, false, false], "grey only after 0.6 s not running: \(timeline)")
    Product.updateIcon(&icon, on: true, running: true, now: 11.01)
    try demand(Product.isColoured(icon), "colour at once when the lane runs")
    // A short stop (route change, restart) does not blink it, and the 0.6 s restarts from the next stop.
    for (t, running) in [(20.0, false), (20.4, false), (20.45, true), (21.0, false), (21.5, false)] {
      Product.updateIcon(&icon, on: true, running: running, now: t)
      try demand(Product.isColoured(icon), "no blink during a short stop, t=\(t)")
    }
    Product.updateIcon(&icon, on: true, running: false, now: 21.61)
    try demand(!Product.isColoured(icon), "grey 0.6 s after the second stop began")
    // Off card: grey, as today, whatever the lane does, and at once.
    for running in [true, false, nil] as [Bool?] {
      var off = Product.makeIcon(on: false, running: running)
      try demand(!Product.isColoured(off), "off card is grey (running=\(String(describing: running)))")
      Product.updateIcon(&off, on: false, running: running, now: 1)
      try demand(!Product.isColoured(off), "off card stays grey (running=\(String(describing: running)))")
    }
    var turnedOff = Product.makeIcon(on: true, running: true)
    Product.updateIcon(&turnedOff, on: false, running: true, now: 5)
    try demand(!Product.isColoured(turnedOff), "switching a card off greys it at once, as today")
  }

  // 13. Everyday and Filters cards for running apps look as today, held at the presentation values.
  static func case13() async throws {
    // Today: `.saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)` (MenuCardViews.swift, MenuCardHeader).
    let running = Product.makeIcon(on: true, running: true)
    let unknown = Product.makeIcon(on: true, running: nil)
    let off = Product.makeIcon(on: false, running: false)
    try demand(toneIs(running, 1, 1), "running card icon: saturation 1, opacity 1, as today's on card: \(Product.iconTone(running))")
    try demand(toneIs(unknown, 1, 1), "on card with no lane information: as today: \(Product.iconTone(unknown))")
    try demand(toneIs(off, 0, 0.5), "off card icon: saturation 0, opacity 0.5, as today: \(Product.iconTone(off))")
    try demand(Product.accessibilityValueRunning == nil, "a running card's name gets no accessibility value (no new words)")
    // The controller reports both a running Everyday card and a running Filters card as running.
    let rig = Rig()
    rig.world.appear(A, pids: [101]); rig.world.appear(B, pids: [201])
    await rig.apply([(A, true), (B, true)])
    try demand(rig.activity(A) == .running && rig.activity(B) == .running && rig.problem == nil, "two running cards report running: \(rig.describe(A)) \(rig.describe(B))")
    await rig.shutdown()
  }

  // 15. A wake-up that arrives while a waiting lane's attempt is still in flight is not
  //     lost: if that attempt ends waiting, exactly one more attempt follows (one flag per lane).
  static func case15() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])  // waiting
    let one = rig.world.candidate(A, pid: 101)
    rig.world.queue[A] = [[one], [one], []]  // the next attempt resolves 101, which is gone before start
    rig.trace.holdPrepare.insert(A)
    rig.events.processListChanged()
    await rig.advanceWithoutSettling(to: 0.3)  // the folded attempt begins and holds at prepare
    await rig.trace.prepareGate.entered()
    rig.world.appear(A, pids: [102])
    rig.events.processListChanged()  // the new process's list change, during the attempt
    rig.trace.prepareGate.release()
    await rig.settle()
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.trace.resolvedPIDs[A]?.last == 102, "15a: a change during an attempt is not lost: \(rig.describe(A))")
    await rig.shutdown()
    // 15b: several wake-ups during one attempt (list changes and a menu open), and still nothing there:
    //      exactly one more attempt, then quiet.
    let more = Rig()
    await more.apply([(A, true)])  // waiting
    let base = more.attempts(A)
    let gone = more.world.candidate(A, pid: 101)
    more.world.queue[A] = [[gone], [gone], []]
    more.trace.holdPrepare.insert(A)
    more.events.processListChanged()
    await more.advanceWithoutSettling(to: 0.3)  // attempt 2 holds at prepare
    await more.trace.prepareGate.entered()
    for _ in 0..<3 { more.events.processListChanged() }
    more.menuOpenedWithoutSettling()  // a menu open during the attempt
    more.trace.prepareGate.release()
    await more.settle()
    await more.advance(to: 10)
    try demand(more.attempts(A) == base + 2, "15b: the folded attempt, then exactly one more for the wake-ups during it: \(more.describe(A))")
    try demand(more.state(A) == Product.waitingState && more.problem == nil && more.clock.pending == 0, "15b: then quiet, nothing scheduled: \(more.describe(A))")
    await more.shutdown()
  }

  // 14. The accessibility value, the only new string here. A waiting card says "not playing"; running and off cards say nothing new.
  static func case14() async throws {
    try demand(Product.accessibilityValue(.waiting) == "not playing", "waiting card: \"not playing\": \(String(describing: Product.accessibilityValue(.waiting)))")
    try demand(Product.accessibilityValue(.running) == nil, "running card: no value")
    try demand(Product.accessibilityValue(.other) == nil, "off, starting or failed card: no value")
    try demand(Product.accessibilityValueRunning == nil && Product.accessibilityValueNotRunning == nil, "the fixed running and not-running entries carry no value")
    // Through the controller: an absent app's card is waiting and says "not playing", never "not open";
    // an off card says nothing.
    let rig = Rig()
    await rig.apply([(A, true), (B, false)])
    try demand(Product.accessibilityValue(rig.activity(A)) == "not playing", "absent app's card: \"not playing\": \(rig.describe(A))")
    try demand(Product.accessibilityValue(rig.activity(B)) == nil, "off card: no value: \(rig.describe(B))")
    await rig.shutdown()
  }

  // 17. A callback from a retired listener registration causes no attempt. The lane waits, is switched off
  //     (registration 1 removed), and waits again (registration 2); a late callback arrives through 1.
  static func case17() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    await rig.apply([(A, false)])
    await rig.apply([(A, true)])
    try demand(rig.events.listInstalls == 2 && rig.events.activeListListeners == 1, "setup: a second registration is live: adds \(rig.events.listInstalls)")
    let base = rig.attempts(A)
    rig.events.deliverToRetiredListListeners()
    await rig.settle()
    await rig.advance(by: 1)
    try demand(rig.attempts(A) == base && rig.clock.pending == 0, "a retired registration's callback does nothing: \(rig.describe(A))")
    // The live registration still wakes the lane.
    await rig.listChanged()
    await rig.advance(by: 1)
    try demand(rig.attempts(A) == base + 1, "the live registration still wakes it: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 17c. The real process-list listener on the system audio object is removed with exactly the
  //      registration it was added with. Registers and removes a listener only: no audio, no device change.
  static func case17c() async throws {
    let result = Product.realListenerAddAndRemove()
    try demand(result.add == 0, "the listener was added: status \(result.add)")
    try demand(result.remove == 0, "removing it succeeds (the same registration): status \(String(describing: result.remove))")
    try demand(result.again == nil, "a second removal has nothing to remove: \(String(describing: result.again))")
  }

  // 18. The read-to-subscribe gap. The first resolution finds nothing; the app's process appears before the
  //     listener is installed, and nothing else changes. The lane must still start: one look after subscribing.
  static func case18() async throws {
    let rig = Rig()
    rig.world.queue[A] = [[]]  // the first read finds nothing ...
    rig.world.appear(A, pids: [101])  // ... and every later read finds the process
    await rig.apply([(A, true)])
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.trace.resolvedPIDs[A]?.last == 101, "18a: the process that appeared in the gap runs: \(rig.describe(A))")
    try demand(rig.attempts(A) == 2 && rig.captureStarts(A) == 1 && rig.problem == nil, "18a: the first attempt, then exactly one look: \(rig.describe(A))")
    await rig.shutdown()
    // 18b: nothing appears: exactly one look, then quiet.
    let quiet = Rig()
    await quiet.apply([(A, true)])
    await quiet.advance(to: 30)
    try demand(quiet.attempts(A) == 2 && quiet.state(A) == Product.waitingState && quiet.clock.pending == 0, "18b: one look after subscribing, then quiet: \(quiet.describe(A))")
    await quiet.shutdown()
  }

  // 19. A wake start that is queued and has not entered the runtime yet, then a switch-off (19a) or a
  //     shutdown (19b): no capture starts, no lease is held, nothing is stranded.
  static func case19() async throws {
    // 19a: the queued start is held before the runtime while the switch-off's stop goes first.
    let rig = Rig()
    rig.installStartHold()
    await rig.apply([(A, true)])  // waiting
    rig.world.appear(A, pids: [101])  // a start now would succeed
    rig.startHold.arm()
    rig.menuOpenedWithoutSettling()  // the wake start is queued and holds before the runtime
    await rig.startHold.gate.entered()
    rig.applyWithoutSettling(power: true, [(A, false)])  // switched off while the start is queued
    await rig.drainQueued()
    rig.startHold.gate.release()
    await rig.settle()
    await rig.advance(by: 1)
    try demand(rig.captureStarts(A) == 0 && (rig.trace.outputStarts[A] ?? 0) == 0, "19a: no capture or output starts after the switch-off: \(rig.describe(A))")
    try demand(rig.nothingStranded(A) && rig.state(A) == "idle", "19a: no lease, nothing stranded, lane idle: \(rig.describe(A))")
    await rig.shutdown()
    // 19b: shutdown begins in the same turn as the wake, before the queued start runs (no hook needed).
    let quit = Rig()
    await quit.apply([(A, true)])
    quit.world.appear(A, pids: [101])
    quit.menuOpenedWithoutSettling()
    await quit.shutdownNow()
    await quit.settle()
    try demand(quit.captureStarts(A) == 0 && (quit.trace.outputStarts[A] ?? 0) == 0, "19b: no capture or output starts after shutdown: \(quit.describe(A))")
    try demand(quit.nothingStranded(A), "19b: no lease, nothing stranded after shutdown: \(quit.describe(A))")
  }

  // 20. Two lanes: A is being woken (its attempt under way), B is waiting, and the list changes once.
  //     A gets exactly one more attempt (the remembered one) and B gets one; the fold does not sweep A again.
  static func case20() async throws {
    let rig = Rig()
    await rig.apply([(A, true), (B, true)])  // both waiting
    let a = rig.world.candidate(A, pid: 101)
    rig.world.queue[A] = [[a], [a], []]  // A's next attempt reaches prepare, then finds nothing
    rig.trace.holdPrepare.insert(A)
    rig.menuOpenedWithoutSettling()  // A's attempt holds at prepare; B's attempt finds nothing
    await rig.trace.prepareGate.entered()
    for _ in 0..<200 where rig.state(B) != Product.waitingState { await Task.yield() }
    try demand(rig.state(B) == Product.waitingState, "setup: B is waiting again: \(rig.describe(B))")
    let a0 = rig.attempts(A), b0 = rig.attempts(B)
    rig.events.processListChanged()  // one change: A is being woken, B is waiting
    rig.trace.prepareGate.release()
    await rig.settle()
    await rig.advance(by: 1)
    let da = rig.attempts(A) - a0, db = rig.attempts(B) - b0
    try demand(da == 1, "A, woken when the change came, gets exactly one more attempt: \(da): \(rig.describe(A))")
    try demand(db == 1, "B, waiting when the change came, gets one attempt: \(db): \(rig.describe(B))")
    try demand(rig.clock.pending == 0 && rig.problem == nil, "then quiet: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 21. Shutdown while one lane is stopping and another's first start ends in waiting during that stop:
  //     no list listener is installed after shutdown begins. Shutdown visits lanes in an order the check
  //     cannot choose, so each try uses fresh lanes; the requirement is checked on every try.
  static func case21() async throws {
    var orders: [String] = [], witnessed = 0
    for attempt in 1...24 {
      let rig = Rig()
      let b = rig.world.candidate(B, pid: 201)
      let race = await shutdownRace(rig, bReads: [[b], [b], []])  // B's first start finds nothing at the end
      orders.append(race.aFirst ? "A" : "B")
      if race.bEndedDuringShutdown { witnessed += 1 }
      try demand(rig.events.listInstalls == race.addsBefore && !rig.events.listListenerInstalled,
        "try \(attempt) (shutdown stopped \(race.aFirst ? "A" : "B") first): no listener installed after shutdown began: adds \(race.addsBefore) -> \(rig.events.listInstalls)")
    }
    print("case 21 shutdown orders: \(orders.joined()); B's start ended during shutdown in \(witnessed) tries")
    try demand(witnessed > 0, "B's start never ended during shutdown in 24 tries, so the case proved nothing: orders \(orders.joined())")
  }

  /// Shutdown while A is running (its output stop held) and B's first start is held at prepare. B's start
  /// is released while shutdown is under way; in the tries where shutdown stops A first, B's start ends
  /// during shutdown. Returns once shutdown has finished.
  private static func shutdownRace(_ rig: Rig, bReads: [[ProcessCandidate]])
    async -> (aFirst: Bool, bEndedDuringShutdown: Bool, addsBefore: Int)
  {
    rig.world.appear(A, pids: [101])
    await rig.apply([(A, true)])  // A running
    rig.world.queue[B] = bReads
    rig.trace.holdPrepare.insert(B)
    rig.applyWithoutSettling([(A, true), (B, true)])
    await rig.trace.prepareGate.entered()
    rig.trace.holdSinkStop.insert(A)  // shutdown's stop of A holds at A's output
    let addsBefore = rig.events.listInstalls
    let done = Task { @MainActor in await rig.shutdownNow() }
    await rig.drainQueued()
    let aFirst = rig.trace.sinkStopGate.reached
    rig.trace.prepareGate.release()  // B's start goes on while shutdown is under way
    // The witness is the runtime's own report that B's start ended, so it does not depend on what the
    // controller then does with the result.
    if aFirst {
      for _ in 0..<1000 where (rig.trace.failures[B] ?? []).isEmpty { await Task.yield() }
      await rig.drainQueued()  // let the controller handle the result before shutdown goes on
    } else {
      await rig.drainQueued()
    }
    let ended = !(rig.trace.failures[B] ?? []).isEmpty
    rig.trace.sinkStopGate.release()
    await done.value
    return (aFirst, ended, addsBefore)
  }

  // 22. A quiet wake (waiting, an attempt, waiting again) tells the menu nothing; a wake that starts the
  //     lane does.
  static func case22() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    let p0 = rig.publications, a0 = rig.attempts(A)
    await rig.menuOpened()
    await rig.listChanged()
    await rig.advance(by: 1)
    await rig.launched(A)
    await rig.advance(by: 20)
    try demand(rig.attempts(A) == a0 + 7, "exactly 7 quiet attempts (menu 1, list 1, burst 5), no extra retries: \(rig.attempts(A) - a0): \(rig.describe(A))")
    try demand(rig.publications == p0, "quiet wakes publish nothing: \(p0) -> \(rig.publications)")
    rig.world.appear(A, pids: [101])
    await rig.listChanged()
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.publications > p0, "a wake that starts the lane publishes: \(rig.publications)")
    await rig.shutdown()
  }

  // 23. A second lane's first start misses while another lane already holds the listener; its audio then
  //     appears with no further event. The lane must still start: each lane whose ordinary start ends in
  //     waiting gets one look of its own, and no other lane is attempted because it started waiting.
  static func case23() async throws {
    // 23a: B's first read finds nothing, every later read finds B's process, and nothing else happens.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])  // A waiting, listener installed
      let a0 = rig.attempts(A)
      rig.world.queue[B] = [[]]
      rig.world.appear(B, pids: [201])
      await rig.apply([(A, true), (B, true)])
      await rig.advance(by: 1)
      try demand(rig.state(B) == "running" && rig.trace.resolvedPIDs[B]?.last == 201, "23a: B starts without another event: \(rig.describe(B))")
      try demand(rig.attempts(B) == 2, "23a: B's first start, then exactly one look: \(rig.describe(B))")
      try demand(rig.attempts(A) == a0, "23a: A is not attempted because B started waiting: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 23b: the list changes while B's first start is under way, and B's first read finds nothing. The
    //      change marks B while it is starting, and B must still start. A start that misses makes the lane
    //      owed by itself, so B starting in the end cannot show that the change reached it; the mark is read
    //      while the start is held, before it misses.
    do {
      let rig = Rig()
      rig.installStartHold()
      await rig.apply([(A, true)])  // A waiting
      rig.world.queue[B] = [[]]
      rig.world.appear(B, pids: [201])
      rig.startHold.arm()
      rig.applyWithoutSettling([(A, true), (B, true)])  // B's first start holds before the runtime
      await rig.startHold.gate.entered()
      try demand(rig.state(B) == "starting" && !rig.owed(B), "23b: setup: B starting and not owed before the change: \(rig.describe(B))")
      rig.events.processListChanged()  // B's process appeared; A is waiting, B is starting
      try demand(rig.owed(B), "23b: a list change during an ordinary start marks that lane: \(rig.describe(B))")
      rig.startHold.gate.release()
      await rig.settle()
      await rig.advance(by: 1)
      try demand(rig.state(B) == "running" && rig.trace.resolvedPIDs[B]?.last == 201, "23b: B starts although the change came during its first start: \(rig.describe(B))")
      await rig.shutdown()
    }
    // 23c: B absent: B gets its first start and exactly one look; A gets nothing from it.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])
      let a0 = rig.attempts(A)
      await rig.apply([(A, true), (B, true)])
      await rig.advance(to: 30)
      try demand(rig.attempts(B) == 2 && rig.state(B) == Product.waitingState, "23c: B's first start and one look: \(rig.describe(B))")
      try demand(rig.attempts(A) == a0 && rig.clock.pending == 0, "23c: A untouched, nothing scheduled: \(rig.describe(A))")
      await rig.shutdown()
    }
  }

  // 24. A fold owed to a lane does not survive switching that lane off and on again: the new activation's
  //     own start and look are all it gets, while another lane keeps the fold alive.
  static func case24() async throws {
    let rig = Rig()
    await rig.apply([(A, true), (B, true)])  // both waiting
    rig.events.processListChanged()  // a fold for A and B, due at 0.25 s
    await rig.settle()
    await rig.apply([(A, false), (B, true)])  // A off ...
    let aBefore = rig.attempts(A)
    await rig.apply([(A, true), (B, true)])  // ... and on again, at t = 0; its start misses
    await rig.advance(to: 1)
    let bLate = rig.attemptTimes(B).filter { $0 > 0.0001 }
    // The new activation gets its start and one look (with the fold open, the fold takes the look), never
    // a third attempt owed to the earlier activation.
    try demand(rig.attempts(A) - aBefore == 2, "A's new activation: its start and one look only: \(rig.attempts(A) - aBefore): \(rig.describe(A))")
    try demand(sameTimes(bLate, [0.25]), "B still gets its fold: \(bLate)")
    await rig.shutdown()
  }

  // 25. A positions-only switch-off of the only waiting lane while it is being woken, with a fold open,
  //     leaves no listener and no fold timer: the fold is cancelled, not left to run out.
  static func case25() async throws {
    let rig = Rig()
    rig.installStartHold()
    await rig.apply([(A, true)])  // waiting, listener installed
    rig.events.processListChanged()  // a fold opens at t = 0, due at 0.25 s
    try demand(sameTimes(rig.clock.pendingDue, [0.25]), "setup: a fold is open: \(rig.clock.pendingDue)")
    let a0 = rig.attempts(A)
    rig.startHold.arm()
    rig.menuOpenedWithoutSettling()  // the wake start holds before the runtime
    await rig.startHold.gate.entered()
    try demand(sameTimes(rig.clock.pendingDue, [0.25]), "setup: the fold is still open during the wake: \(rig.clock.pendingDue)")
    rig.positionsWithoutSettling([(A, false)])  // switched off by a positions-only delivery
    rig.startHold.gate.release()
    await rig.settle()  // no time has passed: the fold could not have run out
    try demand(rig.state(A) == "idle", "setup: the lane is idle: \(rig.describe(A))")
    try demand(!rig.events.listListenerInstalled && rig.clock.pending == 0, "no listener, and the fold cancelled, once nothing waits: active \(rig.events.activeListListeners): \(rig.describe(A))")
    await rig.advance(by: 1)
    try demand(rig.attempts(A) == a0, "nothing is attempted after the switch-off: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 26. A lane that is switched off never ends in waiting: its app quits during a wake attempt, the lane is
  //     switched off during the teardown, and the teardown then ends.
  static func case26() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])  // waiting
    rig.world.appear(A, pids: [101])
    rig.trace.holdPrepare.insert(A)
    rig.menuOpenedWithoutSettling()  // the wake attempt holds at prepare
    await rig.trace.prepareGate.entered()
    rig.sourceQuit(A)  // the app quits during the wake attempt
    rig.applyWithoutSettling(power: true, [(A, false)])  // switched off during the teardown
    let a0 = rig.attempts(A)
    rig.trace.prepareGate.release()
    await rig.settle()
    await rig.advance(by: 10)
    try demand(rig.state(A) == "idle" && rig.activity(A) != .waiting, "a switched-off lane ends idle, not waiting: \(rig.describe(A))")
    try demand(!rig.events.listListenerInstalled && rig.clock.pending == 0, "no listener or timer for it: \(rig.describe(A))")
    try demand(rig.attempts(A) == a0 && rig.problem == nil && rig.nothingStranded(A), "no attempt, no problem, nothing stranded: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 27. Two lanes' wake starts are queued and shutdown begins in the same turn. Shutdown reaches the lanes
  //     one at a time, so the second lane's start is stopped only by the quit check: no capture, no lease.
  static func case27() async throws {
    for attempt in 1...8 {
      let rig = Rig()
      await rig.apply([(A, true), (B, true)])  // both waiting
      rig.world.appear(A, pids: [101])
      rig.world.appear(B, pids: [201])
      rig.menuOpenedWithoutSettling()  // both wake starts queued
      await rig.shutdownNow()
      await rig.settle()
      try demand(rig.captureStarts(A) == 0 && rig.captureStarts(B) == 0
        && (rig.trace.outputStarts[A] ?? 0) == 0 && (rig.trace.outputStarts[B] ?? 0) == 0,
        "try \(attempt): no capture or output starts after shutdown: \(rig.describe(A)) | \(rig.describe(B))")
      try demand(rig.nothingStranded(A) && rig.nothingStranded(B), "try \(attempt): no lease, nothing stranded: \(rig.describe(A)) | \(rig.describe(B))")
    }
  }

  // 28. A fold mark already set on a lane is cleared when that lane is attempted by something else before
  //     the fold runs: A's burst step comes first, so the fold attempts only B.
  static func case28() async throws {
    let rig = Rig()
    await rig.apply([(A, true), (B, true)])  // both waiting
    await rig.launched(A)  // A's burst: 0.5, 1, 2, 4, 8 s
    await rig.advance(to: 0.4)
    await rig.listChanged()  // fold for A and B, due at 0.65 s
    await rig.advance(to: 0.9)
    let aWindow = rig.attemptTimes(A).filter { $0 > 0.3 && $0 < 0.95 }
    let bWindow = rig.attemptTimes(B).filter { $0 > 0.3 && $0 < 0.95 }
    try demand(sameTimes(aWindow, [0.5]), "A: its burst step only; the fold mark it carried was cleared: \(aWindow)")
    try demand(sameTimes(bWindow, [0.65]), "B: the fold: \(bWindow)")
    await rig.shutdown()
  }

  // 29. A burst step that finds nothing leaves the burst's remaining steps scheduled.
  static func case29() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])
    await rig.launched(A)
    await rig.advance(to: 0.6)  // the 0.5 s step has failed
    try demand(rig.state(A) == Product.waitingState, "setup: still waiting: \(rig.describe(A))")
    try demand(sameTimes(rig.clock.pendingDue, [1, 2, 4, 8]), "the remaining steps are still scheduled: \(rig.clock.pendingDue)")
    await rig.advance(to: 20)
    try demand(sameTimes(rig.attemptTimes(A).filter { $0 > 0.0001 }, [0.5, 1, 2, 4, 8]), "all five steps ran: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 30. The resolver finds the process and revalidation loses it, ten times running: attempts stay at what
  //     the triggering events allow, with no self-sustaining retry.
  static func case30() async throws {
    let rig = Rig()
    let p = rig.world.candidate(A, pid: 101)
    rig.world.queue[A] = Array(repeating: [[p], []], count: 10).flatMap { $0 }
    await rig.apply([(A, true)])
    let base = rig.attempts(A)
    try demand(base == 2, "the first start and one look: \(rig.describe(A))")
    for _ in 0..<8 { await rig.menuOpened() }  // eight more triggering events
    await rig.advance(to: 60)
    try demand(rig.attempts(A) == base + 8, "one attempt per triggering event, no more: \(rig.describe(A))")
    try demand(rig.world.reads[A] == 20 && (rig.world.queue[A] ?? []).isEmpty, "each attempt resolved once and revalidated once: reads \(rig.world.reads[A] ?? 0)")
    try demand(rig.state(A) == Product.waitingState && rig.problem == nil && rig.clock.pending == 0 && rig.nothingStranded(A), "then quiet: \(rig.describe(A))")
    await rig.shutdown()
  }

  /// A waiting (holding the listener); B is woken, B's app quits during the wake, and B's teardown is held
  /// at B's output stop. Returns with the teardown held; release `sinkStopGate` to end it.
  private static func quitDuringWake(_ rig: Rig) async {
    await rig.apply([(A, true), (B, true)])  // both waiting
    rig.world.appear(B, pids: [201])
    rig.trace.holdPrepare.insert(B)
    rig.trace.holdSinkStop.insert(B)
    rig.menuOpenedWithoutSettling()  // B's wake attempt holds at prepare (A's finds nothing)
    await rig.trace.prepareGate.entered()
    rig.world.vanish(B)
    rig.sourceQuit(B)  // B's app quits during the wake
    rig.trace.prepareGate.release()
    await rig.trace.sinkStopGate.entered()  // B's teardown is under way
  }

  // 31. A relaunch during the quit teardown of a lane that was being woken: the new process appears (and
  //     the list changes) before the teardown ends. When it ends, the lane looks once and starts.
  static func case31() async throws {
    let rig = Rig()
    await quitDuringWake(rig)
    rig.world.appear(B, pids: [202])
    rig.events.processListChanged()
    rig.trace.sinkStopGate.release()
    await rig.settle()
    await rig.advance(by: 1)
    try demand(rig.state(B) == "running" && rig.trace.resolvedPIDs[B]?.last == 202, "the relaunched process runs after the teardown: \(rig.describe(B))")
    try demand(rig.problem == nil && rig.captureStarts(B) == 1, "no problem, one start: \(rig.describe(B))")
    await rig.shutdown()
  }

  // 32. A launch of the app during that teardown is remembered: when the teardown ends in waiting, the
  //     launch burst starts from then.
  static func case32() async throws {
    let rig = Rig()
    await rig.advance(to: 10)
    await quitDuringWake(rig)
    rig.events.launched(B)  // during the teardown
    rig.trace.sinkStopGate.release()
    await rig.settle()  // the teardown ends at t = 10
    try demand(rig.state(B) == Product.waitingState && rig.problem == nil, "setup: waiting after the teardown: \(rig.describe(B))")
    await rig.advance(to: 40)
    let burst = rig.attemptTimes(B).filter { $0 > 10.0001 }.map { $0 - 10 }
    try demand(sameTimes(burst, [0.5, 1, 2, 4, 8]), "the remembered launch's burst runs from the teardown's end: \(rig.describe(B))")
    await rig.shutdown()
  }

  // 33. A start that returns `replaced` while shutdown is under way schedules no timer. Same race as
  //     case 21, with B's process replaced at its last revalidation.
  static func case33() async throws {
    var orders: [String] = [], witnessed = 0
    for attempt in 1...24 {
      let rig = Rig()
      let b = rig.world.candidate(B, pid: 201), relaunched = rig.world.candidate(B, pid: 202)
      let race = await shutdownRace(rig, bReads: [[b], [b], [relaunched]])
      orders.append(race.aFirst ? "A" : "B")
      if race.bEndedDuringShutdown { witnessed += 1 }
      try demand(rig.clock.pending == 0, "try \(attempt) (shutdown stopped \(race.aFirst ? "A" : "B") first): nothing scheduled after shutdown: \(rig.clock.pendingDue)")
    }
    print("case 33 shutdown orders: \(orders.joined()); B's start ended during shutdown in \(witnessed) tries")
    try demand(witnessed > 0, "B's start never ended during shutdown in 24 tries, so the case proved nothing: orders \(orders.joined())")
  }

  // 34. A second list change inside an open fold marks a lane that owed nothing until then: that lane is
  //     attempted when the fold fires. B starts waiting while the fold is open, and a menu open answers B's
  //     own debt (and A's), so only the second change can make the fold attempt B.
  static func case34() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])  // A waiting
    await rig.listChanged()  // the fold opens at t = 0, due at 0.25 s
    await rig.apply([(A, true), (B, true)])  // B's first start misses: B waiting, with the fold open
    try demand(rig.state(B) == Product.waitingState, "setup: B waiting: \(rig.describe(B))")
    await rig.advance(to: 0.05)
    await rig.menuOpened()  // at 0.05 s, B's audio still absent: A and B are attempted and miss
    try demand(rig.state(B) == Product.waitingState && !rig.owed(B) && !rig.owed(A),
      "setup: the menu open answered every debt: A owed \(rig.owed(A)), B owed \(rig.owed(B)): \(rig.describe(B))")
    try demand(sameTimes(rig.attemptTimes(B).filter { $0 > 0.0001 }, [0.05]), "setup: B's menu attempt at 0.05 s: \(rig.describe(B))")
    try demand(sameTimes(rig.clock.pendingDue, [0.25]), "setup: the fold is still open: \(rig.clock.pendingDue)")
    await rig.advance(to: 0.1)
    rig.world.appear(B, pids: [201])  // B's audio appears ...
    await rig.listChanged()  // ... and the list changes again inside the open fold
    try demand(rig.owed(B), "the second change marks B: \(rig.describe(B))")
    try demand(sameTimes(rig.clock.pendingDue, [0.25]), "the second change opens no second fold: \(rig.clock.pendingDue)")
    await rig.advance(to: 1)
    try demand(sameTimes(rig.attemptTimes(B).filter { $0 > 0.0001 }, [0.05, 0.25]), "B is attempted when the fold fires: \(rig.describe(B))")
    try demand(rig.state(B) == "running" && rig.trace.resolvedPIDs[B]?.last == 201, "and runs: \(rig.describe(B))")
    try demand(sameTimes(rig.attemptTimes(A).filter { $0 > 0.0001 }, [0.05, 0.25]), "A: the menu, then the fold: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 35. A launch notification during an ordinary (not a wake) start whose start then misses: the launch
  //     burst runs.
  static func case35() async throws {
    let rig = Rig()
    rig.installStartHold()
    rig.startHold.arm()
    rig.applyWithoutSettling([(A, true)])  // A's first start holds before the runtime
    await rig.startHold.gate.entered()
    rig.events.launched(A)  // the app launches while A's ordinary start is under way
    rig.startHold.gate.release()
    await rig.settle()  // the start misses: A waiting
    try demand(rig.state(A) == Product.waitingState, "setup: A waiting: \(rig.describe(A))")
    await rig.advance(to: 20)
    let burst = rig.attemptTimes(A).filter { $0 > 0.0001 }
    try demand(sameTimes(burst, [0.5, 1, 2, 4, 8]), "the launch's burst runs after the missed start: \(burst)")
    await rig.shutdown()
  }

  // 36. Burst steps whose attempts keep returning `replaced` do not re-arm the burst: five attempts per
  //     launch.
  static func case36() async throws {
    let rig = Rig()
    await rig.apply([(A, true)])  // A waiting
    let p = rig.world.candidate(A, pid: 101), q = rig.world.candidate(A, pid: 102)
    rig.world.queue[A] = Array(repeating: [[p], [q]], count: 40).flatMap { $0 }  // every attempt: replaced
    await rig.launched(A)  // at t = 0
    await rig.advance(to: 30)
    let after = rig.attemptTimes(A).filter { $0 > 0.0001 }
    try demand(sameTimes(after, [0.5, 1, 2, 4, 8]), "five attempts for one launch, whatever they return: \(after.count) at \(after.prefix(12))")
    try demand(rig.state(A) == Product.waitingState && rig.problem == nil && rig.clock.pending == 0, "then quiet: \(rig.describe(A))")
    await rig.shutdown()
  }

  // 37. A launch while the lane is off, then switch-on: no burst from the old launch.
  static func case37() async throws {
    // 37a: A is off (idle) while B waits; A's app launches; A is switched on and its start misses.
    do {
      let rig = Rig()
      await rig.apply([(A, false), (B, true)])
      await rig.launched(A)
      await rig.apply([(A, true), (B, true)])
      try demand(rig.clock.pending == 0, "37a: switch-on schedules no burst from the earlier launch: \(rig.clock.pendingDue)")
      await rig.advance(to: 20)
      try demand(rig.attemptTimes(A).filter { $0 > 0.0001 }.isEmpty, "37a: no burst from a launch while off: \(rig.describe(A))")
      try demand(rig.clock.pending == 0, "37a: nothing scheduled: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 37b: B is off during a quit teardown when its app launches, then switched on before the teardown ends.
    do {
      let rig = Rig()
      await rig.advance(to: 10)
      await quitDuringWake(rig)
      rig.applyWithoutSettling(power: true, [(A, true), (B, false)])  // off during the teardown
      rig.events.launched(B)  // launched while off
      rig.applyWithoutSettling(power: true, [(A, true), (B, true)])  // on again before the teardown ends
      rig.trace.sinkStopGate.release()
      await rig.settle()
      let scheduledAtEnd = rig.clock.pendingDue  // what the teardown's end scheduled, before anything fires
      await rig.advance(to: 40)
      let late = rig.attemptTimes(B).filter { $0 > 10.0001 }
      try demand(scheduledAtEnd.isEmpty, "37b: the teardown's end schedules no burst from the launch made while off: \(scheduledAtEnd)")
      try demand(late.isEmpty, "37b: no burst attempts: \(late)")
      try demand(rig.clock.pending == 0, "37b: nothing scheduled: \(rig.clock.pendingDue)")
      await rig.shutdown()
    }
  }

  // 38. The system refuses the list-listener add. The lane still waits quietly, the menu still wakes it,
  //     and the next reconcile (a later lane-state change) tries the add again.
  static func case38() async throws {
    // 38a: one refusal; a later state change adds the listener, and list changes then wake the lane.
    do {
      let rig = Rig()
      rig.events.refuseListAdds = 1
      await rig.apply([(A, true)])
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "38a: waits quietly after a refused add: \(rig.describe(A))")
      try demand(rig.events.listAddAttempts >= 2 && rig.events.activeListListeners == 1,
        "38a: a later reconcile added it: tries \(rig.events.listAddAttempts), live \(rig.events.activeListListeners)")
      rig.world.appear(A, pids: [101])
      await rig.listChanged()
      await rig.advance(by: 1)
      try demand(rig.state(A) == "running", "38a: the added listener wakes the lane: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 38b: every add refused: no listener, no problem, and a menu open still starts the lane.
    do {
      let rig = Rig()
      rig.events.refuseListAdds = 1000
      await rig.apply([(A, true)])
      let tries = rig.events.listAddAttempts
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil && !rig.events.listListenerInstalled, "38b: waits with no listener: \(rig.describe(A))")
      await rig.menuOpened()  // a lane-state change: the add is tried again
      try demand(rig.events.listAddAttempts > tries, "38b: the next reconcile tried the add again: \(tries) -> \(rig.events.listAddAttempts)")
      rig.world.appear(A, pids: [101])
      await rig.menuOpened()
      try demand(rig.state(A) == "running", "38b: the menu still wakes the lane without a listener: \(rig.describe(A))")
      await rig.shutdown()
    }
  }

  // 39. Cells of the lane-state table not pinned elsewhere.
  static func case39() async throws {
    // 39a: a menu open during an ordinary start marks the lane; the start then misses: owed is a flag, so
    //      one look, not two. A start that misses makes the lane owed by itself, so the mark is read while
    //      the start is held.
    do {
      let rig = Rig()
      rig.installStartHold()
      rig.startHold.arm()
      rig.applyWithoutSettling([(A, true)])
      await rig.startHold.gate.entered()
      try demand(rig.state(A) == "starting" && !rig.owed(A), "39a: setup: starting and not owed before the menu opens: \(rig.describe(A))")
      rig.menuOpenedWithoutSettling()
      try demand(rig.owed(A) && rig.attempts(A) == 0, "39a: a menu open during an ordinary start marks it and starts nothing: \(rig.describe(A))")
      rig.startHold.gate.release()
      await rig.settle()
      await rig.advance(to: 10)
      try demand(rig.attempts(A) == 2 && rig.state(A) == Product.waitingState, "39a: the start and one look: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 39b: a launch during a wake attempt starts the burst; the attempt then misses with nothing owed.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])  // waiting
      let one = rig.world.candidate(A, pid: 101)
      rig.world.queue[A] = [[one], [one], []]  // the next attempt reaches prepare, then misses
      rig.trace.holdPrepare.insert(A)
      rig.menuOpenedWithoutSettling()
      await rig.trace.prepareGate.entered()
      rig.events.launched(A)  // during the wake attempt
      rig.trace.prepareGate.release()
      await rig.settle()
      await rig.advance(to: 20)
      let steps = rig.attemptTimes(A).filter { $0 > 0.0001 }
      try demand(sameTimes(steps, [0.5, 1, 2, 4, 8]), "39b: the burst runs from the launch: \(steps)")
      await rig.shutdown()
    }
    // 39c: a burst step during a wake attempt makes the lane owed; when that attempt misses, it is
    //      attempted at once.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])  // waiting
      let one = rig.world.candidate(A, pid: 101)
      rig.world.queue[A] = [[one], [one], []]  // the 0.5 s step's attempt reaches prepare, then misses
      rig.trace.holdPrepare.insert(A)
      rig.events.launched(A)
      await rig.advanceWithoutSettling(to: 0.5)
      await rig.trace.prepareGate.entered()
      await rig.advanceWithoutSettling(to: 1.0)  // the 1 s step arrives while the attempt is under way
      rig.trace.prepareGate.release()
      await rig.settle()
      await rig.advance(to: 20)
      let steps = rig.attemptTimes(A).filter { $0 > 0.0001 }
      try demand(sameTimes(steps, [0.5, 1, 2, 4, 8]), "39c: the step that came during the attempt is answered when it misses: \(steps)")
      await rig.shutdown()
    }
    // 39d: a wake attempt that fails for another reason while a launch burst is live: a problem, nothing
    //      owed, and the burst's remaining steps cancelled at once.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])  // waiting
      await rig.launched(A)  // at t = 0
      await rig.advance(to: 0.6)  // the 0.5 s step found nothing
      try demand(sameTimes(rig.clock.pendingDue, [1, 2, 4, 8]), "39d: setup: the burst is live: \(rig.clock.pendingDue)")
      rig.world.appear(A, pids: [101, 102])
      await rig.menuOpened()  // the wake attempt finds two processes
      try demand(rig.state(A) == "failed" && rig.problem != nil, "39d: two processes is a problem: \(rig.describe(A))")
      try demand(!rig.owed(A) && rig.clock.pending == 0, "39d: nothing owed, the burst cancelled: \(rig.describe(A))")
      let a0 = rig.attempts(A)
      await rig.advance(to: 20)
      try demand(rig.attempts(A) == a0, "39d: no burst step runs after the failure: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 39e: a second launch while a burst is live replaces it: the old remaining steps never run, and the
    //      new five run from the second launch.
    do {
      let rig = Rig()
      await rig.apply([(A, true)])  // waiting
      await rig.launched(A)  // at t = 0: steps at 0.5, 1, 2, 4, 8
      await rig.advance(to: 1.2)  // the 0.5 and 1 s steps have run
      await rig.launched(A)  // at 1.2 s: steps at 1.7, 2.2, 3.2, 5.2, 9.2
      try demand(sameTimes(rig.clock.pendingDue, [1.7, 2.2, 3.2, 5.2, 9.2]), "39e: only the new burst is scheduled: \(rig.clock.pendingDue)")
      await rig.advance(to: 30)
      let steps = rig.attemptTimes(A).filter { $0 > 0.0001 }
      try demand(sameTimes(steps, [0.5, 1, 1.7, 2.2, 3.2, 5.2, 9.2]), "39e: two steps of the first burst, then the second burst's five: \(steps)")
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil && rig.clock.pending == 0, "39e: then quiet: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 39f: a burst step fires during an ordinary start: it marks the lane and starts nothing, the start
    //      then misses and gets its one look, and the burst goes on.
    do {
      let rig = Rig()
      rig.installStartHold()
      rig.startHold.arm()
      rig.applyWithoutSettling([(A, true)])  // A's first start holds before the runtime
      await rig.startHold.gate.entered()
      rig.events.launched(A)  // at t = 0, during the ordinary start
      await rig.advanceWithoutSettling(to: 0.5)  // the 0.5 s step fires while A is still starting
      try demand(rig.owed(A) && rig.attempts(A) == 0 && rig.state(A) == "starting", "39f: the step marks the starting lane and starts nothing: \(rig.describe(A))")
      try demand(sameTimes(rig.clock.pendingDue, [1, 2, 4, 8]), "39f: the rest of the burst is still scheduled: \(rig.clock.pendingDue)")
      rig.startHold.gate.release()
      await rig.settle()  // the start misses at 0.5 s; its one look follows at once
      await rig.advance(to: 20)
      let times = rig.attemptTimes(A)
      try demand(sameTimes(times, [0.5, 0.5, 1, 2, 4, 8]), "39f: the start, its one look, then the burst's remaining steps: \(times)")
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil && rig.clock.pending == 0, "39f: then quiet: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 39g: an ordinary start that fails for another reason while a launch burst is live: a problem, nothing
    //      owed, and the burst cancelled at once.
    do {
      let rig = Rig()
      rig.installStartHold()
      rig.startHold.arm()
      rig.applyWithoutSettling([(A, true)])  // A's first start holds before the runtime
      await rig.startHold.gate.entered()
      rig.events.launched(A)  // at t = 0, during the ordinary start
      await rig.advanceWithoutSettling(to: 0.5)  // the 0.5 s step fires while A is still starting
      try demand(sameTimes(rig.clock.pendingDue, [1, 2, 4, 8]), "39g: setup: the burst is live: \(rig.clock.pendingDue)")
      rig.world.appear(A, pids: [101, 102])
      rig.startHold.gate.release()
      await rig.settle()  // the start finds two processes
      try demand(rig.state(A) == "failed" && rig.problem != nil, "39g: two processes is a problem: \(rig.describe(A))")
      try demand(!rig.owed(A) && rig.clock.pending == 0, "39g: nothing owed, the burst cancelled: \(rig.describe(A))")
      await rig.advance(to: 20)
      try demand(sameTimes(rig.attemptTimes(A), [0.5]), "39g: no attempt after the failure: \(rig.describe(A))")
      await rig.shutdown()
    }
  }

  // 40. Switching off a failed lane: nothing is owed and nothing is scheduled, and later events attempt
  //     nothing. The lane's state is what each kind of switch-off already does: a full delivery makes it idle
  //     and clears its problem; a positions-only delivery leaves it as it was.
  static func case40() async throws {
    for full in [true, false] {
      let label = full ? "40a full delivery" : "40b positions-only delivery"
      let rig = Rig()
      rig.world.appear(A, pids: [101, 102])
      await rig.apply([(A, true), (B, true)])  // A failed; B waiting holds the listener
      try demand(rig.state(A) == "failed" && rig.problem != nil, "\(label): setup: A failed: \(rig.describe(A))")
      try demand(rig.events.listListenerInstalled, "\(label): setup: the listener is installed: \(rig.describe(B))")
      if full { await rig.apply([(A, false), (B, true)]) } else { await rig.positions([(A, false), (B, true)]) }
      if full {
        try demand(rig.state(A) == "idle" && rig.problem == nil, "\(label): a failed lane switched off is idle with no problem: \(rig.describe(A))")
      } else {
        try demand(rig.state(A) == "failed", "\(label): the lane's state is unchanged: \(rig.describe(A))")
      }
      try demand(!rig.owed(A) && rig.clock.pending == 0, "\(label): nothing owed or scheduled: \(rig.describe(A))")
      let a0 = rig.attempts(A)
      await rig.listChanged(); await rig.launched(A); await rig.menuOpened()
      try demand(rig.clock.pending <= 1 && !rig.owed(A), "\(label): later events give A no burst and no debt: \(rig.clock.pendingDue): \(rig.describe(A))")
      await rig.advance(by: 30)
      try demand(rig.attempts(A) == a0 && rig.clock.pending == 0, "\(label): no attempt after the switch-off: \(rig.describe(A))")
      await rig.shutdown()
    }
  }

  // 16. A different process found at revalidation (`replaced`) is a miss like any other: the lane
  //     waits quietly and gets one look; no burst starts.
  static func case16() async throws {
    // 16a: replaced before prepare; 16b: replaced before start (tap prepared). No process afterwards.
    for (label, reads) in [("16a before prepare", 1), ("16b before start", 2)] {
      let rig = Rig()
      await rig.advance(to: 5)
      let old = rig.world.candidate(A, pid: 101), new = rig.world.candidate(A, pid: 102)
      rig.world.queue[A] = Array(repeating: [old], count: reads) + [[new]]
      await rig.apply([(A, true)])  // attempt at t = 5 finds 101, then 102 at revalidation
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil, "\(label): replaced is waiting, not a problem: \(rig.describe(A))")
      try demand(rig.nothingStranded(A) && rig.captureStarts(A) == 0, "\(label): nothing stranded or started: \(rig.describe(A))")
      await rig.advance(to: 40)
      // A replaced process is a miss like any other: the start and one look, both at t = 5, and no burst.
      let late = rig.attemptTimes(A).filter { $0 > 5.0001 }
      try demand(late.isEmpty && rig.attempts(A) == 2, "\(label): the start and one look, no burst: \(rig.describe(A))")
      try demand(rig.state(A) == Product.waitingState && rig.problem == nil && rig.clock.pending == 0, "\(label): still quiet, nothing left scheduled: \(rig.describe(A))")
      await rig.shutdown()
    }
    // 16c: the new process is there for the burst: the first burst step runs it.
    let rig = Rig()
    let old = rig.world.candidate(A, pid: 101), new = rig.world.candidate(A, pid: 102)
    rig.world.queue[A] = [[old], [new]]
    rig.world.appear(A, pids: [102])
    await rig.apply([(A, true)])
    try demand(rig.problem == nil, "16c: replaced is not a problem: \(rig.describe(A))")
    await rig.advance(to: 0.5)
    try demand(rig.state(A) == "running" && rig.trace.resolvedPIDs[A]?.last == 102, "16c: the new process runs by the burst's first step: \(rig.describe(A))")
    try demand(rig.clock.pending == 0, "16c: the rest of the burst is cancelled at once: \(rig.describe(A))")
    await rig.shutdown()
  }
}

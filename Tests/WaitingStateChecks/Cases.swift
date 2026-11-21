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

  // 5. Menu open: one attempt per waiting lane, none for running or off lanes.
  static func case5() async throws {
    let rig = Rig()
    rig.world.appear(C, pids: [303])
    await rig.apply([(A, true), (B, true), (C, true), (D, false)])
    try demand(rig.state(A) == Product.waitingState && rig.state(B) == Product.waitingState && rig.state(C) == "running", "setup: A, B waiting, C running: \(rig.describe(A)) \(rig.describe(C))")
    let before = [A, B, C, D].map { rig.attempts($0) }
    await rig.menuOpened()
    await rig.advance(by: 0.3)  // in case menu-open attempts share the list fold
    let after = [A, B, C, D].map { rig.attempts($0) }
    try demand(zip(after, before).map { $0 - $1 } == [1, 1, 0, 0], "menu open: one attempt per waiting lane, none for running or off: before \(before) after \(after)")
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
    await quit.shutdown()
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
    var orders: [String] = []
    for attempt in 1...24 {
      let rig = Rig()
      rig.world.appear(A, pids: [101])
      await rig.apply([(A, true)])  // A running
      let b = rig.world.candidate(B, pid: 201)
      rig.world.queue[B] = [[b], [b], []]  // B's first start reaches prepare, then finds nothing
      rig.trace.holdPrepare.insert(B)
      rig.applyWithoutSettling([(A, true), (B, true)])
      await rig.trace.prepareGate.entered()
      rig.trace.holdSinkStop.insert(A)  // shutdown's stop of A holds at A's output
      let addsBefore = rig.events.listInstalls
      let done = Task { @MainActor in await rig.shutdown() }
      await rig.drainQueued()
      let aFirst = rig.trace.sinkStopGate.reached
      orders.append(aFirst ? "A" : "B")
      rig.trace.prepareGate.release()  // B's start finishes, in waiting, while shutdown is under way
      await rig.drainQueued()
      rig.trace.sinkStopGate.release()
      await done.value
      try demand(rig.events.listInstalls == addsBefore && !rig.events.listListenerInstalled,
        "try \(attempt) (shutdown stopped \(aFirst ? "A" : "B") first): no listener installed after shutdown began: adds \(addsBefore) -> \(rig.events.listInstalls)")
    }
    print("case 21 shutdown orders: \(orders.joined())")
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
    try demand(rig.attempts(A) >= a0 + 7, "setup: menu, list and burst attempts were made: \(rig.describe(A))")
    try demand(rig.publications == p0, "quiet wakes publish nothing: \(p0) -> \(rig.publications)")
    rig.world.appear(A, pids: [101])
    await rig.listChanged()
    await rig.advance(by: 1)
    try demand(rig.state(A) == "running" && rig.publications > p0, "a wake that starts the lane publishes: \(rig.publications)")
    await rig.shutdown()
  }

  // 16. A different process found at revalidation (`replaced`) counts as a relaunch: the
  //     lane waits, quietly, and the launch burst starts.
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
      let burst = rig.attemptTimes(A).filter { $0 > 5.0001 }.map { $0 - 5 }
      try demand(sameTimes(Array(burst), [0.5, 1, 2, 4, 8]), "\(label): the launch burst follows at 0.5, 1, 2, 4, 8 s: \(rig.describe(A))")
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

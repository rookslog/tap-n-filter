// Fakes for the waiting-state checks: the system's audio-process list, the wake-up events, a clock
// advanced by hand, and capture/output that record what was prepared, started and stopped.
// No CoreAudio, no NSWorkspace, no real time, no sound. Names the product's new code only through Names.swift.

import Foundation
import PlaybackLifecycle
import PlaybackRuntime
import SoundModel

@testable import PlaybackOutput

struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

func demand(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  guard condition else { throw CheckFailure(description: message()) }
}

// MARK: Clock

/// One-shot work scheduled by the controller, run only when a check advances time.
@MainActor final class ManualClock {
  private struct Item {
    let id: Int
    let due: TimeInterval
    let tag: String?
    let work: @MainActor () -> Void
  }
  private(set) var now: TimeInterval = 0
  private var items: [Item] = []
  private var nextID = 0

  /// Scheduled and not yet run or cancelled.
  var pending: Int { items.count }
  var pendingDue: [TimeInterval] { items.map(\.due).sorted() }

  /// Work scheduled while this is set carries it as a tag (a launch's burst steps carry the launched bundle).
  var tag: String?
  /// How many tagged items actually ran, by tag. A cancelled item never runs, so it is not counted.
  private(set) var ranByTag: [String: Int] = [:]

  func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    nextID += 1
    let id = nextID
    items.append(Item(id: id, due: now + max(0, delay), tag: tag, work: work))
    return { [weak self] in self?.items.removeAll { $0.id == id } }
  }

  /// Runs due work in time order. After each item, `settle` lets any start it began finish at that instant.
  func advance(to target: TimeInterval, settle: () async -> Void) async {
    while let next = items.filter({ $0.due <= target + 1e-9 }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
      items.removeAll { $0.id == next.id }
      now = max(now, next.due)
      if let tag = next.tag { ranByTag[tag, default: 0] += 1 }
      next.work()
      await settle()
    }
    now = max(now, target)
  }
}

// MARK: Wake-up events

/// Stands in for the HAL process-list listener and the NSWorkspace launch notification.
@MainActor final class WakeEvents {
  private var listHandlers: [Int: @MainActor () -> Void] = [:]
  /// Handlers of registrations that were removed, kept so a check can deliver a late callback through one,
  /// as the HAL may for a callback already queued when the listener was removed.
  private var retiredListHandlers: [Int: @MainActor () -> Void] = [:]
  private var launchHandlers: [Int: @MainActor (String) -> Void] = [:]
  private var nextID = 0
  private(set) var listInstalls = 0
  /// How many times each list registration's removal was called, by registration (in install order).
  private(set) var listRemovals: [Int: Int] = [:]
  private var listOrder: [Int] = []

  var listListenerInstalled: Bool { !listHandlers.isEmpty }
  var activeListListeners: Int { listHandlers.count }
  /// Removal calls per registration, in install order: `[1, 1]` is two registrations each removed once.
  var removalsPerRegistration: [Int] { listOrder.map { listRemovals[$0] ?? 0 } }

  /// The next this-many list-listener adds are refused, as the system may refuse one (the add returns nil).
  var refuseListAdds = 0
  /// Every add the controller asked for, refused or not.
  private(set) var listAddAttempts = 0
  /// Called once per list change actually delivered to a live registration (for the per-lane bound).
  var onListChangeDelivered: (@MainActor () -> Void)?
  /// Called once per launch notification, before and after the controller handles it (for the per-lane bound).
  var onLaunchDelivered: (@MainActor (String) -> Void)?
  var onLaunchHandled: (@MainActor (String) -> Void)?

  func installListListener(_ handler: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)? {
    listAddAttempts += 1
    if refuseListAdds > 0 { refuseListAdds -= 1; return nil }
    nextID += 1
    let id = nextID
    listHandlers[id] = handler
    listInstalls += 1
    listOrder.append(id)
    return { [weak self] in
      guard let self else { return }
      self.listRemovals[id, default: 0] += 1
      if let removed = self.listHandlers.removeValue(forKey: id) { self.retiredListHandlers[id] = removed }
    }
  }

  /// A callback arrives through every registration that has already been removed.
  func deliverToRetiredListListeners() { for handler in retiredListHandlers.values { handler() } }

  func installLaunchListener(_ handler: @escaping @MainActor (String) -> Void) -> @MainActor () -> Void {
    nextID += 1
    let id = nextID
    launchHandlers[id] = handler
    return { [weak self] in self?.launchHandlers[id] = nil }
  }

  /// The system's audio-process list changed. Delivered only to an installed listener, as the HAL would.
  func processListChanged() {
    if !listHandlers.isEmpty { onListChangeDelivered?() }
    for handler in listHandlers.values { handler() }
  }

  /// An app launched.
  func launched(_ bundle: String) {
    onLaunchDelivered?(bundle)
    for handler in launchHandlers.values { handler(bundle) }
    onLaunchHandled?(bundle)
  }
}

// MARK: The system's audio processes

/// Which audio processes exist, per bundle. `queue` answers the next catalog reads in order before
/// `present` applies, so a process can vanish between resolve and a revalidation.
@MainActor final class World {
  var present: [String: [ProcessCandidate]] = [:]
  var queue: [String: [[ProcessCandidate]]] = [:]
  private(set) var reads: [String: Int] = [:]

  func candidate(_ bundle: String, pid: Int32) -> ProcessCandidate {
    ProcessCandidate(binding: try! AppBinding(bundleIdentifier: bundle), pid: pid, audioProcessID: UInt32(pid))
  }
  func appear(_ bundle: String, pids: [Int32]) { present[bundle] = pids.map { candidate(bundle, pid: $0) } }
  func vanish(_ bundle: String) { present[bundle] = [] }

  func answer(_ bundle: String) -> [ProcessCandidate] {
    reads[bundle, default: 0] += 1
    if var next = queue[bundle], !next.isEmpty {
      let first = next.removeFirst()
      queue[bundle] = next
      return first
    }
    return present[bundle] ?? []
  }
}

@MainActor struct ScriptedCatalog: ProcessCatalog {
  let world: World
  func processes(for binding: AppBinding) throws -> [ProcessCandidate] { world.answer(binding.bundleIdentifier) }
}

@MainActor struct InertGuard: InputGuardPort {
  func recoverIfStranded() async -> GuardRestoration { .noMarker }
  func engage(settingEnabled: Bool) async -> GuardEngagement { .declined(reason: "inert waiting-state fake") }
  func restore() async -> GuardRestoration { .noMarker }
}

// MARK: Capture and output

/// A small one-shot gate a fake can pause on, so a check can act while a start is in progress.
/// A release that comes before the pause lets that pause pass at once.
@MainActor final class Gate {
  private var waiter: CheckedContinuation<Void, Never>?
  private var arrivals: [CheckedContinuation<Void, Never>] = []
  private var open = false
  private(set) var reached = false
  func pause() async {
    reached = true
    if open { open = false; return }
    await withCheckedContinuation { waiter = $0; for a in arrivals { a.resume() }; arrivals = [] }
  }
  func entered() async { if waiter == nil { await withCheckedContinuation { arrivals.append($0) } } }
  func release() {
    if let waiter { waiter.resume(); self.waiter = nil } else { open = true }
  }
}

/// Holds the first call made after it is armed, until released. Later calls pass.
@MainActor final class OneShotHold {
  private var armed = false
  let gate = Gate()
  func arm() { armed = true }
  func hold() async {
    guard armed else { return }
    armed = false
    await gate.pause()
  }
}

@MainActor final class Trace {
  let clock: ManualClock
  init(clock: ManualClock) { self.clock = clock }
  /// Times of each resolve attempt (`.resolving`), per bundle.
  var attempts: [String: [TimeInterval]] = [:]
  var resolvedPIDs: [String: [Int32]] = [:]
  /// Start failures the runtime reported (`.failed`), per bundle, whatever the controller then did.
  var failures: [String: [RuntimeFailure]] = [:]
  var startCompletions: [String: [String]] = [:]
  var sessionsMade: [String: Int] = [:]
  var prepared: [String: Int] = [:]
  var captureStarts: [String: Int] = [:]
  var stopped: [String: Int] = [:]
  var outputStarts: [String: Int] = [:]
  /// Bundles whose next capture prepare pauses at `prepareGate`.
  var holdPrepare: Set<String> = []
  let prepareGate = Gate()
  /// Bundles whose next output stop pauses at `sinkStopGate`.
  var holdSinkStop: Set<String> = []
  let sinkStopGate = Gate()
  /// Told of each resolve attempt as it begins, so the rig can say whether it is a wake attempt.
  var onResolving: (@MainActor (String) -> Void)?

  func observed(_ bundle: String, _ observation: LifecycleObservation) {
    switch observation.event {
    case .resolving:
      attempts[bundle, default: []].append(clock.now)
      onResolving?(bundle)
    case .resolved(let process): resolvedPIDs[bundle, default: []].append(process.pid)
    case .failed(let failure, _, _): failures[bundle, default: []].append(failure)
    default: break
    }
  }
}

@MainActor final class FakeCapture: CaptureSession {
  let trace: Trace, bundle: String
  private var wasPrepared = false, wasStopped = false
  init(_ trace: Trace, bundle: String) { self.trace = trace; self.bundle = bundle }
  func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
    if trace.holdPrepare.remove(bundle) != nil { await trace.prepareGate.pause() }
    wasPrepared = true
    trace.prepared[bundle, default: 0] += 1
    return CapturePreparation(format: try StreamFormat(sampleRate: 48000, channels: 2))
  }
  func start() async throws {
    try Task.checkCancellation()
    trace.captureStarts[bundle, default: 0] += 1
  }
  func stop() async -> TeardownOutcome {
    if !wasStopped { wasStopped = true; trace.stopped[bundle, default: 0] += 1 }
    return .completed
  }
}

@MainActor struct FakeCaptureFactory: CaptureSessionFactory {
  let trace: Trace, bundle: String
  func makeSession() -> any CaptureSession {
    trace.sessionsMade[bundle, default: 0] += 1
    return FakeCapture(trace, bundle: bundle)
  }
}

@MainActor final class FakeSink: PlaybackSink {
  let trace: Trace, bundle: String
  init(_ trace: Trace, bundle: String) { self.trace = trace; self.bundle = bundle }
  func prepare(_ capture: CapturePreparation) async throws {}
  func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {}
  func start() throws { trace.outputStarts[bundle, default: 0] += 1 }
  func stop() async { if trace.holdSinkStop.remove(bundle) != nil { await trace.sinkStopGate.pause() } }
}

// MARK: Rig

/// One real PlaybackController over the fakes above. Cards are named by bundle ("test.A" ...).
@MainActor final class Rig {
  let clock = ManualClock()
  let world = World()
  let events = WakeEvents()
  let trace: Trace
  let leases = InputGuardLeaseCoordinator(port: InertGuard(), settingEnabled: false)
  private(set) var controller: PlaybackController!
  /// How many times the controller told the menu something changed.
  private(set) var publications = 0
  /// Holds a start between being queued and entering the runtime, once armed.
  let startHold = OneShotHold()
  private var ids: [String: UUID] = [:]

  init() {
    RigAudit.made += 1
    let trace = Trace(clock: clock)
    self.trace = trace
    let world = self.world, leases = self.leases
    controller = Product.makeController(
      lane: { assignment, observe in
        let bundle = assignment.bundleIdentifier
        let factory = PlaybackCaptureFactory(
          inner: FakeCaptureFactory(trace: trace, bundle: bundle), assignment: assignment
        ) { value, _ in FakeSink(trace, bundle: value.bundleIdentifier) }
        let runtime = PlaybackRuntime(
          resolver: BundleProcessResolver(catalog: ScriptedCatalog(world: world)), factory: factory,
          leases: leases, observe: { observation in trace.observed(bundle, observation); observe(observation) })
        return (factory, runtime)
      }, events: events, clock: clock)
    controller.changed = { [weak self] in self?.publications += 1 }
    events.onListChangeDelivered = { [weak self] in self?.countForSwitchedOn { $0.listChanges += 1 } }
    // A launch's burst steps are the clock items scheduled while the controller handles it; each one that
    // actually runs allows one wake attempt, so a burst cancelled before its first step allows none.
    let burstClock = self.clock
    events.onLaunchDelivered = { bundle in burstClock.tag = bundle }
    events.onLaunchHandled = { _ in burstClock.tag = nil }
    // A resolve attempt begun while the card reads as waiting is a wake attempt (an attempt from waiting keeps
    // reading as waiting while it is under way); any other is an ordinary start.
    trace.onResolving = { [weak self] bundle in
      guard let self else { return }
      if self.activity(bundle) == .waiting {
        self.wakeAttemptsByLane[bundle, default: 0] += 1
        self.ordinaryInFlight.remove(bundle)
      } else {
        self.ordinaryInFlight.insert(bundle)
      }
    }
    controller.startedForTesting = { [weak self] id, state in
      guard let self, let bundle = self.ids.first(where: { $0.value == id })?.key else { return }
      self.trace.startCompletions[bundle, default: []].append(state)
      // Only an ordinary start that ends in waiting earns its one look.
      if self.ordinaryInFlight.remove(bundle) != nil, state == Product.waitingState {
        self.allowance[bundle, default: Allowance()].ordinaryMisses += 1
      }
    }
  }

  func id(_ bundle: String) -> UUID {
    if let id = ids[bundle] { return id }
    let id = UUID()
    ids[bundle] = id
    return id
  }

  /// What a lane's events allow it in wake attempts, at most. Each wake attempt spends one of: a list change
  /// or menu open delivered while the lane was switched on, a burst step that actually ran, or the one look
  /// earned by an ordinary start that ended in waiting. Ordinary starts are not wake attempts and are not
  /// counted; a delivery that starts nothing allows nothing.
  struct Allowance {
    var listChanges = 0, menuOpens = 0, burstSteps = 0, ordinaryMisses = 0
    var bound: Int { listChanges + menuOpens + burstSteps + ordinaryMisses }
  }
  private(set) var allowance: [String: Allowance] = [:]
  private var switchedOn: [String: Bool] = [:]
  private var wakeAttemptsByLane: [String: Int] = [:]
  private var ordinaryInFlight: Set<String> = []
  private func countForSwitchedOn(_ add: (inout Allowance) -> Void) {
    for (bundle, on) in switchedOn where on { add(&allowance[bundle, default: Allowance()]) }
  }

  /// Wake attempts (resolve attempts begun from waiting) made for a lane.
  func wakeAttempts(_ bundle: String) -> Int { wakeAttemptsByLane[bundle] ?? 0 }

  private func allowanceNow(_ bundle: String) -> Allowance {
    var value = allowance[bundle] ?? Allowance()
    value.burstSteps = clock.ranByTag[bundle] ?? 0
    return value
  }

  /// The checks every case ends with, run by `shutdown()` and reported through `RigAudit`:
  /// at rest no waiting lane is owed, and the attempt bound holds.
  func endChecks() async {
    await settle()
    await advance(by: 60)  // at rest: every fold and burst step has run
    for bundle in ids.keys {
      if state(bundle) == Product.waitingState, Product.owed(controller, id(bundle)) {
        RigAudit.problems.append("at rest, waiting lane \(bundle) is still owed: \(describe(bundle))")
      }
    }
    boundChecks()
  }

  /// Per lane, wake attempts never exceed what its events allow. Across the controller, its own count of
  /// wake attempts (which also counts any stopped before they reached the runtime) stays within the lanes'
  /// allowances together, and is never below what this rig counted.
  private func boundChecks() {
    var total = 0, counted = 0
    for bundle in ids.keys {
      let allowed = allowanceNow(bundle)
      total += allowed.bound
      counted += wakeAttempts(bundle)
      if wakeAttempts(bundle) > allowed.bound {
        RigAudit.problems.append("lane \(bundle) made \(wakeAttempts(bundle)) wake attempts, more than its events allow (\(allowed.bound)): \(allowed): \(describe(bundle))")
      }
    }
    let product = Product.wakeAttempts(controller)
    if product > total {
      RigAudit.problems.append("the controller made \(product) wake attempts, more than all lanes' events allow (\(total))")
    }
    if counted > product {
      RigAudit.problems.append("\(counted) wake attempts were seen but the controller counted \(product): the check's own count is wrong")
    }
  }

  func snapshot(power: Bool, _ cards: [(String, Bool)]) -> ListeningRenderSnapshot {
    for (bundle, on) in cards { switchedOn[bundle] = power && on }
    return ListeningRenderSnapshot(isEnabled: power, assignments: cards.map {
      ListeningRenderAssignment(id: id($0.0), bundleIdentifier: $0.0, isEnabled: $0.1, parts: [])
    })
  }

  /// A full delivery, as the library coordinator sends on a mutation or at attach.
  func apply(power: Bool = true, _ cards: [(String, Bool)]) async {
    controller.apply(snapshot(power: power, cards), original: false)
    await settle()
  }

  /// A positions-only delivery, which can also carry a switch change.
  func positions(power: Bool = true, _ cards: [(String, Bool)]) async {
    _ = controller.updatePositions(snapshot(power: power, cards), original: false)
    await settle()
  }

  func settle() async {
    for _ in 0..<4 {
      await controller.quiescent()
      await Task.yield()
    }
  }

  func advance(to time: TimeInterval) async {
    await clock.advance(to: time) { await self.settle() }
    await settle()
  }
  func advance(by delta: TimeInterval) async { await advance(to: clock.now + delta) }

  /// The assigned app quit: the same entry the termination observer uses (existing seam).
  func sourceQuit(_ bundle: String) { controller.injectConditionForTesting(id(bundle), .sourceDisappeared) }

  /// A full delivery that does not wait for the starts it begins (for a held prepare).
  func applyWithoutSettling(_ cards: [(String, Bool)]) {
    controller.apply(snapshot(power: true, cards), original: false)
  }

  /// Runs due scheduled work without waiting for the starts it begins (for a held prepare).
  func advanceWithoutSettling(to time: TimeInterval) async {
    await clock.advance(to: time) {}
  }

  func listChanged() async { events.processListChanged(); await settle() }
  func launched(_ bundle: String) async { events.launched(bundle); await settle() }
  func menuOpened() async { menuOpenedWithoutSettling(); await settle() }
  func menuOpenedWithoutSettling() {
    countForSwitchedOn { $0.menuOpens += 1 }
    Product.menuOpened(controller)
  }

  /// Every start waits on `startHold` before it enters the runtime; the hold only bites once armed.
  func installStartHold() {
    let hold = startHold
    Product.beforeStartEntersRuntime(controller) { _ in await hold.hold() }
  }

  func applyWithoutSettling(power: Bool, _ cards: [(String, Bool)]) {
    controller.apply(snapshot(power: power, cards), original: false)
  }

  /// A positions-only delivery that does not wait for held operations.
  func positionsWithoutSettling(power: Bool = true, _ cards: [(String, Bool)]) {
    _ = controller.updatePositions(snapshot(power: power, cards), original: false)
  }

  /// Lets queued main-actor work run without waiting for held operations.
  func drainQueued(_ times: Int = 50) async { for _ in 0..<times { await Task.yield() } }

  func state(_ bundle: String) -> String? { Product.laneState(controller, id(bundle)) }
  func owed(_ bundle: String) -> Bool { Product.owed(controller, id(bundle)) }
  func activity(_ bundle: String) -> Activity { Product.activity(controller, id(bundle)) }
  func attempts(_ bundle: String) -> Int { trace.attempts[bundle]?.count ?? 0 }
  func attemptTimes(_ bundle: String) -> [TimeInterval] { trace.attempts[bundle] ?? [] }
  func captureStarts(_ bundle: String) -> Int { trace.captureStarts[bundle] ?? 0 }
  var problem: String? { controller.problem }
  var compare: Bool { controller.compareAvailable }

  /// Every capture session that was made has been stopped, and no input-guard lease is held.
  func nothingStranded(_ bundle: String) -> Bool {
    (trace.sessionsMade[bundle] ?? 0) == (trace.stopped[bundle] ?? 0) && leases.activeLeaseCount == 0
  }

  func describe(_ bundle: String) -> String {
    "state=\(state(bundle) ?? "nil") activity=\(activity(bundle)) problem=\(problem ?? "nil") "
      + "attempts=\(attemptTimes(bundle)) captureStarts=\(captureStarts(bundle)) "
      + "sessions=\(trace.sessionsMade[bundle] ?? 0) stopped=\(trace.stopped[bundle] ?? 0) "
      + "leases=\(leases.activeLeaseCount) pending=\(clock.pendingDue) now=\(clock.now)"
  }

  /// Runs the end checks once, then shuts the controller down.
  func shutdown() async {
    if !checked { checked = true; RigAudit.fullyChecked += 1; await endChecks() }
    await controller.shutdown()
  }
  private var checked = false

  /// Shuts down in this turn: for a case where shutdown must begin before queued work runs. The at-rest
  /// check needs time to pass first, so it is skipped; the attempt bound is checked once shutdown is done.
  func shutdownNow() async {
    let first = !checked
    checked = true
    await controller.shutdown()
    if first {
      RigAudit.boundOnly += 1
      boundChecks()
    }
  }
}

/// End-check findings from every rig in the running case; the runner fails the case when any are left, and
/// says which rigs did not get every end check.
@MainActor enum RigAudit {
  static var problems: [String] = []
  /// Rigs made, rigs given every end check, and rigs given the attempt bound only (`shutdownNow`).
  static var made = 0, fullyChecked = 0, boundOnly = 0
  static func reset() { problems = []; made = 0; fullyChecked = 0; boundOnly = 0 }
}

/// Times are compared to a millisecond.
func sameTimes(_ a: [TimeInterval], _ b: [TimeInterval]) -> Bool {
  a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.001 }
}

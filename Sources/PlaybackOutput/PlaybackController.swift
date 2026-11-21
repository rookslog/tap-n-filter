import AppKit
import Capture
import Foundation
import PlaybackLifecycle
import PlaybackRuntime
import PlaybackRuntimeCaptureAdapters
import SoundModel

import struct PlaybackRuntime.AssignmentID

@MainActor
enum PlaybackSamplingScheduler {
  static func start(_ sample: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
      MainActor.assumeIsolated { sample() }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
  }
}

/// What a lane is doing, as far as the menu card's icon and accessibility value are concerned.
public enum PlaybackLaneActivity: Equatable, Sendable {
  /// The app's sound is running through TNF.
  case running
  /// The assignment is on and its app has no audio process yet (waiting state).
  case waiting
  /// Anything else: off, starting, stopping, or failed.
  case other
}

struct PlaybackSamplingNotifications {
  private struct Value: Equatable {
    let compareAvailable: Bool
    let problem: String?
    let activity: [UUID: PlaybackLaneActivity]
  }
  private var last: Value?
  mutating func shouldNotify(
    compareAvailable: Bool, problem: String?, activity: [UUID: PlaybackLaneActivity] = [:], force: Bool
  ) -> Bool {
    let next = Value(compareAvailable: compareAvailable, problem: problem, activity: activity)
    let notify = force || next != last
    last = next
    return notify
  }
}

@MainActor
private final class CaptureGeneration {
  var value: UInt64 = 0
  func advance() -> UInt64 {
    precondition(value < UInt64.max)
    value += 1
    return value
  }
}

@MainActor
private final class PlaybackSinkSlot {
  var value: NativePlaybackSink?
}

@MainActor
private final class PlaybackLane {
  /// The lane states of the event table (B): I idle, S starting, R running, T stopping, F failed.
  /// State A, "stopping with restart authorized", is `.stopping` while `PlaybackStopResumePolicy`
  /// still authorizes this assignment (`laneStateForTesting` names it).
  /// `waiting`: the assignment is on and its app has no audio process yet. Not a failure: `failure` stays nil.
  enum State { case idle, starting, running, stopping, failed, waiting }
  let factory: PlaybackCaptureFactory
  let runtime: PlaybackRuntime
  let generation: CaptureGeneration
  var state = State.idle
  var operation: UInt64 = 0
  var token: PlanToken?
  var sourcePID: Int32?
  /// The bundle this lane last started (or waits) for, so a changed assignment is noticed while waiting.
  var bundle: String?
  /// True while a start begun from `waiting` is in flight: compare ignores the lane, as it did while waiting.
  var wakeStart = false
  /// A wake-up arrived while a wake attempt was under way: one more attempt if it ends in waiting.
  var wakePending = false
  /// The list-change fold owes this lane an attempt: it was waiting when the fold was scheduled and has not
  /// been attempted since.
  var foldOwed = false
  let slot: PlaybackSinkSlot
  var sink: NativePlaybackSink? {
    get { slot.value }
    set { slot.value = newValue }
  }
  var failure: String?
  /// Cancels for the scheduled attempts of a launch burst (waiting state).
  var burst: [@MainActor () -> Void] = []
  func cancelBurst() {
    let pending = burst
    burst = []
    for cancel in pending { cancel() }
  }

  init(
    factory: PlaybackCaptureFactory, runtime: PlaybackRuntime, generation: CaptureGeneration,
    slot: PlaybackSinkSlot
  ) {
    self.factory = factory
    self.runtime = runtime
    self.generation = generation
    self.slot = slot
  }
}

@MainActor
public final class PlaybackController {
  private let coreAudio: (any CoreAudioInterface)?
  private let leases: InputGuardLeaseCoordinator?
  private let probeEnabled: Bool
  private let hub: NativeOutputHub
  private var testingLane: ((ListeningRenderAssignment, @escaping @MainActor (LifecycleObservation) -> Void) -> (PlaybackCaptureFactory, PlaybackRuntime))?
  private var lanes: [UUID: PlaybackLane] = [:]
  private var nextKey: UInt64 = 0
  private var desired: ListeningRenderSnapshot?
  private var stopResume = PlaybackStopResumePolicy()
  private var original = false
  private var visualizationRequest: VisualizationRequest?
  private var quitting = false
  private var timer: Timer?
  private var samplingNotifications = PlaybackSamplingNotifications()
  private var terminationObserver: NSObjectProtocol?
  /// Waiting-state wake-ups. Nil in checks that do not script them.
  private var wake: PlaybackWakeEnvironment?
  private var removeLaunchListener: (@MainActor () -> Void)?
  /// Installed only while at least one lane is waiting.
  private var removeListListener: (@MainActor () -> Void)?
  /// The number of the current list-listener registration; a handler from a retired one does nothing.
  private var listRegistration: UInt64 = 0
  private var currentListRegistration: UInt64?
  private var cancelListFold: (@MainActor () -> Void)?
  /// Attempts made to start a waiting lane by any wake-up (check seam).
  private(set) var wakeAttemptsForTesting = 0
  /// Check seam: consulted for a running lane that has no sink (a testing lane never fills its sink slot).
  var sinkReadyForTesting: ((UUID) -> Bool)?
  /// Check seam: awaited first in a lane start's task, before the quitting and operation check and the runtime.
  var beforeStartEntersRuntimeForTesting: ((UUID) async -> Void)?
  var startedForTesting: ((UUID, String) -> Void)?
  var stoppedForTesting: ((UUID, String) -> Void)?
  public var changed: () -> Void = {}
  /// A source quit or the output format changed under a running or starting lane: a real barrier for what
  /// the menu shows. Lane starts, stops and problems publish through `changed` only (A-LC).
  public var sourceOrFormatChanged: () -> Void = {}
  /// Test seams (M4, M7, M8, M9). Inert unless used.
  /// M7: awaited between a lane's runtime stop returning and its state change, so a stop can be held.
  var beforeStopCompletesForTesting: ((UUID) async -> Void)?
  private var operations = 0
  private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
  /// M8: returns once no lane start, stop or invalidation is pending.
  func quiescent() async {
    if operations == 0 { return }
    await withCheckedContinuation { quiescenceWaiters.append($0) }
  }
  private func operationBegan() { operations += 1 }
  private func operationEnded() {
    operations -= 1
    if operations == 0 { let waiters = quiescenceWaiters; quiescenceWaiters = []; for w in waiters { w.resume() } }
  }
  /// M9: the lane's state, as the table names it.
  func laneStateForTesting(_ id: UUID) -> String? {
    guard let lane = lanes[id] else { return nil }
    if lane.state == .stopping, let desired, let assignment = desired.assignments.first(where: { $0.id == id }),
      stopResume.isAuthorized(assignment, desired: desired) { return "stopping+restart" }
    return String(describing: lane.state)
  }
  /// M4: a source or route condition for one assignment's lane.
  func injectConditionForTesting(_ id: UUID, _ condition: CaptureCondition) {
    if let lane = lanes[id] { invalidate(id, lane: lane, condition: condition) }
  }
  public var log: (String) -> Void = { _ in }

  public init(coreAudio: any CoreAudioInterface, guardPort: any InputGuardPort) {
    self.coreAudio = coreAudio
    probeEnabled = false
    hub = NativeOutputHub()
    leases = InputGuardLeaseCoordinator(port: guardPort, settingEnabled: true)
    installObservers()
  }

  public init(
    coreAudio: any CoreAudioInterface, leases: InputGuardLeaseCoordinator,
    probeOutputEnabled: Bool = false
  ) {
    self.coreAudio = coreAudio
    self.leases = leases
    probeEnabled = probeOutputEnabled
    hub = NativeOutputHub(probeEnabled: probeOutputEnabled)
    hub.probeLog = { [weak self] value in self?.log(value) }
    installObservers()
  }

  /// Inert dependency seam for the real controller's asynchronous lifecycle checks.
  init(
    testingLane: @escaping (ListeningRenderAssignment, @escaping @MainActor (LifecycleObservation) -> Void) -> (PlaybackCaptureFactory, PlaybackRuntime),
    wake: PlaybackWakeEnvironment? = nil
  ) {
    self.wake = wake
    coreAudio = nil
    leases = nil
    probeEnabled = false
    hub = NativeOutputHub()
    self.testingLane = testingLane
    removeLaunchListener = wake?.listenForLaunches { [weak self] in self?.applicationLaunched($0) }
  }

  private func installObservers() {
    wake = PlaybackWakeEnvironment.system(log: { [weak self] in self?.log($0) })
    hub.configurationChanged = { [weak self] in self?.invalidateAll(.formatChanged) }
    terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
      else { return }
      let pid = app.processIdentifier
      Task { @MainActor [weak self] in self?.sourceTerminated(pid) }
    }
    timer = PlaybackSamplingScheduler.start { [weak self] in self?.sample() }
    removeLaunchListener = wake?.listenForLaunches { [weak self] in self?.applicationLaunched($0) }
  }

  public var problem: String? { lanes.values.compactMap(\.failure).sorted().first }
  public var guardLeaseCount: Int { leases?.activeLeaseCount ?? 0 }
  public var telemetry: [PlaybackTelemetry] {
    lanes.values.compactMap { $0.sink?.telemetry(state: String(describing: $0.state)) }
      .sorted { $0.assignment.uuidString < $1.assignment.uuidString }
  }

  private func isWaitingOrWaking(_ lane: PlaybackLane?) -> Bool {
    guard let lane else { return false }
    return lane.state == .waiting || (lane.state == .starting && lane.wakeStart)
  }

  public var compareAvailable: Bool {
    let active = lanes.filter { $0.value.state == .running }
    // Waiting apps have nothing to compare, so they are left out of the "everything is ready" test.
    let expected =
      desired?.isEnabled == true
      ? desired?.assignments.filter { $0.isEnabled && !isWaitingOrWaking(lanes[$0.id]) }.count ?? 0 : 0
    return expected > 0 && active.count == expected
      && active.allSatisfy { id, lane in
        if let sink = lane.sink { return sink.status().ready }
        return sinkReadyForTesting?(id) == true
      }
  }

  public func setVisualizationDemand(_ request: VisualizationRequest?) {
    visualizationRequest = request
    routeVisualizationDemand()
  }

  public func visualizationSnapshot(matching epoch: UInt64) -> VisualizationSnapshot {
    routeVisualizationDemand()
    guard desired?.isEnabled == true else { return .unavailable(.off) }
    let enabled = desired?.assignments.filter(\.isEnabled) ?? []
    guard enabled.count == 1, enabled[0].bundleIdentifier == "com.apple.Safari",
      let request = visualizationRequest, request.epoch == epoch, request.assignment == enabled[0].id
    else { return .unavailable(.unsupportedScope) }
    guard let lane = lanes[request.assignment], lane.state == .running else { return .unavailable(.starting) }
    return lane.sink?.visualizationSnapshot(epoch: epoch) ?? .unavailable(.warming)
  }

  private func routeVisualizationDemand() {
    let enabled = desired?.isEnabled == true ? desired?.assignments.filter(\.isEnabled) ?? [] : []
    for (id, lane) in lanes {
      let eligible = enabled.count == 1 && enabled[0].bundleIdentifier == "com.apple.Safari"
        && enabled[0].id == id && lane.state == .running && visualizationRequest?.assignment == id
      lane.sink?.setVisualizationDemand(eligible ? visualizationRequest : nil)
    }
  }

  public func apply(_ snapshot: ListeningSnapshot, original: Bool) {
    apply(ListeningRenderSnapshot(legacy: snapshot), original: original)
  }

  @discardableResult
  public func updatePositions(_ snapshot: ListeningRenderSnapshot, original: Bool) -> PositionDeliveryResult {
    guard !quitting else { return .closed }
    let previous = desired
    desired = snapshot
    stopResume.withdraw(snapshot)
    settleWaitingLanes(for: snapshot)
    let original = original && compareAvailable
    self.original = original
    let known = Dictionary(uniqueKeysWithValues: (previous?.assignments ?? []).map { ($0.id, $0.bundleIdentifier) })
    let plan = PlaybackPositionDelivery(snapshot: snapshot,
      running: Set(lanes.filter { $0.value.state == .running }.map(\.key)),
      starting: Set(lanes.filter { $0.value.state == .starting }.map(\.key)), known: known)
    return plan.apply(update: { [self] assignment in
      guard let lane = lanes[assignment.id] else { return }
      do { try lane.factory.update(assignment, original: original) }
      catch { lane.failure = "The sound change could not be applied. \(error)"; throw error }
    }, stop: { [self] id in
      if let lane = lanes[id] { stop(id, lane: lane) }
    })
  }

  public func apply(_ snapshot: ListeningRenderSnapshot, original: Bool) {
    guard !quitting else { return }
    stopResume.activate(snapshot)
    applyDesired(snapshot, original: original)
  }

  /// `authorizedOnly`: a retry may start only what the latest activation authorized (B-F10).
  private func applyDesired(_ snapshot: ListeningRenderSnapshot, original: Bool, authorizedOnly: Bool = false) {
    guard !quitting else { return }
    desired = snapshot
    let original = original && compareAvailable
    self.original = original
    let present = Set(snapshot.assignments.map(\.id))
    for (id, lane) in lanes where !present.contains(id) { stop(id, lane: lane, removing: true, includesCurrentActivation: true) }
    for assignment in snapshot.assignments {
      let lane = lanes[assignment.id] ?? makeLane(assignment)
      lanes[assignment.id] = lane
      if lane.state == .waiting, lane.bundle != assignment.bundleIdentifier {
        lane.cancelBurst()
        lane.state = .idle
      }
      do { try lane.factory.update(assignment, original: original) } catch {
        lane.failure = "The sound change could not be applied. \(error)"
        stop(assignment.id, lane: lane, includesCurrentActivation: true)
        continue
      }
      if !snapshot.isEnabled || !assignment.isEnabled {
        if lane.state == .failed || lane.state == .waiting {
          lane.failure = nil
          lane.state = .idle
        }
        lane.cancelBurst()
        stop(assignment.id, lane: lane, includesCurrentActivation: true)
      } else if lane.state == .idle, !authorizedOnly || stopResume.isAuthorized(assignment, desired: snapshot) {
        start(assignment, lane: lane)
      }
    }
    publishChange()
  }

  public func retry() {
    guard let desired else { return }
    for lane in lanes.values where lane.state == .failed {
      lane.failure = nil
      lane.state = .idle
    }
    applyDesired(desired, original: original, authorizedOnly: true)
  }

  public func shutdown() async {
    quitting = true
    setVisualizationDemand(nil)
    timer?.invalidate()
    timer = nil
    if let terminationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
    }
    self.terminationObserver = nil
    removeLaunchListener?()
    removeLaunchListener = nil
    removeListListener?()
    removeListListener = nil
    currentListRegistration = nil
    cancelFold()
    for lane in lanes.values { lane.cancelBurst() }
    for (id, lane) in lanes {
      lane.operation += 1
      _ = await lane.runtime.stop(AssignmentID(id))
      lane.sink = nil
    }
    lanes.removeAll()
  }

  private func makeLane(_ assignment: ListeningRenderAssignment) -> PlaybackLane {
    if let testingLane {
      let (factory, runtime) = testingLane(assignment) { [weak self] in self?.observed($0) }
      return PlaybackLane(factory: factory, runtime: runtime, generation: CaptureGeneration(), slot: PlaybackSinkSlot())
    }
    guard let coreAudio, let leases else { preconditionFailure("Playback dependencies are required") }
    precondition(nextKey < UInt64.max)
    nextKey += 1
    let key = nextKey
    let generation = CaptureGeneration()
    let slot = PlaybackSinkSlot()
    let diagnosticEnabled = probeEnabled
    let factory = PlaybackCaptureFactory(
      inner: TapCaptureSessionFactory(coreAudio: coreAudio), assignment: assignment
    ) {
      [hub, diagnosticEnabled] assignment, original in
      let sink = NativePlaybackSink(
        hub: hub, assignment: assignment, original: original, key: key, epoch: generation.value,
        probeEnabled: diagnosticEnabled)
      slot.value = sink
      return sink
    }
    let runtime = PlaybackRuntime(
      resolver: BundleProcessResolver(catalog: SystemProcessCatalog(coreAudio: coreAudio)),
      factory: factory, leases: leases
    ) { [weak self] observation in
      self?.observed(observation)
    }
    return PlaybackLane(factory: factory, runtime: runtime, generation: generation, slot: slot)
  }

  /// `wake`: the start is an attempt from `waiting`; the lane keeps reading as waiting while it is under way.
  private func start(_ assignment: ListeningRenderAssignment, lane: PlaybackLane, wake: Bool = false) {
    let epoch = lane.generation.advance()
    lane.operation += 1
    let operation = lane.operation
    let token = PlanToken(intent: epoch, source: epoch, format: epoch)
    lane.token = token
    lane.bundle = assignment.bundleIdentifier
    lane.wakeStart = wake
    lane.wakePending = false
    lane.state = .starting
    lane.failure = nil
    let request = StartRequest(
      assignment: AssignmentID(assignment.id),
      binding: try! AppBinding(bundleIdentifier: assignment.bundleIdentifier), token: token)
    operationBegan()
    Task { @MainActor [weak self, weak lane] in
      guard let self else { return }
      defer { self.operationEnded() }
      guard let lane else { return }
      await self.beforeStartEntersRuntimeForTesting?(assignment.id)
      // A stop, switch-off or shutdown can have come in while this task was queued: do not enter the runtime.
      guard !self.quitting, lane.operation == operation else { return }
      let result = await lane.runtime.start(request)
      guard lane.operation == operation else { return }
      let wasWake = lane.wakeStart
      lane.wakeStart = false
      let retryWake = lane.wakePending
      lane.wakePending = false
      switch result.event {
      case .running:
        lane.state = .running
        if let desired = self.desired { _ = self.updatePositions(desired, original: self.original) }
      case .failed(.source(let source), _, _)
      where !self.probeEnabled && (source == .disappeared || source == .replaced):
        // No audio process for the app (the app is closed, or open with nothing playing), or the process was
        // replaced by a relaunch: waiting, not a failure. A relaunch also starts the launch burst.
        // Teardown and lease release already happened inside the runtime's failure path.
        lane.state = .waiting
        lane.failure = nil
        lane.sourcePID = nil
        lane.sink = nil  // the runtime has stopped the output; do not hold it while waiting
        if source == .replaced { self.startBurst(assignment.id, lane: lane) }
      case .failed(let error, _, _):
        lane.state = .failed
        lane.failure = self.message(error)
      case .refused(let reason):
        lane.state = .failed
        lane.failure = "Playback was refused. \(reason)"
      default: lane.state = .idle
      }
      self.startedForTesting?(assignment.id, String(describing: lane.state))
      // An attempt from waiting that ends in waiting changed nothing a person can see: publish nothing.
      if !(wasWake && lane.state == .waiting) { self.publishChange() }
      if retryWake, lane.state == .waiting { self.attemptWaiting(assignment.id, lane: lane) }
    }
  }

  private func stop(_ id: UUID, lane: PlaybackLane, removing: Bool = false, includesCurrentActivation: Bool = false) {
    guard lane.state == .starting || lane.state == .running else {
      if removing, lane.state != .stopping {
        lane.cancelBurst()
        lanes.removeValue(forKey: id)
      }
      return
    }
    lane.cancelBurst()
    lane.operation += 1
    let operation = lane.operation
    let authorization = stopResume.stopping(assignment: id, includesCurrentActivation: includesCurrentActivation)
    lane.state = .stopping
    operationBegan()
    Task { @MainActor [weak self, weak lane] in
      guard let self else { return }
      defer { self.operationEnded() }
      guard let lane else { return }
      _ = await lane.runtime.stop(AssignmentID(id))
      await self.beforeStopCompletesForTesting?(id)
      guard lane.operation == operation else { return }
      lane.sink = nil
      lane.state = lane.failure == nil ? .idle : .failed
      if removing { self.lanes.removeValue(forKey: id) }
      if !self.quitting, let desired = self.desired, self.stopResume.mayResume(authorization, desired: desired),
         lane.state == .idle, let assignment = desired.assignments.first(where: { $0.id == id }) {
        self.lanes[id] = lane
        do {
          try lane.factory.update(assignment, original: self.original)
          self.start(assignment, lane: lane)
        } catch {
          lane.state = .failed
          lane.failure = "The sound change could not be applied. \(error)"
        }
      }
      self.stoppedForTesting?(id, String(describing: lane.state))
    }
  }

  private func observed(_ observation: LifecycleObservation) {
    if probeEnabled {
      logProbe(observation)
    } else {
      log("capture \(observation.assignment.rawValue) \(observation.event)")
    }
    guard let lane = lanes[observation.assignment.rawValue] else { return }
    if case .resolved(let source) = observation.event { lane.sourcePID = source.pid }
  }

  private func logProbe(_ observation: LifecycleObservation) {
    var record: [String: Any] = ["assignment": observation.assignment.rawValue.uuidString]
    if let token = observation.token {
      record["intent"] = token.intent; record["sourceEpoch"] = token.source
      record["formatEpoch"] = token.format
    }
    switch observation.event {
    case .resolved(let process):
      record["event"] = "resolved"; record["pid"] = process.pid
      record["audioProcessID"] = process.audioProcessID
      if let instance = process.instanceIdentifier { record["instanceIdentifier"] = instance }
    case .prepared(let format):
      record["event"] = "prepared"; record["sampleRate"] = format.sampleRate
      record["channels"] = format.channels
    case .running(let format):
      record["event"] = "running"; record["sampleRate"] = format.sampleRate
      record["channels"] = format.channels
      log("PROBE_RUNNING")
    case .guardReady(let acquisition):
      record["event"] = "guard-ready"; record["shared"] = acquisition.shared
      record["recovery"] = String(describing: acquisition.recovery)
      if case .engaged = acquisition.engagement {
        record["engaged"] = true
      } else {
        record["engaged"] = false
      }
    case .stopped(_, let teardown, let release):
      record["event"] = "stopped"
      if let teardown {
        if case .completed = teardown {
          record["teardownCompleted"] = true
        } else {
          record["teardownCompleted"] = false
        }
      }
      // LeaseRelease/GuardRestoration carry no UID or arbitrary error text.
      if let release { record["release"] = String(describing: release) }
    case .failed(let failure, let teardown, let release):
      record["event"] = "failed"
      if let teardown {
        if case .completed = teardown {
          record["teardownCompleted"] = true
        } else {
          record["teardownCompleted"] = false
        }
      }
      if let release { record["release"] = String(describing: release) }
      switch failure {
      case .invalidFormat: record["category"] = "invalid-format"
      case .formatMismatch: record["category"] = "format-mismatch"
      case .source: record["category"] = "source-resolution"
      case .prepare: record["category"] = "prepare"
      case .start: record["category"] = "start"
      }
    default: return
    }
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    {
      log("PROBE_LIFECYCLE " + text)
    }
  }

  private func sourceTerminated(_ pid: Int32) {
    for (id, lane) in lanes where lane.sourcePID == pid {
      invalidate(id, lane: lane, condition: .sourceDisappeared)
    }
  }

  private func invalidateAll(_ condition: CaptureCondition) {
    for (id, lane) in lanes { invalidate(id, lane: lane, condition: condition) }
  }

  private func invalidate(_ id: UUID, lane: PlaybackLane, condition: CaptureCondition) {
    guard lane.state == .running || lane.state == .starting, let token = lane.token else { return }
    original = false
    if let desired {
      for assignment in desired.assignments {
        try? lanes[assignment.id]?.factory.update(assignment, original: false)
      }
    }
    lane.cancelBurst()
    // A wake attempt still starting when its app quits goes back to waiting, as a vanish at revalidation does.
    let wasWake = lane.state == .starting && lane.wakeStart
    lane.wakeStart = false
    lane.wakePending = false
    lane.operation += 1
    let operation = lane.operation
    lane.state = .stopping
    sourceOrFormatChanged()
    operationBegan()
    Task { @MainActor [weak self, weak lane] in
      guard let self else { return }
      defer { self.operationEnded() }
      guard let lane else { return }
      _ = await lane.runtime.report(condition: condition, for: AssignmentID(id), matching: token)
      guard operation == lane.operation else { return }
      lane.sink = nil
      if wasWake, condition == .sourceDisappeared, !self.probeEnabled {
        lane.state = .waiting
        lane.sourcePID = nil
        self.publishChange()
        return
      }
      lane.state = .failed
      lane.failure =
        condition == .sourceDisappeared ? "The source app closed." : "The audio route changed."
      self.publishChange()
    }
  }

  private func sample() {
    for (id, lane) in lanes where lane.state == .running {
      lane.sink?.checkpoint()
      if let failure = lane.sink?.status().failure {
        lane.failure = failure
        stop(id, lane: lane)
      }
    }
    publishChange(sampleOnly: true)
  }

  private func publishChange(sampleOnly: Bool = false) {
    if !sampleOnly { reconcileWakeListener() }
    if samplingNotifications.shouldNotify(
      compareAvailable: compareAvailable, problem: problem, activity: laneActivities, force: !sampleOnly)
    {
      changed()
    }
  }

  /// The activity of each lane, keyed by assignment id, for the menu card.
  public var laneActivities: [UUID: PlaybackLaneActivity] {
    lanes.mapValues { lane -> PlaybackLaneActivity in
      if isWaitingOrWaking(lane) { return .waiting }
      return lane.state == .running ? .running : .other
    }
  }

  // MARK: Waiting state

  /// A lane a wake-up is for: waiting, or being started from waiting.
  private var anyLaneWaiting: Bool { lanes.values.contains { isWaitingOrWaking($0) } }

  /// Keeps the audio-process-list listener installed exactly while a lane is waiting.
  private func reconcileWakeListener() {
    guard !quitting else { return }
    // A lane that has moved on (running, failed, idle, stopping) leaves nothing scheduled behind.
    for lane in lanes.values where !lane.burst.isEmpty && lane.state != .waiting && lane.state != .starting {
      lane.cancelBurst()
    }
    guard let wake else { return }
    if anyLaneWaiting {
      if removeListListener == nil {
        listRegistration += 1
        let registration = listRegistration
        currentListRegistration = registration
        removeListListener = wake.listenForProcessListChanges { [weak self] in
          self?.processListChanged(registration: registration)
        }
        // Subscribe, then look once: the audio process may have appeared between the failed read and now.
        attemptAllWaiting()
      }
    } else {
      removeListListener?()
      removeListListener = nil
      currentListRegistration = nil
      cancelFold()
    }
  }

  private func cancelFold() {
    cancelListFold?()
    cancelListFold = nil
    for lane in lanes.values { lane.foldOwed = false }
  }

  /// One attempt per change, with changes inside the fold window folded into one.
  private func processListChanged(registration: UInt64) {
    guard registration == currentListRegistration, removeListListener != nil else { return }
    guard !quitting, anyLaneWaiting, let wake else { return }
    // A change during an attempt is remembered for that lane and does not join a fold.
    for lane in lanes.values where lane.state == .starting && lane.wakeStart { lane.wakePending = true }
    guard lanes.values.contains(where: { $0.state == .waiting }), cancelListFold == nil else { return }
    for lane in lanes.values where lane.state == .waiting { lane.foldOwed = true }
    cancelListFold = wake.schedule(PlaybackWakeSchedule.listFold) { [weak self] in
      guard let self else { return }
      self.cancelListFold = nil
      // Only lanes owed an attempt: one that was woken since, or began waiting later, is not swept again.
      for (id, lane) in self.lanes where lane.foldOwed {
        lane.foldOwed = false
        if lane.state == .waiting { self.attemptWaiting(id, lane: lane) }
      }
    }
  }

  /// A launch of a waiting lane's app starts a bounded burst of attempts.
  private func applicationLaunched(_ bundle: String) {
    guard !quitting, anyLaneWaiting, let desired else { return }
    for assignment in desired.assignments where assignment.bundleIdentifier == bundle {
      guard let lane = lanes[assignment.id], isWaitingOrWaking(lane) else { continue }
      startBurst(assignment.id, lane: lane)
      if lane.state == .starting { lane.wakePending = true }
    }
  }

  /// Attempts at `PlaybackWakeSchedule.launchBurst` seconds from now; the first success ends it.
  private func startBurst(_ id: UUID, lane: PlaybackLane) {
    guard let wake else { return }
    lane.cancelBurst()
    for delay in PlaybackWakeSchedule.launchBurst {
      lane.burst.append(
        wake.schedule(delay) { [weak self, weak lane] in
          guard let self, let lane else { return }
          switch lane.state {
          case .waiting: self.attemptWaiting(id, lane: lane)
          case .starting: if lane.wakeStart { lane.wakePending = true }
          case .stopping: break
          default: lane.cancelBurst()  // running or otherwise moved on: the burst ends
          }
        })
    }
  }

  /// A positions-only delivery can switch an app or the whole thing off without a full apply; a waiting lane
  /// then goes idle so it stops waiting and no later wake-up starts it.
  private func settleWaitingLanes(for snapshot: ListeningRenderSnapshot) {
    var settled = false
    for (id, lane) in lanes where lane.state == .waiting {
      if snapshot.isEnabled, snapshot.assignments.first(where: { $0.id == id })?.isEnabled == true { continue }
      lane.cancelBurst()
      lane.state = .idle
      settled = true
    }
    // Not `publishChange()`: this runs inside a control-rate delivery. The listener and any pending work are
    // released here; the menu catches up at the next ordinary publish.
    if settled { reconcileWakeListener() }
  }

  /// Opening the menu is the manual retry: one attempt for each waiting lane.
  public func menuOpened() { attemptAllWaiting() }

  private func attemptAllWaiting() {
    guard !quitting, anyLaneWaiting else { return }
    for (id, lane) in lanes {
      if lane.state == .waiting { attemptWaiting(id, lane: lane) }
      else if lane.state == .starting, lane.wakeStart { lane.wakePending = true }
    }
  }

  private func attemptWaiting(_ id: UUID, lane: PlaybackLane) {
    guard !quitting, lanes[id] === lane, lane.state == .waiting, let desired, desired.isEnabled,
      let assignment = desired.assignments.first(where: { $0.id == id }), assignment.isEnabled,
      stopResume.isAuthorized(assignment, desired: desired)
    else { return }
    wakeAttemptsForTesting += 1
    lane.foldOwed = false
    do { try lane.factory.update(assignment, original: original) } catch {
      lane.state = .failed
      lane.failure = "The sound change could not be applied. \(error)"
      publishChange()
      return
    }
    start(assignment, lane: lane, wake: true)
  }

  private func message(_ failure: RuntimeFailure) -> String {
    switch failure {
    case .source(.disappeared): "The source app is not available."
    case .source(.ambiguousSameBundle): "More than one audio process matches this app."
    default: "TNF could not start this app's audio. \(failure)"
    }
  }
}

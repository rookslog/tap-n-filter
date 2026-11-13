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

struct PlaybackSamplingNotifications {
  private struct Value: Equatable {
    let compareAvailable: Bool
    let problem: String?
  }
  private var last: Value?
  mutating func shouldNotify(compareAvailable: Bool, problem: String?, force: Bool) -> Bool {
    let next = Value(compareAvailable: compareAvailable, problem: problem)
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
  enum State { case idle, starting, running, stopping, failed }
  let factory: PlaybackCaptureFactory
  let runtime: PlaybackRuntime
  let generation: CaptureGeneration
  var state = State.idle
  var operation: UInt64 = 0
  var token: PlanToken?
  var sourcePID: Int32?
  let slot: PlaybackSinkSlot
  var sink: NativePlaybackSink? {
    get { slot.value }
    set { slot.value = newValue }
  }
  var failure: String?

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
  var startedForTesting: ((UUID, String) -> Void)?
  var stoppedForTesting: ((UUID, String) -> Void)?
  public var changed: () -> Void = {}
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
  init(testingLane: @escaping (ListeningRenderAssignment, @escaping @MainActor (LifecycleObservation) -> Void) -> (PlaybackCaptureFactory, PlaybackRuntime)) {
    coreAudio = nil
    leases = nil
    probeEnabled = false
    hub = NativeOutputHub()
    self.testingLane = testingLane
  }

  private func installObservers() {
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
  }

  public var problem: String? { lanes.values.compactMap(\.failure).sorted().first }
  public var guardLeaseCount: Int { leases?.activeLeaseCount ?? 0 }
  public var telemetry: [PlaybackTelemetry] {
    lanes.values.compactMap { $0.sink?.telemetry(state: String(describing: $0.state)) }
      .sorted { $0.assignment.uuidString < $1.assignment.uuidString }
  }

  public var compareAvailable: Bool {
    let active = lanes.values.filter { $0.state == .running }
    let expected =
      desired?.isEnabled == true ? desired?.assignments.filter(\.isEnabled).count ?? 0 : 0
    return expected > 0 && active.count == expected
      && active.allSatisfy { $0.sink?.status().ready == true }
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

  private func applyDesired(_ snapshot: ListeningRenderSnapshot, original: Bool) {
    guard !quitting else { return }
    desired = snapshot
    let original = original && compareAvailable
    self.original = original
    let present = Set(snapshot.assignments.map(\.id))
    for (id, lane) in lanes where !present.contains(id) { stop(id, lane: lane, removing: true, includesCurrentActivation: true) }
    for assignment in snapshot.assignments {
      let lane = lanes[assignment.id] ?? makeLane(assignment)
      lanes[assignment.id] = lane
      do { try lane.factory.update(assignment, original: original) } catch {
        lane.failure = "The sound change could not be applied. \(error)"
        stop(assignment.id, lane: lane, includesCurrentActivation: true)
        continue
      }
      if !snapshot.isEnabled || !assignment.isEnabled {
        if lane.state == .failed {
          lane.failure = nil
          lane.state = .idle
        }
        stop(assignment.id, lane: lane, includesCurrentActivation: true)
      } else if lane.state == .idle {
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
    apply(desired, original: original)
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

  private func start(_ assignment: ListeningRenderAssignment, lane: PlaybackLane) {
    let epoch = lane.generation.advance()
    lane.operation += 1
    let operation = lane.operation
    let token = PlanToken(intent: epoch, source: epoch, format: epoch)
    lane.token = token
    lane.state = .starting
    lane.failure = nil
    let request = StartRequest(
      assignment: AssignmentID(assignment.id),
      binding: try! AppBinding(bundleIdentifier: assignment.bundleIdentifier), token: token)
    Task { @MainActor [weak self, weak lane] in
      guard let self, let lane else { return }
      let result = await lane.runtime.start(request)
      guard lane.operation == operation else { return }
      switch result.event {
      case .running:
        lane.state = .running
        if let desired = self.desired { _ = self.updatePositions(desired, original: self.original) }
      case .failed(let error, _, _):
        lane.state = .failed
        lane.failure = self.message(error)
      case .refused(let reason):
        lane.state = .failed
        lane.failure = "Playback was refused. \(reason)"
      default: lane.state = .idle
      }
      self.startedForTesting?(assignment.id, String(describing: lane.state))
      self.publishChange()
    }
  }

  private func stop(_ id: UUID, lane: PlaybackLane, removing: Bool = false, includesCurrentActivation: Bool = false) {
    guard lane.state == .starting || lane.state == .running else {
      if removing, lane.state != .stopping { lanes.removeValue(forKey: id) }
      return
    }
    lane.operation += 1
    let operation = lane.operation
    let authorization = stopResume.stopping(assignment: id, includesCurrentActivation: includesCurrentActivation)
    lane.state = .stopping
    Task { @MainActor [weak self, weak lane] in
      guard let self, let lane else { return }
      _ = await lane.runtime.stop(AssignmentID(id))
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
    lane.operation += 1
    let operation = lane.operation
    lane.state = .stopping
    Task { @MainActor [weak self, weak lane] in
      guard let self, let lane else { return }
      _ = await lane.runtime.report(condition: condition, for: AssignmentID(id), matching: token)
      guard operation == lane.operation else { return }
      lane.sink = nil
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
    if samplingNotifications.shouldNotify(compareAvailable: compareAvailable, problem: problem, force: !sampleOnly) {
      changed()
    }
  }

  private func message(_ failure: RuntimeFailure) -> String {
    switch failure {
    case .source(.disappeared): "The source app is not available."
    case .source(.ambiguousSameBundle): "More than one audio process matches this app."
    default: "TNF could not start this app's audio. \(failure)"
    }
  }
}

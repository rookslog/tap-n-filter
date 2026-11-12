import Foundation
import PlaybackDSP
import PlaybackLifecycle
import PlaybackRenderBridge
import PlaybackRuntime
import PlaybackRuntimeCaptureAdapters
import SoundModel

@MainActor
final class NativePlaybackSink: PlaybackSink {
  private enum State { case fresh, preparing, prepared, stopped }
  private var state = State.fresh
  private let hub: NativeOutputHub
  private let key: UInt64
  private let epoch: UInt64
  private var assignment: ListeningRenderAssignment
  private var original: Bool
  private var intent: UInt64 = 1
  private var owner: PlaybackRenderOwner?
  private var output: NativeOutputLease?
  private let probe: ProbeDSPCheckpoints?
  private var visualization: VisualizationCapture?
  private var probeIdentity: RawRingProbeIdentity?

  init(
    hub: NativeOutputHub, assignment: ListeningRenderAssignment, original: Bool, key: UInt64,
    epoch: UInt64, probeEnabled: Bool = false
  ) {
    self.hub = hub
    self.assignment = assignment
    self.original = original
    self.key = key
    self.epoch = epoch
    probe = probeEnabled ? ProbeDSPCheckpoints() : nil
  }

  func prepare(_ capture: CapturePreparation) async throws {
    guard state == .fresh, let resource = capture.resource as? TapCaptureResource else {
      throw OutputError.invalidFormat
    }
    state = .preparing
    let format = try RenderProcessingFormat(
      sampleRate: capture.format.sampleRate,
      channels: capture.format.channels, maximumFrames: 4096)
    let owner = try PlaybackRenderOwner(
      assignment: assignment, numericAssignmentKey: key,
      sourceEpoch: epoch, formatEpoch: epoch, format: format, intent: intent)
    if assignment.bundleIdentifier == "com.apple.Safari" {
      visualization = VisualizationCapture.create(assignment: assignment.id, rate: capture.format.sampleRate, channels: capture.format.channels,
        numericAssignment: key, sourceEpoch: epoch, formatEpoch: epoch)
    }
    self.owner = owner
    owner.setOriginalRequested(original)
    await owner.waitUntilIdle()
    try Task.checkCancellation()
    guard let receipt = owner.lastPreparation, receipt.published,
      receipt.token.topology == owner.desiredToken.topology
    else {
      throw OutputError.invalidCallback
    }
    let identity = RawRingProbeIdentity(
      assignment: assignment.id, numericAssignment: key, sourceEpoch: epoch, formatEpoch: epoch,
      sampleRate: capture.format.sampleRate, channels: capture.format.channels)
    if probe != nil { probeIdentity = identity }
    probe?.record(owner.telemetry(), phase: "prepared")
    let output = try await hub.attach(
      resource: resource, callback: owner.nativeCallback, probeIdentity: probeIdentity, visualization: visualization)
    self.output = output
    try Task.checkCancellation()
    state = .prepared
  }

  func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {
    if state != .stopped, assignment != self.assignment, let owner {
      guard intent < UInt64.max else { throw OutputError.invalidCallback }
      intent += 1
      _ = try owner.update(assignment, intent: intent, sourceEpoch: epoch, formatEpoch: epoch)
    }
    self.assignment = assignment
    self.original = original
    if state != .stopped { owner?.setOriginalRequested(original) }
  }

  func start() throws {
    guard state == .prepared else { throw OutputError.invalidCallback }
    try hub.start()
    checkpoint(phase: "running")
  }

  func stop() async {
    guard state != .stopped else { return }
    state = .stopped
    visualization?.setDemand(nil)
    checkpoint(phase: "stopping")
    if let output {
      await hub.remove(output)
      self.output = nil
    }
    checkpoint(phase: "retired")
    if let owner {
      // remove has disabled the borrowed callback and waited for its users.
      // If attach never happened, no consumer ever borrowed this owner.
      try! await owner.close(consumerQuiesced: true)
      self.owner = nil
    }
    if let probe, let probeIdentity { hub.probeLog(probe.json(identity: probeIdentity)) }
  }

  func setVisualizationDemand(_ request: VisualizationRequest?) { visualization?.setDemand(request) }

  func visualizationSnapshot(epoch: UInt64) -> VisualizationSnapshot {
    visualization?.snapshot(epoch: epoch) ?? .unavailable(.invalid)
  }

  func checkpoint(phase: String = "sample") {
    if let probe, let owner { probe.record(owner.telemetry(), phase: phase) }
  }

  func status() -> (ready: Bool, failure: String?) {
    guard state == .prepared, let owner else { return (false, nil) }
    if let output, output.context.telemetry().errors > 0 {
      return (false, "The output callback received an unsupported audio buffer.")
    }
    owner.collect()
    let stats = owner.telemetry()
    if stats.last_result != FR_OK.rawValue || stats.native_status != 0 {
      return (false, "Audio processing stopped (\(stats.last_result), \(stats.native_status)).")
    }
    if !owner.preparationPending, let receipt = owner.lastPreparation,
      !receipt.published, receipt.token.topology == owner.desiredToken.topology
    {
      return (false, "The sound change could not be prepared (\(receipt.nativeStatus)).")
    }
    return (stats.compare_ready != 0, nil)
  }

  func telemetry(state: String) -> PlaybackTelemetry {
    let native = owner?.telemetry()
    let output = output?.context.telemetry()
    return PlaybackTelemetry(
      assignment: assignment.id, state: state,
      capturedFrames: output?.captured_frames ?? 0,
      outputCallbacks: output?.callbacks ?? 0,
      nonSilentMeasuredFrames: native?.measured_frames ?? 0,
      underruns: output?.underruns ?? 0,
      errors: (output?.errors ?? 0) + (native?.errors ?? 0),
      appliedIntent: native?.frame_intent ?? 0,
      nativeStatus: native?.native_status ?? 0)
  }
}

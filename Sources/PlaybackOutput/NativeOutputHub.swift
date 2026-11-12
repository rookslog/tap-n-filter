import AVFoundation
import Capture
import OutputGate
import PlaybackDSP
import PlaybackRuntimeCaptureAdapters

@MainActor
final class NativeOutputLease {
  let id = UUID()
  let node: AVAudioSourceNode
  let context: NativeOutputContext

  init(node: AVAudioSourceNode, context: NativeOutputContext) {
    self.node = node
    self.context = context
  }
}

// One output clock/mix/final limiter for every assignment. Constructed lazily
// during guarded prepare, never by menu discovery or ordinary model changes.
@MainActor
final class NativeOutputHub {
  private var engine: AVAudioEngine?
  private var limiter: AVAudioUnitEffect?
  private var leases: [UUID: NativeOutputLease] = [:]
  private var configurationObserver: NSObjectProtocol?
  private var hasStarted = false
  private let probeEnabled: Bool
  private var probeEpoch: UInt64 = 0
  private var probeMeter: ProbeOutputMeter?
  var probeLog: (String) -> Void = { _ in }
  init(probeEnabled: Bool = false) { self.probeEnabled = probeEnabled }
  var configurationChanged: () -> Void = {}

  func attach(
    resource: TapCaptureResource, callback: PDCallback,
    probeIdentity: RawRingProbeIdentity? = nil, visualization: VisualizationCapture? = nil
  ) async throws -> NativeOutputLease {
    let engine = try prepareEngine()
    let context: NativeOutputContext
    do {
      context = try NativeOutputContext(
        ring: resource.ring, callback: callback, probeIdentity: probeEnabled ? probeIdentity : nil,
        visualization: visualization, visualizationRate: resource.format.sampleRate)
    } catch {
      await tearDownIfEmpty()
      throw error
    }
    let node = AVAudioSourceNode(format: resource.format) { silence, _, frames, buffers in
      context.render(silence: silence, frames: frames, buffers: buffers)
    }
    engine.attach(node)
    do {
      try connect(
        engine, node, engine.mainMixerNode, bus: engine.mainMixerNode.nextAvailableInputBus,
        format: resource.format)
      let lease = NativeOutputLease(node: node, context: context)
      leases[lease.id] = lease
      return lease
    } catch {
      og_disable(context.gate)
      engine.detach(node)
      await context.drain()
      if let receipt = context.rawProbeReceipt() { probeLog(receipt) }
      await tearDownIfEmpty()
      throw error
    }
  }

  func start() throws {
    guard let engine else { throw OutputError.invalidCallback }
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
      hasStarted = true
    }
  }

  func remove(_ lease: NativeOutputLease) async {
    og_disable(lease.context.gate)
    if leases.removeValue(forKey: lease.id) != nil, let engine {
      engine.detach(lease.node)
      await tearDownIfEmpty()
    }
    await lease.context.drain()
    if let receipt = lease.context.rawProbeReceipt() { probeLog(receipt) }
  }

  private func tearDownIfEmpty() async {
    guard leases.isEmpty else { return }
    hasStarted = false
    let retiredMeter = probeMeter
    var retiredEngine = engine
    retiredMeter?.close()
    if retiredMeter != nil { limiter?.removeTap(onBus: 0) }
    retiredEngine?.stop()
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    probeMeter = nil
    limiter = nil
    engine = nil
    retiredEngine = nil
    if let retiredMeter {
      await retiredMeter.drain()
      probeLog(retiredMeter.json())
    }
  }

  private func connect(
    _ engine: AVAudioEngine, _ source: AVAudioNode, _ destination: AVAudioNode,
    bus: AVAudioNodeBus = 0, format: AVAudioFormat?
  ) throws {
    if #available(macOS 27, *) {
      try engine.connectNode(source, to: destination, fromBus: 0, toBus: bus, format: format)
    } else {
      engine.connect(source, to: destination, fromBus: 0, toBus: bus, format: format)
    }
  }

  private func prepareEngine() throws -> AVAudioEngine {
    if let engine { return engine }
    let engine = AVAudioEngine()
    let limiter = try FinalMixLimiter.make()
    engine.attach(limiter)
    do {
      try connect(engine, engine.mainMixerNode, limiter, format: nil)
      try connect(engine, limiter, engine.outputNode, format: nil)
    } catch {
      engine.stop()
      throw error
    }
    if probeEnabled {
      probeEpoch += 1
      let meter = try ProbeOutputMeter(epoch: probeEpoch, format: limiter.outputFormat(forBus: 0))
      meter.install(on: limiter)
      probeMeter = meter
    }
    self.engine = engine
    self.limiter = limiter
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasStarted else { return }
        self.configurationChanged()
      }
    }
    return engine
  }
}

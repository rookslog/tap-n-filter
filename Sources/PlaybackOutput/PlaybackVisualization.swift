import Accelerate
import Darwin
import Foundation
import OutputGate

public enum VisualizationMode: Int, CaseIterable, Sendable { case waveform, spectrum, levels }
public enum VisualizationUnavailable: Sendable { case off, unsupportedScope, starting, warming, stale, gap, invalid }
public struct VisualizationRequest: Equatable, Sendable {
  public let epoch: UInt64
  public let assignment: UUID
  public let mode: VisualizationMode
  public init(epoch: UInt64, assignment: UUID, mode: VisualizationMode) {
    self.epoch = epoch; self.assignment = assignment; self.mode = mode
  }
}
public struct VisualizationExtrema: Sendable {
  public let low: Float
  public let high: Float
}
public struct VisualizationFrame: Sendable {
  public let requestEpoch, sequence: UInt64
  public let assignment: UUID
  public let numericAssignment, sourceEpoch, formatEpoch, topology, intent, frameIntent: UInt64
  public let sampleRate: Double
  public let channels, frameCount, clockBasis: UInt32
  public let firstRenderFrame, hostTime, droppedWindows: UInt64
  public let mode: VisualizationMode
  public let beforeWave, afterWave: [VisualizationExtrema]
  public let beforeSpectrum, afterSpectrum, edgesHz: [Float]
  public let beforeRMSDBFS, afterRMSDBFS: Float
  public let originalMix: Float
  public let compareActive, transitioning, intentChanged, compareChanged, silent: Bool
}
public enum VisualizationSnapshot: Sendable {
  case unavailable(VisualizationUnavailable)
  case live(VisualizationFrame)
}

// All setup, allocation, analysis and publication are outside the audio callback.
final class VisualizationAnalyzer {
  private let count: Int
  private let setup: vDSP_DFT_Setup
  private var hann: [Float]
  init?(count: Int) {
    guard count >= 512, count <= 4096, count.nonzeroBitCount == 1,
      let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(count), .FORWARD) else { return nil }
    self.count = count; self.setup = setup
    hann = [Float](repeating: 0, count: count)
    vDSP_hann_window(&hann, vDSP_Length(count), Int32(vDSP_HANN_NORM))
  }
  deinit { vDSP_DFT_DestroySetup(setup) }
  static func db(_ energy: Double, floor: Float = -80) -> Float {
    energy > 0 ? max(floor, Float(10 * log10(energy))) : floor
  }
  func analyze(_ window: UnsafePointer<OGVWindow>, assignment: UUID, mode: VisualizationMode) -> VisualizationFrame {
    let m = window.pointee.meta, channels = Int(m.channels)
    let b = (0..<channels).map { Array(UnsafeBufferPointer(start: ogv_before(window, UInt32($0)), count: count)) }
    let a = (0..<channels).map { Array(UnsafeBufferPointer(start: ogv_after(window, UInt32($0)), count: count)) }
    func energy(_ values: [[Float]]) -> Double {
      values.reduce(0) { $0 + $1.reduce(0) { $0 + Double($1) * Double($1) } } / Double(count * channels)
    }
    func wave(_ values: [[Float]]) -> [VisualizationExtrema] {
      (0..<80).map { column in
        let lo = column * count / 80, hi = (column + 1) * count / 80
        var minimum = Float.greatestFiniteMagnitude, maximum = -Float.greatestFiniteMagnitude
        for channel in values { for i in lo..<hi { minimum = min(minimum, channel[i]); maximum = max(maximum, channel[i]) } }
        return VisualizationExtrema(low: minimum, high: maximum)
      }
    }
    var edges: [Float] = []
    var bands: [Range<Int>] = []
    if mode == .spectrum {
      let upper = min(20_000, m.rate / 2)
      var previous = 1
      for i in 1...32 {
        let frequency = 20 * pow(upper / 20, Double(i) / 32)
        let end = min(count / 2 + 1, max(1, Int(frequency * Double(count) / m.rate) + 1))
        if end > previous {
          edges.append(Float(Double(previous) * m.rate / Double(count)))
          bands.append(previous..<end); previous = end
        }
      }
      edges.append(Float(Double(previous - 1) * m.rate / Double(count)))
    }
    let dftScale = max(1.0, (b + a).flatMap { $0 }.reduce(0.0) { max($0, abs(Double($1))) })
    func spectrum(_ values: [[Float]]) -> [Float] {
      guard mode == .spectrum else { return [] }
      var power = [Double](repeating: 0, count: count / 2 + 1)
      let windowPower = hann.reduce(0.0) { $0 + Double($1) * Double($1) }
      for channel in values {
        var real = [Float](repeating: 0, count: count / 2), imag = real
        var outReal = real, outImag = real
        for i in 0..<count/2 { real[i] = Float(Double(channel[i*2]) / dftScale) * hann[i*2]; imag[i] = Float(Double(channel[i*2+1]) / dftScale) * hann[i*2+1] }
        vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)
        // Real DFT is scaled by two and packs DC/Nyquist in element zero.
        for k in 0...count/2 {
          let re = k == count/2 ? outImag[0] : outReal[k]
          let im: Float = k == 0 || k == count/2 ? 0 : outImag[k]
          let factor = k == 0 || k == count/2 ? 1.0 : 2.0
          power[k] += dftScale * dftScale * factor * (Double(re)*Double(re)+Double(im)*Double(im)) / (4 * Double(count) * windowPower * Double(channels))
        }
      }
      return bands.map { Self.db($0.reduce(0.0) { $0 + power[$1] }) }
    }
    let be = energy(b), ae = energy(a)
    return VisualizationFrame(requestEpoch: m.request, sequence: m.sequence, assignment: assignment,
      numericAssignment: m.assignment, sourceEpoch: m.source, formatEpoch: m.format,
      topology: m.topology, intent: m.intent, frameIntent: m.frame_intent,
      sampleRate: m.rate, channels: m.channels, frameCount: m.frames, clockBasis: m.clock_basis,
      firstRenderFrame: m.first_frame, hostTime: m.last_host_time, droppedWindows: m.dropped,
      mode: mode, beforeWave: wave(b), afterWave: wave(a), beforeSpectrum: spectrum(b),
      afterSpectrum: spectrum(a), edgesHz: edges, beforeRMSDBFS: Self.db(be), afterRMSDBFS: Self.db(ae),
      originalMix: m.original_mix, compareActive: m.compare_active != 0,
      transitioning: m.transitioning != 0, intentChanged: m.intent_changed != 0, compareChanged: m.compare_changed != 0, silent: be <= 1e-12 && ae <= 1e-12)
  }
}

final class VisualizationCapture: @unchecked Sendable {
  private static let allocationLock = NSLock()
  private static var allocated = 0
  let storage: OpaquePointer
  private let assignment: UUID
  private let numericAssignment, sourceEpoch, formatEpoch: UInt64
  private var identityInvalid = false
  private let queue = DispatchQueue(label: "tnf.visualization", qos: .utility)
  private let lock = NSLock()
  private var request: VisualizationRequest?
  private var latest: VisualizationFrame?
  private var event: UInt64 = 0
  private var identityGeneration: UInt64 = 0
  private var demandStarted: UInt64 = 0
  private var hasWindow = false
  private var timer: DispatchSourceTimer?
  private let scratch: UnsafeMutablePointer<OGVWindow>
  private let analyzer: VisualizationAnalyzer
  private let secondsPerTick: Double

  static func create(assignment: UUID, rate: Double, channels: UInt32, numericAssignment: UInt64 = 1, sourceEpoch: UInt64 = 1, formatEpoch: UInt64 = 1) -> VisualizationCapture? {
    allocationLock.lock(); defer { allocationLock.unlock() }
    guard numericAssignment > 0, sourceEpoch > 0, formatEpoch > 0, allocated < 2, let storage = ogv_create(rate, channels) else { return nil }
    guard let analyzer = VisualizationAnalyzer(count: Int(ogv_window_frames(storage))) else { ogv_destroy(storage); return nil }
    allocated += 1
    return VisualizationCapture(storage: storage, assignment: assignment, analyzer: analyzer, numericAssignment: numericAssignment, sourceEpoch: sourceEpoch, formatEpoch: formatEpoch)
  }
  private init(storage: OpaquePointer, assignment: UUID, analyzer: VisualizationAnalyzer, numericAssignment: UInt64, sourceEpoch: UInt64, formatEpoch: UInt64) {
    self.storage = storage; self.assignment = assignment; self.analyzer = analyzer
    self.numericAssignment = numericAssignment; self.sourceEpoch = sourceEpoch; self.formatEpoch = formatEpoch
    scratch = .allocate(capacity: 1); scratch.initialize(to: OGVWindow())
    var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
    secondsPerTick = Double(info.numer) / Double(info.denom) / 1e9
  }
  deinit {
    ogv_request(storage, 0)
    precondition(ogv_scrub_disabled(storage) != 0)
    ogv_destroy(storage); scratch.deinitialize(count: 1); scratch.deallocate()
    Self.allocationLock.lock(); Self.allocated -= 1; Self.allocationLock.unlock()
  }
  func setDemand(_ next: VisualizationRequest?) {
    lock.lock()
    guard next != request else { lock.unlock(); return }
    if let next, let current = request, next.epoch == current.epoch, next.assignment == current.assignment {
      request = next
      lock.unlock()
      return
    }
    request = next; latest = nil; identityInvalid = false; identityGeneration = 0
    demandStarted = mach_absolute_time()
    event = ogv_event(storage)
    ogv_request(storage, next?.epoch ?? 0)
    let old = timer; timer = nil
    old?.cancel()
    if next != nil {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
      timer.setEventHandler { [weak self] in self?.analyzeLatest() }
      self.timer = timer; timer.resume()
    }
    lock.unlock()
    if next == nil {
      queue.async { [self] in
        for _ in 0..<16 {
          if ogv_requested(storage) != 0 || ogv_scrub_disabled(storage) != 0 { break }
          usleep(1_000)
        }
        lock.lock()
        if request == nil { scratch.pointee = OGVWindow(); hasWindow = false }
        lock.unlock()
      }
    }
  }
  private func analyzeLatest() {
    lock.lock(); let wanted = request; lock.unlock()
    guard let wanted else { return }
    if ogv_latest(storage, scratch) != 0 { hasWindow = true }
    guard hasWindow, scratch.pointee.meta.request == wanted.epoch, scratch.pointee.meta.event == ogv_event(storage) else { return }
    let meta = scratch.pointee.meta
    let generation = ogv_identity_generation(storage)
    guard generation != 0, meta.identity_generation == generation else { return }
    guard meta.assignment == numericAssignment, meta.source == sourceEpoch, meta.format == formatEpoch else {
      lock.lock()
      if request == wanted { identityInvalid = true; latest = nil }
      lock.unlock()
      return
    }
    lock.lock(); let unchanged = latest?.sequence == scratch.pointee.meta.sequence && latest?.mode == wanted.mode; lock.unlock()
    guard !unchanged else { return }
    let frame = analyzer.analyze(scratch, assignment: assignment, mode: wanted.mode)
    lock.lock(); defer { lock.unlock() }
    guard request == wanted, meta.identity_generation == ogv_identity_generation(storage),
      meta.event == ogv_event(storage) else { return }
    latest = frame; event = meta.event; identityGeneration = meta.identity_generation; identityInvalid = false
  }
  func snapshot(epoch: UInt64, now: UInt64 = mach_absolute_time()) -> VisualizationSnapshot {
    lock.lock(); defer { lock.unlock() }
    guard request?.epoch == epoch else { return .unavailable(.warming) }
    guard !identityInvalid else { return .unavailable(.invalid) }
    let generation = ogv_identity_generation(storage)
    guard generation != 0 else { return .unavailable(.invalid) }
    if let latest, identityGeneration != generation {
      return .unavailable(now >= latest.hostTime && Double(now - latest.hostTime) * secondsPerTick <= 0.25 ? .warming : .stale)
    }
    if event != ogv_event(storage) {
      if ogv_reason(storage) == 3 {
        let previous = latest?.hostTime ?? demandStarted
        return .unavailable(now >= previous && Double(now - previous) * secondsPerTick <= 0.25 ? .warming : .stale)
      }
      let reason = ogv_reason(storage)
      if let latest, reason == 1 || reason == 2 {
        guard now >= latest.hostTime, Double(now - latest.hostTime) * secondsPerTick <= 0.25 else { return .unavailable(.stale) }
      } else if latest == nil, now >= demandStarted, Double(now - demandStarted) * secondsPerTick <= 0.25 {
        return .unavailable(.warming)
      } else {
        return .unavailable(reason == 2 ? .invalid : .gap)
      }
    }
    guard let latest else {
      let warming = now >= demandStarted && Double(now - demandStarted) * secondsPerTick <= 0.25
      return .unavailable(warming ? .warming : .stale)
    }
    guard now >= latest.hostTime, Double(now - latest.hostTime) * secondsPerTick <= 0.25 else { return .unavailable(.stale) }
    guard latest.mode == request?.mode else { return .unavailable(.warming) }
    let currentGeneration = ogv_identity_generation(storage)
    guard currentGeneration != 0 else { return .unavailable(.invalid) }
    guard identityGeneration == currentGeneration else { return .unavailable(.warming) }
    return .live(latest)
  }
}

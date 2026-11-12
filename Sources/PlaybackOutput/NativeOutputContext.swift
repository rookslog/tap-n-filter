import AVFoundation
import Capture
import Darwin
import OutputGate
import PlaybackDSP

enum OutputError: Error {
  case invalidFormat
  case allocation
  case invalidCallback
  case nativeParameter(OSStatus)
}

// Immutable storage is shared with one serial output callback. `primed` belongs
// only to that callback; gate/counters are C atomics. Control disables and drains
// the gate before closing the borrowed DSP handle or the capture reader.
final class NativeOutputContext: @unchecked Sendable {
  let gate: OpaquePointer
  private let ring: AudioRingBuffer
  private let callback: PDCallback
  private let channels: Int
  private let maximumFrames = 4096
  private let samples: UnsafeMutablePointer<Float>
  private let planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  private var primed = false
  private var visualizationFrames: UInt64 = 0
  private let rawProbe: RawRingProbe?
  private let visualization: VisualizationCapture?
  private let visualizationRate: Double

  @MainActor init(
    ring: AudioRingBuffer, callback: PDCallback,
    probeIdentity: RawRingProbeIdentity? = nil,
    visualization: VisualizationCapture? = nil, visualizationRate: Double = 0
  ) throws {
    guard (1...2).contains(ring.channelCount) else { throw OutputError.invalidFormat }
    guard callback.context != nil, callback.render != nil else { throw OutputError.invalidCallback }
    if let probeIdentity, Int(probeIdentity.channels) != ring.channelCount {
      throw OutputError.invalidFormat
    }
    let rawProbe = try probeIdentity.map { try RawRingProbe(identity: $0) }
    guard let gate = og_create() else { throw OutputError.allocation }
    self.rawProbe = rawProbe
    self.visualization = visualization
    self.visualizationRate = visualizationRate
    self.gate = gate
    self.ring = ring
    self.callback = callback
    channels = ring.channelCount
    samples = .allocate(capacity: channels * maximumFrames)
    samples.initialize(repeating: 0, count: channels * maximumFrames)
    planes = .allocate(capacity: channels)
    for index in 0..<channels {
      planes.advanced(by: index).initialize(to: samples.advanced(by: index * maximumFrames))
    }
  }

  deinit {
    og_disable(gate)
    precondition(og_is_quiescent(gate) != 0)
    planes.deinitialize(count: channels)
    planes.deallocate()
    samples.deinitialize(count: channels * maximumFrames)
    samples.deallocate()
    og_destroy(gate)
  }

  func render(
    silence: UnsafeMutablePointer<ObjCBool>, frames: AVAudioFrameCount,
    buffers: UnsafeMutablePointer<AudioBufferList>
  ) -> OSStatus {
    let visualizationHostTime = visualization != nil && ogv_requested(visualization!.storage) != 0 ? mach_absolute_time() : 0
    let firstVisualizationFrame = visualizationFrames
    let (nextVisualizationFrame, visualizationOverflow) = visualizationFrames.addingReportingOverflow(UInt64(frames))
    if !visualizationOverflow { visualizationFrames = nextVisualizationFrame }
    let probeHostTime = rawProbe == nil ? 0 : mach_absolute_time()
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    func clear() {
      for buffer in list {
        if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
      }
      silence.pointee = true
    }
    guard og_enter(gate) != 0 else {
      clear()
      return noErr
    }
    defer { og_leave(gate) }
    guard frames <= maximumFrames, list.count == channels,
      list.allSatisfy({
        $0.mNumberChannels == 1 && $0.mData != nil && $0.mDataByteSize >= frames * 4
      })
    else {
      clear()
      if let visualization { ogv_gap(visualization.storage, 2) }
      og_record(gate, frames, 0, -1)
      return noErr
    }
    if !primed {
      guard ring.fillCount >= min(256, Int(frames)) else {
        if let visualization { ogv_gap(visualization.storage, 1) }
        clear()
        return noErr
      }
      primed = true
    }
    let count = ring.read(intoChannelPointers: planes, channelCount: channels, frames: Int(frames))
    if count > 0 {
      rawProbe?.record(planes: planes, frames: UInt32(count), hostTime: probeHostTime)
    }
    if count < frames {
      for channel in 0..<channels {
        planes[channel].advanced(by: count).update(repeating: 0, count: Int(frames) - count)
      }
    }
    var input = FRInput()
    input.channels = UInt32(channels)
    input.capacity_frames = UInt32(maximumFrames)
    input.planes = (UnsafePointer(planes[0]), channels == 2 ? UnsafePointer(planes[1]) : nil)
    var output = FROutput()
    output.channels = UInt32(channels)
    output.capacity_frames = frames
    output.planes = (
      list[0].mData?.assumingMemoryBound(to: Float.self),
      channels == 2 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
    )
    var report = PDRenderReport()
    let result = callback.render!(callback.context, &input, &output, frames, &report)
    if let visualization, ogv_requested(visualization.storage) != 0 {
      if result != FR_OK || count != Int(frames) || visualizationOverflow {
        ogv_gap(visualization.storage, result != FR_OK || visualizationOverflow ? 2 : 1)
      } else {
        var meta = OGVMeta()
        meta.assignment = report.renderer.audible.assignment
        meta.source = report.renderer.audible.source_epoch; meta.format = report.renderer.audible.format_epoch
        meta.topology = report.renderer.audible.topology; meta.intent = report.renderer.audible.intent
        meta.frame_intent = report.renderer.frame_intent
        meta.rate = visualizationRate; meta.channels = UInt32(channels)
        meta.first_frame = firstVisualizationFrame
        meta.last_host_time = visualizationHostTime
        meta.clock_basis = 2
        meta.compare_active = report.compare_active; meta.original_requested = report.original_requested
        meta.transitioning = report.renderer.transitioning
        meta.original_mix = report.original_mix; meta.original_gain = report.original_gain
        withUnsafeTemporaryAllocation(of: UnsafePointer<Float>?.self, capacity: channels * 2) { pointers in
          for channel in 0..<channels {
            pointers[channel] = UnsafePointer(planes[channel])
            pointers[channels + channel] = UnsafePointer(list[channel].mData!.assumingMemoryBound(to: Float.self))
          }
          ogv_record(visualization.storage, pointers.baseAddress, pointers.baseAddress!.advanced(by: channels),
            frames, &meta, 0, 0)
        }
      }
    }
    og_record(gate, frames, UInt32(count), result == FR_OK ? 0 : Int32(result.rawValue))
    if result != FR_OK { clear() } else { silence.pointee = false }
    return noErr
  }

  @MainActor
  func drain() async {
    og_disable(gate)
    while og_is_quiescent(gate) == 0 {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { continuation.resume() }
      }
    }
    rawProbe?.finish()
  }

  @MainActor func rawProbeReceipt() -> String? { rawProbe?.json() }

  @MainActor
  func telemetry() -> OGStats {
    var result = OGStats()
    og_stats(gate, &result)
    return result
  }
}

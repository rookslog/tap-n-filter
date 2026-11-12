import AVFoundation
import Darwin
import Foundation
import OutputGate

// MainActor owns storage through drain. The tap captures a token, NOT this
// owner. Token deinit atomically acknowledges final block release; only the
// control-thread owner reclaims C storage, after that ack and callback drain.
final class ProbeOutputMeter: @unchecked Sendable {
  private let storage: OpaquePointer
  init(epoch: UInt64, format: AVAudioFormat) throws {
    guard let storage = og_probe_create(epoch, format.sampleRate, format.channelCount) else {
      throw OutputError.allocation
    }
    self.storage = storage
  }
  deinit {
    precondition(Thread.isMainThread)
    og_probe_close(storage)
    precondition(og_probe_quiescent(storage) != 0)
    og_probe_destroy(storage)
  }
  func record(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    Self.record(buffer, at: time, storage: storage)
  }
  fileprivate static func record(
    _ buffer: AVAudioPCMBuffer, at time: AVAudioTime, storage: OpaquePointer
  ) {
    // A planar pointer array is invalid for an interleaved buffer. Diagnose
    // unsupported layout instead of indexing beyond its sole data pointer.
    let data = buffer.format.isInterleaved ? nil : buffer.floatChannelData
    let planes = data.map {
      UnsafeRawPointer($0).assumingMemoryBound(to: UnsafePointer<Float>?.self)
    }
    og_probe_record(
      storage, planes, buffer.format.channelCount, buffer.frameLength,
      buffer.format.sampleRate, time.isHostTimeValid ? time.hostTime : mach_absolute_time())
  }
  @MainActor func observerBlock() -> AVAudioNodeTapBlock {
    let token = ProbeMeterTapToken(storage: storage)
    return { [token] buffer, time in token.record(buffer, at: time) }
  }
  @MainActor func install(on node: AVAudioNode) {
    // SDK documents a 100–400 ms tap buffer range. This is observation
    // batching only, not a change to the render chain's processing quantum.
    let frames = AVAudioFrameCount(ceil(node.outputFormat(forBus: 0).sampleRate * 0.1))
    node.installTap(onBus: 0, bufferSize: frames, format: nil, block: observerBlock())
  }
  func close() { og_probe_close(storage) }
  func snapshot() -> OGProbeSnapshot {
    var value = OGProbeSnapshot()
    og_probe_snapshot(storage, &value)
    return value
  }
  @MainActor func drain() async {
    close()
    while og_probe_quiescent(storage) == 0 { try? await Task.sleep(for: .milliseconds(1)) }
  }
  @MainActor func json() -> String {
    let s = snapshot()
    let valid =
      s.complete != 0 && s.samples > 0 && s.invalid_samples == 0 && s.invalid_buffers == 0
      && s.dropped_callbacks == 0
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let now = mach_absolute_time()
    let nowUnix = Date().timeIntervalSince1970
    let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
    let firstUnix = nowUnix + (Double(s.first_host_time) - Double(now)) * secondsPerTick
    let lastUnix = nowUnix + (Double(s.last_host_time) - Double(now)) * secondsPerTick
    let record: [String: Any] = [
      "version": 1, "stage": "post-limiter-pre-device", "scope": "final-mix",
      "epoch": s.epoch, "sampleRate": s.sample_rate, "channels": s.channels,
      "callbacks": s.callbacks,
      "frames": s.frames, "samples": s.samples, "nonzeroSamples": s.nonzero_samples,
      "invalidSamples": s.invalid_samples, "invalidBuffers": s.invalid_buffers,
      "droppedCallbacks": s.dropped_callbacks,
      "firstHostTime": s.first_host_time, "lastHostTime": s.last_host_time,
      "timebaseNumer": timebase.numer, "timebaseDenom": timebase.denom,
      "firstBufferUnixSeconds": firstUnix, "lastBufferUnixSeconds": lastUnix,
      "intervalBasis": "tap-host-time-or-callback-entry; last buffer start, not end",
      "summaryUnixSeconds": nowUnix, "summaryHostTime": now,
      "sumSquares": s.sum_squares,
      "rms": s.samples > 0 ? sqrt(s.sum_squares / Double(s.samples)) : 0,
      "peak": s.peak, "complete": s.complete != 0, "valid": valid,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "PROBE_OUTPUT {\"valid\":false}" }
    return "PROBE_OUTPUT " + text
  }
}

private final class ProbeMeterTapToken: @unchecked Sendable {
  private let storage: OpaquePointer
  init(storage: OpaquePointer) {
    self.storage = storage
    og_probe_retain_observer(storage)
  }
  deinit { og_probe_release_observer(storage) }
  func record(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    ProbeOutputMeter.record(buffer, at: time, storage: storage)
  }
}

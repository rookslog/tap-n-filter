import Darwin
import Foundation
import OutputGate
import PlaybackDSP

struct RawRingProbeIdentity: Encodable {
  let assignment: UUID
  let numericAssignment: UInt64
  let sourceEpoch: UInt64
  let formatEpoch: UInt64
  let sampleRate: Double
  let channels: UInt32
}

// NativeOutputContext owns this storage. Its disabled, quiescent callback gate
// must end all borrowing before finish; no framework observer owns this meter.
final class RawRingProbe {
  let identity: RawRingProbeIdentity
  private var storage: OpaquePointer?
  private var retired: OGProbeSnapshot?
  private var finished = false

  @MainActor init(identity: RawRingProbeIdentity) throws {
    guard
      let storage = og_probe_create(
        identity.sourceEpoch, identity.sampleRate, identity.channels)
    else { throw OutputError.allocation }
    self.identity = identity
    self.storage = storage
  }

  deinit {
    if let storage {
      precondition(Thread.isMainThread)
      og_probe_close(storage)
      precondition(og_probe_quiescent(storage) != 0)
      og_probe_destroy(storage)
    }
  }

  func record(
    planes: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, frames: UInt32,
    hostTime: UInt64
  ) {
    guard let storage else { return }
    let readOnly = UnsafeRawPointer(planes).assumingMemoryBound(to: UnsafePointer<Float>?.self)
    og_probe_record(storage, readOnly, identity.channels, frames, identity.sampleRate, hostTime)
  }

  @MainActor func finish() {
    guard let storage else { return }
    og_probe_close(storage)
    guard og_probe_quiescent(storage) != 0 else { return }
    var snapshot = OGProbeSnapshot()
    og_probe_snapshot(storage, &snapshot)
    retired = snapshot
    finished = true
    og_probe_destroy(storage)
    self.storage = nil
  }

  @MainActor func json() -> String {
    let encoded = try! JSONEncoder().encode(identity)
    var record = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    record["version"] = 1
    record["stage"] = "raw-ring-before-padding-before-dsp"
    record["complete"] = finished
    record["valid"] = false
    guard finished, let s = retired else {
      record["reason"] = "callback-retirement-not-observed"
      return Self.line(record)
    }
    record["callbacks"] = s.callbacks
    record["frames"] = s.frames
    record["samples"] = s.samples
    record["finiteSamples"] = s.samples - s.invalid_samples
    record["invalidSamples"] = s.invalid_samples
    record["nonzeroSamples"] = s.nonzero_samples
    record["invalidBuffers"] = s.invalid_buffers
    record["droppedCallbacks"] = s.dropped_callbacks
    record["sumSquares"] = s.sum_squares
    record["peak"] = s.peak
    record["rms"] =
      s.samples > s.invalid_samples
      ? sqrt(s.sum_squares / Double(s.samples - s.invalid_samples)) : 0
    record["valid"] =
      s.samples > 0 && s.invalid_samples == 0
      && s.invalid_buffers == 0 && s.dropped_callbacks == 0 && s.complete != 0
    record["firstHostTime"] = s.first_host_time
    record["lastHostTime"] = s.last_host_time
    record["intervalBasis"] = "callback-entry-host-time; last buffer start, not end"
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let now = mach_absolute_time()
    let unix = Date().timeIntervalSince1970
    let seconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
    record["timebaseNumer"] = timebase.numer
    record["timebaseDenom"] = timebase.denom
    record["summaryHostTime"] = now
    record["summaryUnixSeconds"] = unix
    if s.frames > 0 {
      record["firstBufferUnixSeconds"] = unix + (Double(s.first_host_time) - Double(now)) * seconds
      record["lastBufferUnixSeconds"] = unix + (Double(s.last_host_time) - Double(now)) * seconds
    }
    return Self.line(record)
  }

  private static func line(_ record: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
      let value = String(data: data, encoding: .utf8)
    else { return "PROBE_RAW_INPUT {\"complete\":false,\"valid\":false}" }
    return "PROBE_RAW_INPUT " + value
  }
}

@MainActor final class ProbeDSPCheckpoints {
  private struct Sample: Encodable {
    let hostTime: UInt64
    let phase: String
    let assignment, sourceEpoch, formatEpoch, topology, intent, frameIntent: UInt64
    let measuredFrames, invalidSamples, callbacks: UInt64
    let result: Int32
    let nativeStatus: Int32
    let epochChanged: Bool
  }
  private var samples: [Sample] = []
  private var dropped = 0
  private var timebase = mach_timebase_info_data_t()
  init() {
    mach_timebase_info(&timebase)
    samples.reserveCapacity(64)
  }

  func record(_ stats: PDStats, phase: String, hostTime: UInt64 = mach_absolute_time()) {
    let t = stats.adopted
    let last = samples.last
    let changed =
      last.map {
        $0.assignment != t.assignment || $0.sourceEpoch != t.source_epoch
          || $0.formatEpoch != t.format_epoch
      } ?? true
    if let last, !changed, phase == "sample" {
      let elapsed =
        Double(hostTime - min(hostTime, last.hostTime))
        * Double(timebase.numer) / Double(timebase.denom) / 1e9
      if elapsed < 0.25 { return }
    }
    guard samples.count < 64 else { dropped += 1; return }
    samples.append(
      Sample(
        hostTime: hostTime, phase: phase, assignment: t.assignment,
        sourceEpoch: t.source_epoch, formatEpoch: t.format_epoch, topology: t.topology,
        intent: t.intent, frameIntent: stats.frame_intent, measuredFrames: stats.measured_frames,
        invalidSamples: stats.invalid_samples, callbacks: stats.callbacks,
        result: stats.last_result, nativeStatus: stats.native_status, epochChanged: changed))
  }

  func json(identity: RawRingProbeIdentity) -> String {
    struct Receipt: Encodable {
      let identity: RawRingProbeIdentity
      let version = 1
      let stage = "sampled-dsp-adoption"
      let sampledNotContinuous = true
      let checkpointLimit = 64
      let cadenceSeconds = 0.25
      let checkpoints: [Sample]
      let droppedCheckpoints: Int
      let timebaseNumer, timebaseDenom: UInt32
    }
    let data = try! JSONEncoder().encode(
      Receipt(
        identity: identity, checkpoints: samples, droppedCheckpoints: dropped,
        timebaseNumer: timebase.numer, timebaseDenom: timebase.denom))
    return "PROBE_ADOPTION " + String(decoding: data, as: UTF8.self)
  }
}

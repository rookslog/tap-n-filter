import AVFoundation
import Capture
import Darwin
import OutputGate
import PlaybackDSP
import PlaybackRenderBridge
import SoundModel

@testable import PlaybackOutput

private final class RetiredContextHolder: @unchecked Sendable {
  var value: NativeOutputContext?
  init(_ value: NativeOutputContext) { self.value = value }
}

extension Check {
  @MainActor static func rawRingChecks() async throws {
    let model = try await ListeningSession()
    try await model.putEveryday(on: "test.raw-ring")
    let assignment = try await model.snapshot().assignments[0]
    func owner() async throws -> PlaybackRenderOwner {
      let result = try PlaybackRenderOwner(
        assignment: assignment, numericAssignmentKey: 8, sourceEpoch: 2, formatEpoch: 3,
        format: RenderProcessingFormat(sampleRate: 48000, channels: 2, maximumFrames: 4096),
        intent: 1)
      await result.waitUntilIdle()
      precondition(result.lastPreparation?.published == true)
      return result
    }
    func object(_ line: String, prefix: String = "PROBE_RAW_INPUT ") throws -> [String: Any] {
      precondition(line.hasPrefix(prefix))
      return try JSONSerialization.jsonObject(with: Data(line.dropFirst(prefix.count).utf8))
        as! [String: Any]
    }
    let identity = RawRingProbeIdentity(
      assignment: assignment.id, numericAssignment: 8, sourceEpoch: 2, formatEpoch: 3,
      sampleRate: 48000, channels: 2)
    do {
      _ = try NativeOutputContext(
        ring: AudioRingBuffer(channelCount: 2, capacity: 8192), callback: PDCallback(),
        probeIdentity: identity)
      preconditionFailure("invalid callback must not prepare a meter")
    } catch OutputError.invalidCallback {}
    do {
      _ = try RawRingProbe(
        identity: RawRingProbeIdentity(
          assignment: assignment.id, numericAssignment: 8, sourceEpoch: 0, formatEpoch: 3,
          sampleRate: 48000, channels: 2))
      preconditionFailure("invalid epoch must refuse allocation")
    } catch OutputError.allocation {}
    let measuredOwner = try await owner(), plainOwner = try await owner()
    let ring = AudioRingBuffer(channelCount: 2, capacity: 8192)
    let plainRing = AudioRingBuffer(channelCount: 2, capacity: 8192)
    let context = try NativeOutputContext(
      ring: ring, callback: measuredOwner.nativeCallback, probeIdentity: identity)
    let plain = try NativeOutputContext(ring: plainRing, callback: plainOwner.nativeCallback)
    precondition(plain.rawProbeReceipt() == nil)
    let early = try object(context.rawProbeReceipt()!)
    precondition(early["complete"] as? Bool == false && early["frames"] == nil)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    let other = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    output.frameLength = 256; other.frameLength = 256
    var expectedFrames = 0, expectedInvalid = 0, expectedNonzero = 0
    var expectedEnergy = 0.0
    func feed(_ left: Float, _ right: Float, stored: Int = 256) {
      input.floatChannelData![0].update(repeating: left, count: 256)
      input.floatChannelData![1].update(repeating: right, count: 256)
      let planes = [
        UnsafePointer(input.floatChannelData![0]), UnsafePointer(input.floatChannelData![1]),
      ]
      precondition(ring.write(from: planes, frames: stored) == stored)
      precondition(plainRing.write(from: planes, frames: stored) == stored)
      var silent: ObjCBool = false, otherSilent: ObjCBool = false
      _ = context.render(silence: &silent, frames: 256, buffers: output.mutableAudioBufferList)
      _ = plain.render(silence: &otherSilent, frames: 256, buffers: other.mutableAudioBufferList)
      for channel in 0..<2 {
        for frame in 0..<256 {
          precondition(
            output.floatChannelData![channel][frame].bitPattern
              == other.floatChannelData![channel][frame].bitPattern)
        }
      }
      expectedFrames += stored
      for value in [left, right] {
        if !value.isFinite {
          expectedInvalid += stored
        } else {
          expectedNonzero += value == 0 ? 0 : stored
          expectedEnergy += Double(value) * Double(value) * Double(stored)
        }
      }
    }
    for _ in 0..<200 { feed(0, 0) }
    feed(0, 0.125)
    feed(0.0000005, 0.0000005)
    feed(.nan, 0.25, stored: 64)
    feed(0.5, -0.25, stored: 16)
    feed(0, 0, stored: 0)
    precondition(og_enter(context.gate) != 0)
    let pending = Task { @MainActor in await context.drain() }
    await Task.yield()
    let waiting = try object(context.rawProbeReceipt()!)
    precondition(waiting["complete"] as? Bool == false)
    og_leave(context.gate)
    await pending.value
    await context.drain()
    let receipt = try object(context.rawProbeReceipt()!)
    precondition(receipt["complete"] as? Bool == true && receipt["valid"] as? Bool == false)
    precondition(receipt["frames"] as? Int == expectedFrames)
    precondition(receipt["samples"] as? Int == expectedFrames * 2)
    precondition(receipt["invalidSamples"] as? Int == expectedInvalid)
    precondition(receipt["finiteSamples"] as? Int == expectedFrames * 2 - expectedInvalid)
    precondition(receipt["nonzeroSamples"] as? Int == expectedNonzero)
    precondition(abs((receipt["sumSquares"] as! Double) - expectedEnergy) < 1e-10)
    precondition(receipt["peak"] as? Double == 0.5)
    precondition(receipt["sourceEpoch"] as? Int == 2 && receipt["formatEpoch"] as? Int == 3)
    precondition(receipt["assignment"] as? String == assignment.id.uuidString)
    precondition((receipt["lastHostTime"] as! UInt64) >= (receipt["firstHostTime"] as! UInt64))
    print(
      "PASS raw ring zero/late-positive/right-channel/threshold/nonfinite/partial/zero-read scalars; padding excluded"
    )
    print("PASS diagnostic-disabled output bit-identical; default context has no raw meter")
    var silence: ObjCBool = false
    _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
    let late = try object(context.rawProbeReceipt()!)
    precondition(late["frames"] as? Int == expectedFrames)
    await plain.drain()
    try await measuredOwner.close(consumerQuiesced: true)
    try await plainOwner.close(consumerQuiesced: true)
    print(
      "PASS pending callback gate prevents premature snapshot; duplicate drain/late callback leave retired data unchanged"
    )

    for epoch: UInt64 in [4, 5] {
      let freshOwner = try await owner()
      let fresh = try NativeOutputContext(
        ring: AudioRingBuffer(channelCount: 2, capacity: 8192), callback: freshOwner.nativeCallback,
        probeIdentity: RawRingProbeIdentity(
          assignment: assignment.id, numericAssignment: 8,
          sourceEpoch: epoch, formatEpoch: epoch, sampleRate: 48000, channels: 2))
      await fresh.drain()
      let empty = try object(fresh.rawProbeReceipt()!)
      precondition(empty["frames"] as? Int == 0 && empty["valid"] as? Bool == false)
      precondition(empty["sourceEpoch"] as? UInt64 == epoch)
      try await freshOwner.close(consumerQuiesced: true)
    }
    print(
      "PASS never-started/empty epochs are distinct, complete but invalid; no fabricated valid silence"
    )
    let finalOwner = try await owner()
    let holder = RetiredContextHolder(
      try NativeOutputContext(
        ring: AudioRingBuffer(channelCount: 2, capacity: 8192), callback: finalOwner.nativeCallback,
        probeIdentity: identity))
    await holder.value!.drain()
    try await finalOwner.close(consumerQuiesced: true)
    await Task.detached { holder.value = nil }.value
    precondition(holder.value == nil)
    print("PASS raw C storage retired on control thread before framework-side last context release")
    let checkpoints = ProbeDSPCheckpoints()
    var stats = PDStats()
    stats.adopted.assignment = 8; stats.adopted.source_epoch = 2; stats.adopted.format_epoch = 3
    stats.frame_intent = 9; stats.invalid_samples = 7; stats.last_result = -2
    checkpoints.record(stats, phase: "prepared", hostTime: 1)
    for _ in 0..<100 { checkpoints.record(stats, phase: "sample", hostTime: 2) }
    var result = try object(checkpoints.json(identity: identity), prefix: "PROBE_ADOPTION ")
    precondition((result["checkpoints"] as! [[String: Any]]).count == 1)
    for epoch: UInt64 in 3..<103 {
      stats.adopted.source_epoch = epoch
      checkpoints.record(stats, phase: "sample", hostTime: epoch)
    }
    result = try object(checkpoints.json(identity: identity), prefix: "PROBE_ADOPTION ")
    let rows = result["checkpoints"] as! [[String: Any]]
    precondition(rows.count == 64 && result["droppedCheckpoints"] as? Int == 37)
    precondition(rows[1]["epochChanged"] as? Bool == true)
    precondition(rows[0]["invalidSamples"] as? Int == 7 && rows[0]["result"] as? Int == -2)
    precondition(result["sampledNotContinuous"] as? Bool == true)
    print(
      "PASS adopted epochs/status scalars, cadence coalescing and64-checkpoint cap with explicit drops"
    )
    print("PASS no engine start, capture, server, browser or device operations")
  }
}

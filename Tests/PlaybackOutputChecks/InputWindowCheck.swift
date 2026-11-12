import AVFoundation
import Capture
import PlaybackRenderBridge
import SoundModel

@testable import PlaybackOutput

extension Check {
  @MainActor static func inputWindowChecks() async throws {
    let model = try await ListeningSession()
    try await model.putEveryday(on: "test.input-window")
    let assignment = try await model.snapshot().assignments[0]
    let owner = try PlaybackRenderOwner(
      assignment: assignment, numericAssignmentKey: 91, sourceEpoch: 1, formatEpoch: 1,
      format: RenderProcessingFormat(sampleRate: 48000, channels: 2, maximumFrames: 4096),
      intent: 1)
    await owner.waitUntilIdle()
    precondition(
      owner.lastPreparation?.published == true,
      "Native preparation result=\(owner.lastPreparation?.result.description ?? "nil") status=\(owner.lastPreparation?.nativeStatus.description ?? "nil")"
    )
    let ring = AudioRingBuffer(channelCount: 2, capacity: 8192)
    let context = try NativeOutputContext(ring: ring, callback: owner.nativeCallback)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    output.frameLength = 256

    func feed(_ value: Float, blocks: Int) {
      for channel in 0..<2 {
        input.floatChannelData![channel].update(repeating: value, count: 256)
      }
      for _ in 0..<blocks {
        precondition(
          ring.write(
            from: [
              UnsafePointer(input.floatChannelData![0]), UnsafePointer(input.floatChannelData![1]),
            ], frames: 256) == 256)
        var silence: ObjCBool = false
        _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
      }
    }

    feed(0, blocks: 200)
    let silent = owner.telemetry()
    precondition(silent.adopted.assignment == 91 && silent.adopted.source_epoch == 1)
    precondition(silent.frame_intent == 1 && silent.measured_frames == 0)
    precondition(context.telemetry().captured_frames == 51200)
    print("PASS 51200 zero ring frames consumed with adopted assignment91; measured_frames=0")

    feed(0.01, blocks: 1)
    precondition(owner.telemetry().measured_frames == 256)
    feed(0.01, blocks: 99)
    precondition(owner.telemetry().measured_frames == 19200)
    precondition(owner.telemetry().compare_ready != 0)
    print(
      "PASS positive input after 1.067s starts counter at256 and reaches19200; not a first-0.4s window"
    )

    feed(0, blocks: 5)
    feed(0.01, blocks: 5)
    precondition(owner.telemetry().measured_frames == 19200)
    print("PASS zero and further positive input neither reset nor exceed the 19200-frame cap")

    _ = try owner.update(assignment, intent: 2, sourceEpoch: 2, formatEpoch: 1)
    await owner.waitUntilIdle()
    precondition(owner.lastPreparation?.published == true)
    feed(0, blocks: 1)
    let reset = owner.telemetry()
    precondition(reset.adopted.source_epoch == 2 && reset.measured_frames == 0)
    feed(0.0000005, blocks: 1)
    precondition(owner.telemetry().measured_frames == 0)
    feed(.nan, blocks: 1)
    precondition(owner.telemetry().measured_frames == 0)
    precondition(owner.telemetry().invalid_samples == reset.invalid_samples + 512)
    print(
      "PASS below-threshold and nonfinite frames can leave measured_frames=0 despite ring consumption"
    )
    feed(0.01, blocks: 1)
    precondition(owner.telemetry().measured_frames == 256)
    precondition(context.telemetry().errors == 0 && context.telemetry().underruns == 0)
    print(
      "PASS new adopted source epoch resets the counter; later positive input accumulates again")
    await context.drain()
    try await owner.close(consumerQuiesced: true)
    print(
      "PASS direct headless ring/DSP callbacks only; no engine start, capture, HAL or hardware output"
    )
  }
}

import AVFoundation
import Capture
import OutputGate
import PlaybackRenderBridge
import SoundModel

@testable import PlaybackOutput

@main struct Check {
  @MainActor static func main() async throws {
    if CommandLine.arguments.contains("--raw-ring") {
      try await rawRingChecks()
      return
    }
    if CommandLine.arguments.contains("--input-window") {
      try await inputWindowChecks()
      return
    }
    if CommandLine.arguments.contains("--softer-onset") {
      for position in [0.0, 0.005, 0.01, 0.0125, 0.015, 0.02, 0.05, 0.1] {
        let gain = try await transferGain(position: position, peak: 0.8)
        precondition(gain > 0 && gain.isFinite)
        print("ONSET position=\(position) inputPeak=0.8 outputInputRMS=\(gain)")
      }
      print(
        "PASS native steady-tone Softer onset samples; not an audible click or transient verdict")
      return
    }
    try await probeMeterChecks()
    let model = try await ListeningSession()
    try await model.putEveryday(on: "test.output-callback")
    let assignment = try await model.snapshot().assignments[0]
    let owner = try PlaybackRenderOwner(
      assignment: assignment, numericAssignmentKey: 1,
      sourceEpoch: 1, formatEpoch: 1,
      format: RenderProcessingFormat(sampleRate: 48000, channels: 2, maximumFrames: 4096), intent: 1
    )
    await owner.waitUntilIdle()
    precondition(owner.lastPreparation?.published == true)
    let ring = AudioRingBuffer(channelCount: 2, capacity: 8192)
    let context = try NativeOutputContext(ring: ring, callback: owner.nativeCallback)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
    input.frameLength = 8192
    output.frameLength = 8192
    for channel in 0..<2 {
      for frame in 0..<8192 {
        input.floatChannelData![channel][frame] = Float(
          0.1 * sin(Double(frame) * 997 * 2 * .pi / 48000))
      }
    }
    var silence: ObjCBool = false
    _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
    precondition(silence.boolValue && owner.telemetry().callbacks == 0)
    print("PASS unprimed ring remains silent without consuming the initial render fade")
    for _ in 0..<100 {
      _ = ring.write(
        from: [
          UnsafePointer(input.floatChannelData![0]), UnsafePointer(input.floatChannelData![1]),
        ], frames: 256)
      _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
      precondition(!silence.boolValue)
      for channel in 0..<2 {
        for frame in 0..<256 { precondition(output.floatChannelData![channel][frame].isFinite) }
      }
    }
    precondition(
      owner.telemetry().compare_ready != 0 && context.telemetry().captured_frames == 25600)
    print(
      "PASS real ring-to-stereo-native-render callback produces finite output and measured compare readiness"
    )
    _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
    precondition(context.telemetry().underruns == 1)
    _ = context.render(silence: &silence, frames: 8192, buffers: output.mutableAudioBufferList)
    precondition(silence.boolValue && context.telemetry().errors == 1)
    print("PASS underrun and unsupported callback size are distinct observable conditions")
    await context.drain()
    let calls = owner.telemetry().callbacks
    try await owner.close(consumerQuiesced: true)
    _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
    precondition(silence.boolValue)
    print(
      "PASS disabled output callback stays silent after the borrowed native owner closes (\(calls) earlier calls)"
    )
    let unlimitedPeak = try mixedPeak(limited: false)
    let limitedPeak = try mixedPeak(limited: true)
    precondition(unlimitedPeak > 1.5, "The two-source control must actually exceed full scale")
    precondition(limitedPeak > 0.2 && limitedPeak <= 1.00001)
    print(
      "PASS two coherent native sources: unprotected peak \(unlimitedPeak), final-limited peak \(limitedPeak)"
    )
    var gentleGains: [Double] = []
    for peak in [0.01, 0.1, 0.8] {
      let neutral = try await transferGain(position: 0, peak: peak)
      let gentle = try await transferGain(position: 1, peak: peak)
      precondition(neutral > 0.98 && neutral < 1.02)
      precondition(gentle > 0 && gentle < neutral)
      gentleGains.append(gentle)
      print("TRANSFER inputPeak=\(peak) neutralGain=\(neutral) gentleGain=\(gentle)")
    }
    precondition(gentleGains[2] < gentleGains[0] * 0.9)
    print(
      "PASS Softer changes steady-state level response, not only constant gain; neutral stays near unity"
    )
    print(
      "PASS offline output adapter/manual engine only; no hardware output, capture, route or device opened"
    )
  }

  @MainActor private static func probeMeterChecks() async throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let owner = try ProbeOutputMeter(epoch: 99, format: format)
    var callback: AVAudioNodeTapBlock? = owner.observerBlock()
    owner.close()
    precondition(owner.snapshot().complete == 0)
    let late = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
    late.frameLength = 32
    callback?(late, AVAudioTime(hostTime: 1))
    precondition(owner.snapshot().frames == 0 && owner.snapshot().complete == 0)
    callback = nil
    await owner.drain()
    precondition(owner.snapshot().complete != 0)
    print(
      "PASS callback-token release ack gates storage retirement; closed late entry ignored; owner reclaimed only on control thread"
    )
    let interleaved = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
    let unsupported = AVAudioPCMBuffer(pcmFormat: interleaved, frameCapacity: 32)!
    unsupported.frameLength = 32
    let invalidMeter = try ProbeOutputMeter(epoch: 100, format: interleaved)
    invalidMeter.record(unsupported, at: AVAudioTime(hostTime: 1))
    await invalidMeter.drain()
    precondition(
      invalidMeter.snapshot().invalid_buffers == 1 && invalidMeter.snapshot().samples == 0)
    print(
      "PASS unsupported interleaved layout is diagnosed, not dereferenced as planar or called silent"
    )
    for muted in [true, false] {
      let engine = AVAudioEngine()
      let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
      try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
      let model = try await ListeningSession()
      try await model.putEveryday(on: "test.probe-final-output")
      let assignment = try await model.snapshot().assignments[0]
      let renderer = try PlaybackRenderOwner(
        assignment: assignment, numericAssignmentKey: 1, sourceEpoch: 1, formatEpoch: 1,
        format: RenderProcessingFormat(sampleRate: 48000, channels: 2, maximumFrames: 4096),
        intent: 1)
      await renderer.waitUntilIdle()
      precondition(renderer.lastPreparation?.published == true)
      let ring = AudioRingBuffer(channelCount: 2, capacity: 8192)
      let context = try NativeOutputContext(ring: ring, callback: renderer.nativeCallback)
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
      let planes = [
        UnsafePointer(input.floatChannelData![0]), UnsafePointer(input.floatChannelData![1]),
      ]
      let renderBlock: AVAudioSourceNodeRenderBlock = { silence, time, frames, buffers in
        precondition(frames <= 4096)
        for channel in 0..<2 {
          for i in 0..<Int(frames) {
            let sampleTime: Double = time.pointee.mSampleTime + Double(i)
            let phase: Double = sampleTime * 997 * 2 * Double.pi / 48000
            input.floatChannelData![channel][i] = Float(0.1 * sin(phase))
          }
        }
        _ = ring.write(from: planes, frames: Int(frames))
        return context.render(silence: silence, frames: frames, buffers: buffers)
      }
      let source = AVAudioSourceNode(format: format, renderBlock: renderBlock)
      engine.attach(source)
      let limiter = try FinalMixLimiter.make(); engine.attach(limiter)
      try connect(engine, source, engine.mainMixerNode, format: format)
      try connect(engine, engine.mainMixerNode, limiter, format: format)
      try connect(engine, limiter, engine.outputNode, format: format)
      engine.mainMixerNode.outputVolume = muted ? 0 : 1
      let meter = try ProbeOutputMeter(epoch: muted ? 1 : 2, format: format)
      meter.install(on: limiter)  // exact observer installation helper used by NativeOutputHub
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
      precondition(engine.manualRenderingMode == .offline)
      try engine.start()
      for _ in 0..<100 {
        let status = try engine.renderOffline(512, to: buffer)
        precondition(status == .success)
        await Task.yield()
      }
      // Taps may be delivered on a separate framework queue even offline.
      try await Task.sleep(for: .milliseconds(100))
      meter.close(); limiter.removeTap(onBus: 0); engine.stop(); await meter.drain()
      let inputStats = renderer.telemetry()
      precondition(inputStats.measured_frames > 0 && context.telemetry().captured_frames > 0)
      await context.drain()
      try await renderer.close(consumerQuiesced: true)
      let stats = meter.snapshot()
      precondition(stats.complete != 0 && stats.frames > 0 && stats.invalid_buffers == 0)
      precondition(muted ? stats.sum_squares == 0 : stats.sum_squares > 0)
      print(
        "PASS actual final-limiter tap offline: measured input=\(inputStats.measured_frames); mixer muted=\(muted), frames=\(stats.frames), energy=\(stats.sum_squares)"
      )
    }
  }

  @MainActor private static func transferGain(position: Double, peak: Double) async throws -> Double
  {
    let model = try await ListeningSession()
    try await model.putEveryday(on: "test.softer-transfer")
    let id = try await model.snapshot().assignments[0].id
    let softer = model.controls.first { $0.title == "Softer" }!
    try await model.move(softer.id, on: id, to: position)
    let assignment = try await model.snapshot().assignments[0]
    let owner = try PlaybackRenderOwner(
      assignment: assignment, numericAssignmentKey: 1, sourceEpoch: 1, formatEpoch: 1,
      format: RenderProcessingFormat(sampleRate: 48000, channels: 2, maximumFrames: 4096), intent: 1
    )
    await owner.waitUntilIdle()
    precondition(owner.lastPreparation?.published == true)
    let ring = AudioRingBuffer(channelCount: 2, capacity: 8192)
    let context = try NativeOutputContext(ring: ring, callback: owner.nativeCallback)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    input.frameLength = 256
    output.frameLength = 256
    var inputEnergy = 0.0
    var outputEnergy = 0.0
    for block in 0..<720 {
      for frame in 0..<256 {
        let sample = Float(peak * sin(Double(block * 256 + frame) * 997 * 2 * .pi / 48000))
        for channel in 0..<2 { input.floatChannelData![channel][frame] = sample }
        if block >= 480 { inputEnergy += Double(sample) * Double(sample) }
      }
      _ = ring.write(
        from: [
          UnsafePointer(input.floatChannelData![0]), UnsafePointer(input.floatChannelData![1]),
        ], frames: 256)
      var silence: ObjCBool = false
      _ = context.render(silence: &silence, frames: 256, buffers: output.mutableAudioBufferList)
      precondition(!silence.boolValue)
      for frame in 0..<256 {
        let sample = Double(output.floatChannelData![0][frame])
        precondition(sample.isFinite && output.floatChannelData![1][frame].isFinite)
        if block >= 480 { outputEnergy += sample * sample }
      }
    }
    let stats = context.telemetry()
    precondition(stats.errors == 0 && stats.underruns == 0 && stats.captured_frames == 184320)
    await context.drain()
    try await owner.close(consumerQuiesced: true)
    return sqrt(outputEnergy / inputEnergy)
  }

  @MainActor private static func mixedPeak(limited: Bool) throws -> Float {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    for bus in 0..<2 {
      let renderBlock: AVAudioSourceNodeRenderBlock = { silence, timestamp, frames, buffers in
        silence.pointee = false
        let start: Double = timestamp.pointee.mSampleTime
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
          guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
          for frame in 0..<Int(frames) {
            let sampleTime: Double = start + Double(frame)
            let phase: Double = sampleTime * 997 * 2 * Double.pi / 48000
            data[frame] = Float(0.8 * sin(phase))
          }
        }
        return noErr
      }
      let source = AVAudioSourceNode(format: format, renderBlock: renderBlock)
      engine.attach(source)
      try connect(engine, source, engine.mainMixerNode, bus: AVAudioNodeBus(bus), format: format)
    }
    if limited {
      let limiter = try FinalMixLimiter.make()
      engine.attach(limiter)
      try connect(engine, engine.mainMixerNode, limiter, format: format)
      try connect(engine, limiter, engine.outputNode, format: format)
    } else {
      try connect(engine, engine.mainMixerNode, engine.outputNode, format: format)
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    try engine.start()
    defer { engine.stop() }
    var peak: Float = 0
    for _ in 0..<100 {
      let status = try engine.renderOffline(512, to: buffer)
      precondition(status == .success)
      for channel in 0..<2 {
        for frame in 0..<Int(buffer.frameLength) {
          let value = buffer.floatChannelData![channel][frame]
          precondition(value.isFinite)
          peak = max(peak, abs(value))
        }
      }
    }
    return peak
  }

  @MainActor private static func connect(
    _ engine: AVAudioEngine, _ source: AVAudioNode, _ destination: AVAudioNode,
    bus: AVAudioNodeBus = 0, format: AVAudioFormat
  ) throws {
    if #available(macOS 27, *) {
      try engine.connectNode(source, to: destination, fromBus: 0, toBus: numericCast(bus), format: format)
    } else {
      engine.connect(source, to: destination, fromBus: 0, toBus: bus, format: format)
    }
  }
}

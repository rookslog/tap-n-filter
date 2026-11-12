import AVFoundation
import NativeTestSupport
import XCTest
@testable import Effects

final class ReverbNodeTests: XCTestCase {

    // MARK: Defaults and metadata

    func test_default_preset_is_largeHall() {
        let node = ReverbNode()
        XCTAssertEqual(node.preset, .largeHall)
    }

    func test_reverb_has_no_continuous_parameters() {
        let node = ReverbNode()
        XCTAssertTrue(node.parameters.isEmpty)
    }

    func test_setParameter_throws_for_any_identifier() {
        let node = ReverbNode()
        XCTAssertThrowsError(try node.setParameter("anything", value: 1.0))
    }

    func test_showsWetDryByDefault_uses_protocol_default_true() {
        XCTAssertTrue(ReverbNode.showsWetDryByDefault)
    }

    // MARK: Preset enum mapping

    func test_preset_name_round_trip_for_each_supported_case() {
        for (name, preset) in ReverbNode.supportedPresets {
            XCTAssertEqual(
                ReverbNode.preset(forName: name),
                preset,
                "round-trip failed for \(name)"
            )
            XCTAssertEqual(
                ReverbNode.name(for: preset),
                name,
                "round-trip failed for \(name)"
            )
        }
    }

    func test_preset_name_unknown_returns_nil() {
        XCTAssertNil(ReverbNode.preset(forName: "definitely-not-a-real-preset"))
    }

    // MARK: Snapshot / restore round-trip

    func test_snapshot_restore_preserves_preset() throws {
        let original = ReverbNode(preset: .cathedral)
        original.displayName = "Custom Reverb"
        original.wetDryMix = 0.42

        let state = original.snapshot()
        XCTAssertEqual(state.typeIdentifier, ReverbNode.typeIdentifier)
        XCTAssertEqual(state.extras["preset"], .string("cathedral"))

        let restored = ReverbNode()
        try restored.restore(from: state)
        XCTAssertEqual(restored.preset, .cathedral)
        XCTAssertEqual(restored.displayName, "Custom Reverb")
        XCTAssertEqual(restored.wetDryMix, 0.42, accuracy: 0.0001)
    }

    func test_restore_accepts_legacy_int_rawValue() throws {
        // Older or hand-rolled `.tnf` files may use the int rawValue. Make
        // sure the restore path accepts that form for forward-compat.
        let intState = EffectState(
            typeIdentifier: ReverbNode.typeIdentifier,
            id: UUID(),
            displayName: "Reverb",
            bypass: false,
            wetDryMix: 0.5,
            parameters: [:],
            extras: ["preset": .int(AVAudioUnitReverbPreset.plate.rawValue)]
        )
        let node = ReverbNode()
        try node.restore(from: intState)
        XCTAssertEqual(node.preset, .plate)
    }

    func test_restore_throws_on_unknown_preset_name() {
        let badState = EffectState(
            typeIdentifier: ReverbNode.typeIdentifier,
            id: UUID(),
            displayName: "Reverb",
            bypass: false,
            wetDryMix: 0.5,
            parameters: [:],
            extras: ["preset": .string("not-a-real-preset")]
        )
        let node = ReverbNode()
        XCTAssertThrowsError(try node.restore(from: badState))
    }

    // MARK: Offline render — wet/dry endpoints

    private func renderRMS(
        wetDryMix: Float,
        bypass: Bool = false,
        seconds: Double = 0.1
    ) throws -> Float {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        engine.attach(player)
        let node = ReverbNode()
        node.bypass = bypass
        node.wetDryMix = wetDryMix
        try node.attach(to: engine)
        engine.connect(player, to: node.inputBus, format: format)
        engine.connect(node.outputBus, to: engine.mainMixerNode, format: format)

        let frameCount = AVAudioFrameCount(48_000.0 * seconds)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCount)

        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let angularFreq = 2.0 * Double.pi * 1_000.0 / 48_000.0
        for channel in 0 ..< Int(format.channelCount) {
            let data = buffer.floatChannelData![channel]
            for frame in 0 ..< Int(frameCount) {
                data[frame] = Float(sin(angularFreq * Double(frame))) * 0.5
            }
        }

        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        XCTAssertEqual(try engine.renderOffline(frameCount, to: outputBuffer), .success)

        player.stop()
        engine.stop()
        engine.disableManualRenderingMode()
        node.detach()

        var sumSquares: Float = 0
        let channels = Int(format.channelCount)
        let frames = Int(outputBuffer.frameLength)
        for channel in 0 ..< channels {
            let data = outputBuffer.floatChannelData![channel]
            for frame in 0 ..< frames {
                let sample = data[frame]
                sumSquares += sample * sample
            }
        }
        return sqrt(sumSquares / Float(frames * channels))
    }

    func test_bypass_renders_full_signal() throws {
        let rms = try renderRMS(wetDryMix: 0.0, bypass: true)
        XCTAssertGreaterThan(rms, 0.2)
    }

    func test_wetDryMix_zero_renders_dry_signal() throws {
        let rms = try renderRMS(wetDryMix: 0.0)
        XCTAssertGreaterThan(rms, 0.2)
    }

    func test_wetDryMix_one_produces_non_silent_output() throws {
        // A 100 ms render through a large-hall reverb won't have settled, but
        // the initial direct sound should be audible.
        let rms = try renderRMS(wetDryMix: 1.0)
        XCTAssertGreaterThan(rms, 0.0001)
    }
}

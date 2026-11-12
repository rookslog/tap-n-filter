import AVFoundation
import NativeTestSupport
import XCTest
@testable import Effects

final class GainNodeTests: XCTestCase {

    // MARK: Parameter metadata

    func test_parameter_catalog_lists_single_gain_parameter() {
        let node = GainNode()
        XCTAssertEqual(node.parameters.map(\.identifier), ["gain"])
        XCTAssertEqual(node.parameters[0].unit, .decibels)
    }

    func test_default_gain_is_unity_zero_dB() {
        let node = GainNode()
        XCTAssertEqual(node.parameterValue("gain"), 0.0)
    }

    func test_supportsWetDry_is_false() {
        XCTAssertFalse(GainNode.supportsWetDry)
    }

    func test_showsWetDryByDefault_is_false() {
        XCTAssertFalse(GainNode.showsWetDryByDefault)
    }

    // MARK: setParameter dispatch and range enforcement

    func test_setParameter_updates_gain() throws {
        let node = GainNode()
        try node.setParameter("gain", value: -6.0)
        XCTAssertEqual(node.parameterValue("gain"), -6.0)
    }

    func test_setParameter_throws_on_unknown_identifier() {
        let node = GainNode()
        XCTAssertThrowsError(try node.setParameter("bogus", value: 1.0)) { error in
            guard case EffectParameterError.unknownParameter(let id) = error else {
                XCTFail("Expected unknownParameter, got \(error)")
                return
            }
            XCTAssertEqual(id, "bogus")
        }
    }

    func test_setParameter_throws_above_range() {
        let node = GainNode()
        XCTAssertThrowsError(try node.setParameter("gain", value: 24.0)) { error in
            guard case EffectParameterError.valueOutOfRange(let id, _, _) = error else {
                XCTFail("Expected valueOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(id, "gain")
        }
    }

    func test_setParameter_throws_below_range() {
        let node = GainNode()
        XCTAssertThrowsError(try node.setParameter("gain", value: -48.0))
    }

    func test_parameterValue_nil_for_unknown_identifier() {
        XCTAssertNil(GainNode().parameterValue("bogus"))
    }

    func test_initializer_clamps_out_of_range_gain() {
        let tooHot = GainNode(gainDecibels: 60.0)
        XCTAssertEqual(tooHot.parameterValue("gain"), 12.0, "init must clamp to the +12 dB ceiling")
        let tooCold = GainNode(gainDecibels: -60.0)
        XCTAssertEqual(tooCold.parameterValue("gain"), -24.0, "init must clamp to the −24 dB floor")
    }

    // MARK: Offline render — gain applied to the rendered signal

    /// Offline-render a 0.5-amplitude 1 kHz sine through `node` and return the
    /// mean-square energy of the output. Mirrors `EQNodeTests.renderEnergy`.
    private func renderEnergy(through node: GainNode) throws -> Float {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        engine.attach(player)
        try node.attach(to: engine)
        engine.connect(player, to: node.inputBus, format: format)
        engine.connect(node.outputBus, to: engine.mainMixerNode, format: format)

        let frameCount: AVAudioFrameCount = 4_800 // 0.1 s at 48 kHz
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCount)

        let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        inputBuffer.frameLength = frameCount
        let angularFreq = 2.0 * Double.pi * 1_000.0 / 48_000.0
        for channel in 0 ..< Int(format.channelCount) {
            let data = inputBuffer.floatChannelData![channel]
            for frame in 0 ..< Int(frameCount) {
                data[frame] = Float(sin(angularFreq * Double(frame))) * 0.5
            }
        }

        try engine.start()
        player.scheduleBuffer(inputBuffer, at: nil, options: [], completionHandler: nil)
        player.play()

        let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        let status = try engine.renderOffline(frameCount, to: outputBuffer)
        XCTAssertEqual(status, .success)

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
                sumSquares += data[frame] * data[frame]
            }
        }
        return sumSquares / Float(frames * channels)
    }

    func test_unity_gain_passes_signal_at_reference_energy() throws {
        // 0.5-amplitude sine has mean-square energy ≈ 0.125.
        let energy = try renderEnergy(through: GainNode())
        XCTAssertEqual(energy, 0.125, accuracy: 0.02)
    }

    func test_attenuation_reduces_energy() throws {
        let node = GainNode()
        try node.setParameter("gain", value: -6.0) // ≈0.5× amplitude → 0.25× energy
        let energy = try renderEnergy(through: node)
        XCTAssertLessThan(energy, 0.07, "−6 dB should cut energy well below the 0.125 unity reference")
    }

    func test_boost_increases_energy() throws {
        // +6 dB ≈ 2× amplitude → ≈4× energy. This also confirms the mixer's
        // outputVolume applies gain above unity (the project relies on this for
        // the output trim too).
        let node = GainNode()
        try node.setParameter("gain", value: 6.0)
        let energy = try renderEnergy(through: node)
        XCTAssertGreaterThan(energy, 0.25, "+6 dB should raise energy well above the 0.125 unity reference")
    }

    func test_bypass_forces_unity_overriding_dialed_gain() throws {
        let node = GainNode()
        try node.setParameter("gain", value: 12.0) // would boost ≈4× if active
        node.bypass = true
        let energy = try renderEnergy(through: node)
        XCTAssertEqual(energy, 0.125, accuracy: 0.02, "bypass must pass through at unity regardless of gain")
    }

    // MARK: Snapshot / restore roundtrip

    func test_snapshot_restore_roundtrip_preserves_state() throws {
        let original = GainNode()
        original.displayName = "Output Trim"
        original.bypass = true
        try original.setParameter("gain", value: -9.5)

        let state = original.snapshot()
        XCTAssertEqual(state.parameters["gain"], -9.5)

        let restored = GainNode(id: original.id)
        try restored.restore(from: state)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.displayName, "Output Trim")
        XCTAssertTrue(restored.bypass)
        XCTAssertEqual(restored.parameterValue("gain"), -9.5)
    }

    func test_restore_clamps_out_of_range_gain() throws {
        let state = EffectState(
            typeIdentifier: GainNode.typeIdentifier,
            id: UUID(),
            displayName: "Hot",
            bypass: false,
            wetDryMix: 1.0,
            parameters: ["gain": 999.0],
            extras: [:]
        )
        let node = GainNode()
        try node.restore(from: state)
        XCTAssertEqual(node.parameterValue("gain"), 12.0, "restore must clamp out-of-range gain to the ceiling")
    }

    func test_restore_throws_on_type_identifier_mismatch() {
        let badState = EffectState(
            typeIdentifier: "tnf.reverb",
            id: UUID(),
            displayName: "X",
            bypass: false,
            wetDryMix: 1.0,
            parameters: [:],
            extras: [:]
        )
        XCTAssertThrowsError(try GainNode().restore(from: badState))
    }
}

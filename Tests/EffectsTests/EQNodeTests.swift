import AVFoundation
import NativeTestSupport
import XCTest
@testable import Effects

final class EQNodeTests: XCTestCase {

    // MARK: Read-back diagnostics

    /// Assert that a captured read-back equals `expected`, exactly or within
    /// `accuracy`, with the same comparison a plain `XCTAssertEqual` makes.
    ///
    /// CI has occasionally seen one audio-unit write silently lost on a fresh
    /// node (a frequency reading back as the unit's factory default), and it
    /// has never reproduced locally. When that happens, the bare pair of
    /// numbers does not tell us which fix to choose, so on a mismatch only
    /// this helper adds evidence to the failure message: the node's own
    /// `configurationWarnings`, its `debugStateDescription()`, the OS version,
    /// and the result of writing the expected value once more through the
    /// public API. The assertion is always made on `actual`, the value read
    /// before any of this ran, so the diagnostic write can never turn a
    /// failure into a pass. A passing read-back performs no extra writes.
    private func assertReadBack(
        _ actual: Float?,
        equals expected: Float,
        accuracy: Float? = nil,
        of identifier: String,
        on node: EQNode,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func matches(_ value: Float?) -> Bool {
            guard let accuracy = accuracy else { return value == expected }
            return abs((value ?? 0) - expected) <= accuracy
        }

        var detail = message
        if !matches(actual) {
            // Capture the node's own view before the diagnostic rewrite.
            let warnings = node.configurationWarnings
            let state = node.debugStateDescription()
            let rewrite: String
            if (try? node.setParameter(identifier, value: expected)) == nil {
                rewrite = "rewrite threw"
            } else {
                let reread = node.parameterValue(identifier)
                rewrite = matches(reread)
                    ? "rewrite landed"
                    : "rewrite read back \(reread.map { "\($0)" } ?? "nil")"
            }
            let diagnostics = "[\(identifier) read back \(actual.map { "\($0)" } ?? "nil"); " +
                "configurationWarnings: \(warnings); " +
                "\(rewrite); " +
                "OS: \(ProcessInfo.processInfo.operatingSystemVersionString); " +
                "state: \(state)]"
            detail = detail.isEmpty ? diagnostics : "\(detail) \(diagnostics)"
        }

        if let accuracy = accuracy {
            XCTAssertEqual(actual ?? 0, expected, accuracy: accuracy, detail, file: file, line: line)
        } else {
            XCTAssertEqual(actual, expected, detail, file: file, line: line)
        }
    }

    // MARK: Parameter metadata

    func test_parameter_catalog_lists_four_parameters() {
        let node = EQNode()
        let identifiers = node.parameters.map(\.identifier).sorted()
        XCTAssertEqual(identifiers, ["hp.Q", "hp.frequency", "lp.Q", "lp.frequency"])
    }

    func test_parameter_default_values_match_spec() {
        let node = EQNode()
        // Capture every read-back before any assertion can trigger a
        // diagnostic rewrite.
        let hpFrequency = node.parameterValue("hp.frequency")
        let lpFrequency = node.parameterValue("lp.frequency")
        let hpQ = node.parameterValue("hp.Q")
        let lpQ = node.parameterValue("lp.Q")
        assertReadBack(hpFrequency, equals: 80.0, of: "hp.frequency", on: node)
        assertReadBack(lpFrequency, equals: 800.0, of: "lp.frequency", on: node)
        assertReadBack(hpQ, equals: 0.707, accuracy: 0.001, of: "hp.Q", on: node)
        assertReadBack(lpQ, equals: 0.707, accuracy: 0.001, of: "lp.Q", on: node)
    }

    // MARK: Q persistence (the macOS 15+ regression)

    /// Q must survive a write to the audio unit and a read back out of it.
    ///
    /// `AVAudioUnitEQFilterParameters.bandwidth` — where this class stores Q —
    /// is only a live parameter on filter types that have a bandwidth. On
    /// `.lowPass` / `.highPass` (and the shelf types) a write is accepted and
    /// silently discarded, and the property reads back 0.0. The bands are
    /// therefore configured as `.resonantLowPass` / `.resonantHighPass`.
    ///
    /// This test fails on macOS 15 and newer if the band types regress to the
    /// non-resonant variants. It passed on macOS 14 even while broken, which
    /// is why a single-runner CI never caught it; the OS matrix does.
    func test_Q_survives_a_write_and_read_through_the_audio_unit() throws {
        let node = EQNode()
        try node.setParameter("hp.Q", value: 1.5)
        try node.setParameter("lp.Q", value: 0.9)

        XCTAssertEqual(
            node.parameterValue("hp.Q") ?? 0, 1.5, accuracy: 0.01,
            "hp.Q did not survive the audio unit. A read-back of ~14426 means the band's " +
            "filterType does not carry a bandwidth parameter; ~0.707 means it fell through " +
            "to the default guard."
        )
        XCTAssertEqual(
            node.parameterValue("lp.Q") ?? 0, 0.9, accuracy: 0.01,
            "lp.Q did not survive the audio unit — see hp.Q above."
        )
    }

    /// `snapshot()` feeds `.tnf` files that users are invited to read and edit
    /// by hand. It must never emit a Q outside the range the catalog declares.
    ///
    /// Before the resonant-filter fix this emitted 14426.951, which `restore`
    /// then clamped to the range maximum — so a save/load cycle silently
    /// rewrote the user's Q to 4.0.
    func test_snapshot_never_emits_out_of_range_Q() throws {
        let node = EQNode()
        try node.setParameter("hp.Q", value: 1.5)
        try node.setParameter("lp.Q", value: 0.9)

        let state = node.snapshot()
        let qRange = EQNode.parameterCatalog
            .first { $0.identifier == "hp.Q" }!
            .range

        for key in ["hp.Q", "lp.Q"] {
            let value = try XCTUnwrap(state.parameters[key], "\(key) missing from snapshot")
            XCTAssertTrue(
                qRange.contains(value),
                "snapshot() emitted \(key) = \(value), outside the declared range \(qRange). " +
                "This value is written verbatim into user-facing .tnf preset files."
            )
        }
    }

    /// Two save/load generations must not drift. This is the user-visible
    /// shape of the bug: open a preset, save it, and the Q has changed.
    func test_snapshot_restore_is_stable_across_two_generations() throws {
        let node = EQNode()
        try node.setParameter("hp.Q", value: 1.5)
        try node.setParameter("lp.Q", value: 0.9)

        let first = node.snapshot()
        let reloaded = EQNode(id: node.id)
        try reloaded.restore(from: first)
        let second = reloaded.snapshot()

        for key in ["hp.Q", "lp.Q", "hp.frequency", "lp.frequency"] {
            let reloadedValue = try XCTUnwrap(second.parameters[key])
            let savedValue = try XCTUnwrap(first.parameters[key])
            assertReadBack(
                reloadedValue, equals: savedValue, accuracy: 0.01,
                of: key, on: reloaded,
                "\(key) drifted between save generations."
            )
        }
    }

    // MARK: setParameter dispatch and range enforcement

    func test_setParameter_updates_band_frequency() throws {
        let node = EQNode()
        try node.setParameter("hp.frequency", value: 120.0)
        XCTAssertEqual(node.parameterValue("hp.frequency"), 120.0)
    }

    func test_setParameter_updates_band_Q() throws {
        let node = EQNode()
        try node.setParameter("lp.Q", value: 2.0)
        XCTAssertEqual(node.parameterValue("lp.Q") ?? 0, 2.0, accuracy: 0.001)
    }

    func test_setParameter_throws_on_unknown_identifier() {
        let node = EQNode()
        XCTAssertThrowsError(try node.setParameter("hp.bogus", value: 1.0)) { error in
            guard case EffectParameterError.unknownParameter(let id) = error else {
                XCTFail("Expected unknownParameter, got \(error)")
                return
            }
            XCTAssertEqual(id, "hp.bogus")
        }
    }

    func test_setParameter_throws_on_out_of_range_value() {
        let node = EQNode()
        XCTAssertThrowsError(try node.setParameter("hp.frequency", value: 5.0)) { error in
            guard case EffectParameterError.valueOutOfRange(let id, _, _) = error else {
                XCTFail("Expected valueOutOfRange, got \(error)")
                return
            }
            XCTAssertEqual(id, "hp.frequency")
        }
    }

    // MARK: Bypass and wet/dry endpoints (offline render)

    /// Offline-render `node` against a 1 kHz sine and return the mean square
    /// energy of the rendered output.
    private func renderEnergy(through node: any EffectNode) throws -> Float {
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

        // 1 kHz tone in the EQ's passband (between 80 Hz HP and 800 Hz LP
        // defaults; 1 kHz is in the lowpass stopband so this measurably
        // attenuates with the EQ engaged).
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
                let sample = data[frame]
                sumSquares += sample * sample
            }
        }
        return sumSquares / Float(frames * channels)
    }

    func test_bypass_passes_signal_through_at_unity() throws {
        let node = EQNode()
        node.bypass = true
        let energy = try renderEnergy(through: node)
        // The reference dry energy of a 0.5-amplitude sine is ~0.125.
        XCTAssertGreaterThan(energy, 0.1)
    }

    func test_wetDryMix_zero_yields_dry_signal() throws {
        let node = EQNode()
        node.wetDryMix = 0.0
        let energy = try renderEnergy(through: node)
        XCTAssertGreaterThan(energy, 0.1)
    }

    func test_wetDryMix_one_attenuates_above_passband() throws {
        let node = EQNode()
        node.wetDryMix = 1.0
        // 1 kHz with LP at 800 Hz default should attenuate.
        let energy = try renderEnergy(through: node)
        // Compare against the dry-path baseline. The lowpass attenuation at
        // ~1 kHz is real but the EQ's filter is gentle; we only assert the
        // energy is below the dry baseline.
        let dryNode = EQNode()
        dryNode.bypass = true
        let dryEnergy = try renderEnergy(through: dryNode)
        XCTAssertLessThan(energy, dryEnergy)
    }

    // MARK: Snapshot / restore roundtrip

    func test_snapshot_restore_roundtrip_preserves_state() throws {
        try requireNativeTests()
        let original = EQNode()
        original.displayName = "Custom EQ"
        original.bypass = false
        original.wetDryMix = 0.8
        try original.setParameter("hp.frequency", value: 100.0)
        try original.setParameter("hp.Q", value: 1.5)
        try original.setParameter("lp.frequency", value: 4_000.0)
        try original.setParameter("lp.Q", value: 0.9)

        let state = original.snapshot()
        let restored = EQNode(id: original.id)
        try restored.restore(from: state)

        XCTAssertEqual(restored.displayName, "Custom EQ")
        XCTAssertEqual(restored.bypass, false)
        XCTAssertEqual(restored.wetDryMix, 0.8, accuracy: 0.0001)
        let hpFrequency = restored.parameterValue("hp.frequency")
        let lpFrequency = restored.parameterValue("lp.frequency")
        let hpQ = restored.parameterValue("hp.Q")
        let lpQ = restored.parameterValue("lp.Q")
        assertReadBack(hpFrequency, equals: 100.0, of: "hp.frequency", on: restored)
        assertReadBack(lpFrequency, equals: 4_000.0, of: "lp.frequency", on: restored)
        assertReadBack(hpQ, equals: 1.5, accuracy: 0.01, of: "hp.Q", on: restored)
        assertReadBack(lpQ, equals: 0.9, accuracy: 0.01, of: "lp.Q", on: restored)
    }

    func test_restore_throws_on_type_identifier_mismatch() {
        let node = EQNode()
        let badState = EffectState(
            typeIdentifier: "tnf.reverb",
            id: UUID(),
            displayName: "X",
            bypass: false,
            wetDryMix: 1.0,
            parameters: [:],
            extras: [:]
        )
        XCTAssertThrowsError(try node.restore(from: badState))
    }

    func test_showsWetDryByDefault_is_false_per_ADR_007() {
        XCTAssertFalse(EQNode.showsWetDryByDefault)
    }
}

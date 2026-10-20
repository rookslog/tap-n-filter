import AVFoundation
import Foundation
import XCTest
@testable import Effects

final class ReverbNodeTests: XCTestCase {

    // MARK: Defaults and metadata

    func test_default_preset_is_largeHall() {
        let node = ReverbNode()
        XCTAssertEqual(node.preset, .largeHall)
    }

    func test_room_catalog_exposes_one_named_enum_for_supported_presets() throws {
        let node = ReverbNode()
        let parameter = try roomParameter(on: node)
        guard case .enumValue(let cases) = parameter.unit else {
            return XCTFail("Room must use the generic enum picker")
        }
        guard !cases.isEmpty else {
            return XCTFail("Room picker must have selectable cases")
        }
        XCTAssertFalse(parameter.identifier.isEmpty)
        XCTAssertFalse(parameter.displayName.isEmpty)
        XCTAssertEqual(cases.count, ReverbNode.supportedPresets.count)
        XCTAssertEqual(Set(cases).count, cases.count)
        XCTAssertTrue(cases.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertEqual(parameter.range, 0 ... Float(cases.count - 1))
        let defaultIndex = try XCTUnwrap(
            ReverbNode.supportedPresets.firstIndex { $0.preset == ReverbNode.defaultPreset }
        )
        XCTAssertEqual(parameter.defaultValue, Float(defaultIndex))
        XCTAssertEqual(ReverbNode.parameterCatalog, node.parameters)
    }

    func test_setParameter_throws_for_unknown_identifier() {
        let node = ReverbNode()
        XCTAssertThrowsError(try node.setParameter("anything", value: 1.0))
        XCTAssertNil(node.parameterValue("anything"))
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

    // MARK: Room picker contract — no engine attachment or start

    /// Discover the enum through existing APIs without prescribing a new identifier.
    private func roomParameter(on node: ReverbNode) throws -> EffectParameter {
        XCTAssertEqual(node.parameters.count, 1, "Reverb exposes one factory-room choice")
        return try XCTUnwrap(node.parameters.first { parameter in
            if case .enumValue = parameter.unit { return true }
            return false
        })
    }

    private func roomState(
        parameters: [String: Float] = [:],
        extras: [String: AnyCodableValue]
    ) -> EffectState {
        EffectState(
            typeIdentifier: ReverbNode.typeIdentifier,
            id: UUID(),
            displayName: "Saved Room",
            bypass: true,
            wetDryMix: 0.42,
            parameters: parameters,
            extras: extras
        )
    }

    private func assertInternalReverbIsFullyWet(
        _ node: ReverbNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Existing diagnostic reads the actual private unit; no engine is needed.
        let fields = node.debugStateDescription().split(separator: " ")
        XCTAssertTrue(fields.contains("reverbUnitWetDryMix=100.0"), file: file, line: line)
    }

    func test_room_catalog_keeps_existing_macos_14_factory_rooms() {
        XCTAssertEqual(ReverbNode.supportedPresets.map(\.name), [
            "smallRoom", "mediumRoom", "largeRoom", "largeRoom2", "mediumHall",
            "mediumHall2", "mediumHall3", "largeHall", "largeHall2", "plate",
            "mediumChamber", "largeChamber", "cathedral",
        ])
    }

    func test_room_readback_tracks_initial_and_direct_preset_changes_through_protocol() throws {
        let node = ReverbNode(preset: .plate)
        let parameter = try roomParameter(on: node)
        let effect: any EffectNode = node
        let plateIndex = try XCTUnwrap(ReverbNode.supportedPresets.firstIndex { $0.preset == .plate })
        XCTAssertEqual(effect.parameterValue(parameter.identifier), Float(plateIndex))
        for (index, entry) in ReverbNode.supportedPresets.enumerated() {
            node.preset = entry.preset
            XCTAssertEqual(effect.parameterValue(parameter.identifier), Float(index), entry.name)
            assertInternalReverbIsFullyWet(node)
        }
    }

    func test_room_parameter_changes_every_room_and_json_roundtrips_as_legacy_extras() throws {
        let node = ReverbNode()
        let parameter = try roomParameter(on: node)
        node.bypass = true
        node.wetDryMix = 0.42
        for (index, entry) in ReverbNode.supportedPresets.enumerated() {
            let effect: any EffectNode = node
            try effect.setParameter(parameter.identifier, value: Float(index))
            XCTAssertEqual(node.preset, entry.preset, entry.name)
            XCTAssertEqual(effect.parameterValue(parameter.identifier), Float(index))
            let snapshot = node.snapshot()
            XCTAssertEqual(snapshot.extras["preset"], .string(entry.name))
            XCTAssertTrue(snapshot.parameters.isEmpty, "Persist room only as legacy extras")
            let data = try JSONEncoder().encode(snapshot)
            let decoded = try JSONDecoder().decode(EffectState.self, from: data)
            let restored = ReverbNode()
            try restored.restore(from: decoded)
            XCTAssertEqual(restored.preset, entry.preset)
            XCTAssertEqual(restored.parameterValue(parameter.identifier), Float(index))
            XCTAssertEqual(restored.snapshot(), snapshot)
            assertInternalReverbIsFullyWet(node)
            assertInternalReverbIsFullyWet(restored)
        }
    }

    func test_invalid_room_enum_writes_throw_without_changing_state() throws {
        let node = ReverbNode(preset: .cathedral)
        let parameter = try roomParameter(on: node)
        let before = node.snapshot()
        let invalidValues: [Float] = [
            -1, Float(ReverbNode.supportedPresets.count), 0.5, .nan, .infinity, -.infinity,
        ]
        for value in invalidValues {
            XCTAssertThrowsError(try node.setParameter(parameter.identifier, value: value))
            XCTAssertEqual(node.snapshot(), before)
            XCTAssertEqual(node.preset, .cathedral)
            assertInternalReverbIsFullyWet(node)
        }
    }

    func test_legacy_string_rooms_restore_and_resnapshot_without_numeric_room() throws {
        for entry in ReverbNode.supportedPresets {
            let node = ReverbNode()
            let legacy = roomState(extras: ["preset": .string(entry.name)])
            try node.restore(from: legacy)
            XCTAssertEqual(node.preset, entry.preset)
            XCTAssertEqual(node.snapshot(), legacy)
            assertInternalReverbIsFullyWet(node)
        }
    }

    func test_legacy_extras_win_over_conflicting_numeric_room_and_normalize_snapshot() throws {
        let node = ReverbNode()
        let parameter = try roomParameter(on: node)
        let smallRoomIndex = try XCTUnwrap(
            ReverbNode.supportedPresets.firstIndex { $0.preset == .smallRoom }
        )
        let cathedralIndex = try XCTUnwrap(
            ReverbNode.supportedPresets.firstIndex { $0.preset == .cathedral }
        )
        for extra: AnyCodableValue in [.string("cathedral"), .int(AVAudioUnitReverbPreset.cathedral.rawValue)] {
            try node.restore(from: roomState(
                parameters: [parameter.identifier: Float(smallRoomIndex)],
                extras: ["preset": extra]
            ))
            XCTAssertEqual(node.preset, .cathedral)
            XCTAssertEqual(node.parameterValue(parameter.identifier), Float(cathedralIndex))
            XCTAssertEqual(node.snapshot().extras["preset"], .string("cathedral"))
            XCTAssertTrue(node.snapshot().parameters.isEmpty)
            assertInternalReverbIsFullyWet(node)
        }
    }

    func test_missing_legacy_room_keeps_current_room_and_default_on_fresh_node() throws {
        let missingRoom = roomState(extras: [:])
        let custom = ReverbNode(preset: .plate)
        try custom.restore(from: missingRoom)
        XCTAssertEqual(custom.preset, .plate)
        let fresh = ReverbNode()
        try fresh.restore(from: missingRoom)
        XCTAssertEqual(fresh.preset, ReverbNode.defaultPreset)
    }

    func test_invalid_legacy_rooms_throw_preserve_room_and_allow_recovery() throws {
        let node = ReverbNode(preset: .plate)
        let invalidExtras: [AnyCodableValue] = [.string("unknown-room"), .int(-1), .bool(true), .double(1.5)]
        for extra in invalidExtras {
            node.preset = .plate
            XCTAssertThrowsError(try node.restore(from: roomState(extras: ["preset": extra]))) { error in
                guard case EffectRestoreError.invalidExtra(let key, _) = error else {
                    return XCTFail("Expected invalidExtra, got \(error)")
                }
                XCTAssertEqual(key, "preset")
            }
            XCTAssertEqual(node.preset, .plate)
            try node.restore(from: roomState(extras: ["preset": .string("smallRoom")]))
            XCTAssertEqual(node.preset, .smallRoom)
            assertInternalReverbIsFullyWet(node)
        }
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

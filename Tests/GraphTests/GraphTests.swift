import AVFoundation
import Effects
import NativeTestSupport
import XCTest
@testable import Graph

final class GraphTests: XCTestCase {

    // MARK: Attach with no nodes

    func test_empty_graph_attach_passthrough() throws {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        XCTAssertNoThrow(
            try graph.attach(
                to: engine,
                source: player,
                destination: engine.mainMixerNode
            )
        )
        graph.detach()
    }

    // MARK: Registry

    func test_register_and_makeNode_roundtrip_for_eq() throws {
        let registry = EffectNodeRegistry()
        let node = try registry.makeNode(typeIdentifier: "tnf.eq")
        XCTAssertEqual(type(of: node).typeIdentifier, "tnf.eq")
    }

    func test_register_and_makeNode_roundtrip_for_gain() throws {
        let registry = EffectNodeRegistry()
        let node = try registry.makeNode(typeIdentifier: "tnf.gain")
        XCTAssertEqual(type(of: node).typeIdentifier, "tnf.gain")
    }

    func test_register_and_makeNode_roundtrip_for_reverb() throws {
        let registry = EffectNodeRegistry()
        let node = try registry.makeNode(typeIdentifier: "tnf.reverb")
        XCTAssertEqual(type(of: node).typeIdentifier, "tnf.reverb")
    }

    func test_unknown_type_identifier_throws() {
        let registry = EffectNodeRegistry()
        XCTAssertThrowsError(try registry.makeNode(typeIdentifier: "tnf.nonexistent")) { error in
            guard case RegistryError.unknownTypeIdentifier(let identifier) = error else {
                XCTFail("expected unknownTypeIdentifier, got \(error)")
                return
            }
            XCTAssertEqual(identifier, "tnf.nonexistent")
        }
    }

    func test_registry_lists_default_type_identifiers() {
        let registry = EffectNodeRegistry()
        XCTAssertEqual(registry.registeredTypeIdentifiers, ["tnf.eq", "tnf.gain", "tnf.reverb"])
    }

    // MARK: Snapshot / restore

    func test_snapshot_restore_roundtrip_preserves_chain() throws {
        try requireNativeTests()
        let eq = EQNode()
        try eq.setParameter("hp.frequency", value: 100.0)
        let reverb = ReverbNode(preset: .mediumHall)
        reverb.wetDryMix = 0.4
        let graph = Graph(nodes: [eq, reverb], outputGain: 0.8)

        let preset = graph.snapshot(name: "test")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preset)
        let decoded = try JSONDecoder().decode(GraphPreset.self, from: data)

        let restored = try Graph.restore(from: decoded, using: EffectNodeRegistry())
        XCTAssertEqual(restored.nodes.count, 2)
        XCTAssertEqual(restored.outputGain, 0.8, accuracy: 0.0001)

        let restoredEQ = restored.nodes[0] as? EQNode
        XCTAssertNotNil(restoredEQ)
        // A bare equality diff here once cost a full CI investigation to learn
        // only that the value was 20.0 (U-015). Carry the state that would
        // distinguish "the write never took" from "the roundtrip lost it".
        XCTAssertEqual(
            restoredEQ?.parameterValue("hp.frequency"), 100.0,
            """
            hp.frequency did not survive the roundtrip.
              source snapshot : \(preset.nodes[0].parameters.sorted { $0.key < $1.key })
              decoded         : \(decoded.nodes[0].parameters.sorted { $0.key < $1.key })
              source node     : \(eq.debugStateDescription())
              restored node   : \(restoredEQ?.debugStateDescription() ?? "<nil>")
            A read-back of 20.0 with a clean snapshot and decode means the audio
            unit came up unconfigured rather than the preset path losing data.
            """
        )
        // Node identity must survive the save/load cycle.
        XCTAssertEqual(restoredEQ?.id, eq.id, "EQNode id must be preserved across restore")

        let restoredReverb = restored.nodes[1] as? ReverbNode
        XCTAssertNotNil(restoredReverb)
        XCTAssertEqual(restoredReverb?.preset, .mediumHall)
        XCTAssertEqual(restoredReverb?.wetDryMix ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(restoredReverb?.id, reverb.id, "ReverbNode id must be preserved across restore")
    }

    func test_restore_skips_unknown_effect_with_warning() throws {
        let preset = GraphPreset(
            formatVersion: 1,
            name: "mixed",
            outputGain: 1.0,
            nodes: [
                EffectState(
                    typeIdentifier: "tnf.eq",
                    id: UUID(),
                    displayName: "EQ",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: [:],
                    extras: [:]
                ),
                EffectState(
                    typeIdentifier: "tnf.future-effect",
                    id: UUID(),
                    displayName: "Future",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: [:],
                    extras: [:]
                )
            ]
        )
        let graph = try Graph.restore(from: preset, using: EffectNodeRegistry())
        XCTAssertEqual(graph.nodes.count, 1)
        XCTAssertEqual(graph.lastLoadWarnings.count, 1)
        XCTAssertEqual(
            graph.lastLoadWarnings.first,
            .unknownEffect(typeIdentifier: "tnf.future-effect")
        )
    }

    // MARK: Mutations

    func test_add_remove_move_when_detached() throws {
        let graph = Graph()
        let a = EQNode()
        let b = ReverbNode()
        let c = EQNode()

        XCTAssertNoThrow(try graph.add(a))
        XCTAssertNoThrow(try graph.add(b))
        XCTAssertNoThrow(try graph.add(c, at: 1))

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertTrue(graph.nodes[0] === a)
        XCTAssertTrue(graph.nodes[1] === c)
        XCTAssertTrue(graph.nodes[2] === b)

        XCTAssertNoThrow(try graph.move(from: 0, to: 2))
        XCTAssertTrue(graph.nodes[0] === c)
        XCTAssertTrue(graph.nodes[1] === b)
        XCTAssertTrue(graph.nodes[2] === a)

        XCTAssertNoThrow(try graph.remove(at: 1))
        XCTAssertEqual(graph.nodes.count, 2)
        XCTAssertTrue(graph.nodes[0] === c)
        XCTAssertTrue(graph.nodes[1] === a)
    }

    func test_move_to_end_accepted() throws {
        // destination == nodes.count is the "move to end" idiom used by
        // SwiftUI List.onMove. The pre-fix guard rejected it with invalidIndex.
        let graph = Graph()
        let a = EQNode()
        let b = ReverbNode()
        try graph.add(a)
        try graph.add(b)
        // Move the first node to the end.
        XCTAssertNoThrow(try graph.move(from: 0, to: 2))
        XCTAssertTrue(graph.nodes[0] === b)
        XCTAssertTrue(graph.nodes[1] === a)
    }

    func test_restore_clamps_outputGain() throws {
        let preset = GraphPreset(
            formatVersion: 1,
            name: "gain-test",
            outputGain: 5.0,  // out of the 0–2 range
            nodes: []
        )
        let graph = try Graph.restore(from: preset, using: EffectNodeRegistry())
        XCTAssertEqual(graph.outputGain, 2.0, accuracy: 0.0001,
                       "outputGain must be clamped to 0–2 on restore")
    }

    func test_mutations_against_attached_graph_throw() throws {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)

        XCTAssertThrowsError(try graph.add(EQNode())) { error in
            XCTAssertTrue(error is GraphError)
        }
        XCTAssertThrowsError(try graph.remove(at: 0))
        XCTAssertThrowsError(try graph.move(from: 0, to: 1))

        graph.detach()
    }

    // MARK: Attach with engine stopped — assert lifecycle (ADR-006)

    func test_attach_succeeds_on_stopped_engine() throws {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph(nodes: [EQNode(), ReverbNode()])
        XCTAssertFalse(engine.isRunning)
        XCTAssertNoThrow(
            try graph.attach(
                to: engine,
                source: player,
                destination: engine.mainMixerNode
            )
        )
        graph.detach()
    }

    func test_repeat_attach_throws_alreadyAttached() throws {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let graph = Graph()
        try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)
        XCTAssertThrowsError(
            try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)
        )
        graph.detach()
    }

    // MARK: Always-on safety limiter (ADR-021)

    /// Offline-render a 0.5-amplitude 1 kHz sine through `graph` and return the
    /// peak output magnitude over the steady-state region (after the limiter's
    /// ~12 ms attack settles).
    private func renderSteadyStatePeak(through graph: Graph) throws -> Float {
        try requireNativeTests()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000.0, channels: 2)!
        engine.attach(player)
        try graph.attach(to: engine, source: player, destination: engine.mainMixerNode)

        let frameCount: AVAudioFrameCount = 9_600 // 0.2 s at 48 kHz
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
        graph.detach()

        // Skip the first 50 ms so the limiter's attack ramp does not skew the peak.
        let settleFrame = 2_400
        var peak: Float = 0
        let channels = Int(format.channelCount)
        let frames = Int(outputBuffer.frameLength)
        for channel in 0 ..< channels {
            let data = outputBuffer.floatChannelData![channel]
            for frame in settleFrame ..< frames {
                peak = max(peak, abs(data[frame]))
            }
        }
        return peak
    }

    /// A +12 dB gain on a 0.5-amplitude source would drive peaks to ≈1.99
    /// (0.5 × 3.98) without protection. The always-on limiter must hold the
    /// output at ~0 dBFS. The lower bound also rules out the confound "the
    /// boost silently failed to apply" — a failed boost would leave peaks at
    /// ≈0.5, well under 0.8.
    func test_safety_limiter_clamps_hot_signal() throws {
        let gain = GainNode()
        try gain.setParameter("gain", value: 12.0)
        let graph = Graph(nodes: [gain])
        let peak = try renderSteadyStatePeak(through: graph)
        XCTAssertLessThanOrEqual(peak, 1.1, "safety limiter must hold the output near 0 dBFS")
        XCTAssertGreaterThan(peak, 0.8, "the +12 dB boost should drive the signal up into the limiter")
    }

    /// A quiet signal that never approaches 0 dBFS must pass the limiter
    /// essentially untouched — the safety stage should not colour normal levels.
    func test_safety_limiter_transparent_below_threshold() throws {
        let graph = Graph(nodes: [GainNode()]) // unity
        let peak = try renderSteadyStatePeak(through: graph)
        XCTAssertEqual(peak, 0.5, accuracy: 0.05, "unity-level signal must pass the limiter unchanged")
    }
}

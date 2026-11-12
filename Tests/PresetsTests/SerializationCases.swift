import Effects
import Foundation
import Graph
import Presets

enum SerializationCases {
    enum Failure: Error {
        case stateChanged
        case chainChanged
        case invalidCorruptionFixture
        case lostParametersNotDetected
    }

    private static var eq: EffectState {
        EffectState(
            typeIdentifier: "tnf.eq",
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            displayName: "Custom EQ", bypass: false, wetDryMix: 0.8,
            parameters: ["hp.frequency": 100, "hp.Q": 1.5, "lp.frequency": 4000, "lp.Q": 0.9],
            extras: ["label": .string("synthetic"), "count": .int(2),
                     "amount": .double(0.125), "enabled": .bool(true)]
        )
    }

    private static var chain: GraphPreset {
        GraphPreset(name: "Synthetic chain", outputGain: 0.8, nodes: [
            eq,
            EffectState(
                typeIdentifier: "tnf.reverb",
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                displayName: "Custom Reverb", bypass: true, wetDryMix: 0.4,
                parameters: [:], extras: ["preset": .string("mediumHall")]
            )
        ])
    }

    static func effectStateRoundTrip() throws {
        let expected = eq
        var state = expected
        for _ in 0..<2 {
            state = try JSONDecoder().decode(EffectState.self, from: JSONEncoder().encode(state))
            guard state == expected else { throw Failure.stateChanged }
        }
    }

    private static func verifyChain(_ actual: GraphPreset, expected: GraphPreset) throws {
        guard actual == expected else { throw Failure.chainChanged }
    }

    static func chainRoundTrip() throws {
        let expected = chain
        var preset = expected
        for _ in 0..<2 {
            let data = try JSONEncoder().encode(preset)
            preset = try PresetStore.decode(data, source: URL(fileURLWithPath: "synthetic.tnf"))
            try verifyChain(preset, expected: expected)
        }
    }

    static func lostParametersAreDetected() throws {
        let expected = chain
        let data = try JSONEncoder().encode(expected)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var nodes = object["nodes"] as? [[String: Any]],
              var parameters = nodes[0]["parameters"] as? [String: Any] else {
            throw Failure.invalidCorruptionFixture
        }
        parameters.removeValue(forKey: "hp.frequency")
        parameters.removeValue(forKey: "hp.Q")
        nodes[0]["parameters"] = parameters
        object["nodes"] = nodes
        let corrupted = try PresetStore.decode(
            JSONSerialization.data(withJSONObject: object), source: URL(fileURLWithPath: "synthetic.tnf")
        )
        do {
            try verifyChain(corrupted, expected: expected)
        } catch Failure.chainChanged {
            return
        }
        throw Failure.lostParametersNotDetected
    }
}

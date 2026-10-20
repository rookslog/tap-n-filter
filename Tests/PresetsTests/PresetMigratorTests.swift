import Effects
import Graph
import XCTest
@testable import Presets

/// Guards the repair of EQ Q values written by builds that stored Q on a
/// filter type which discarded it.
///
/// Until the resonant-filter fix, `EQNode` kept Q in
/// `AVAudioUnitEQFilterParameters.bandwidth` on `.highPass` / `.lowPass`
/// bands, which have no bandwidth parameter. The write was discarded, the
/// property read back 0.0, and on macOS 15+ `snapshot()` wrote 14426.951 into
/// the `.tnf` file. Unrepaired, `EQNode.restore` clamps that to the top of the
/// declared range — inaudible while Q was inert, maximum resonance now that
/// the resonant filters make Q real.
final class PresetMigratorTests: XCTestCase {

    /// The value earlier builds actually wrote:
    /// `1 / (2 * sinh(0.0001 * ln2 / 2))`.
    private static let corruptSentinel: Float = 14_426.951

    private func eqPreset(hpQ: Float, lpQ: Float) -> GraphPreset {
        GraphPreset(
            name: "fixture",
            outputGain: 1.0,
            nodes: [
                EffectState(
                    typeIdentifier: "tnf.eq",
                    id: UUID(),
                    displayName: "EQ",
                    bypass: false,
                    wetDryMix: 1.0,
                    parameters: [
                        "hp.frequency": 80.0,
                        "hp.Q": hpQ,
                        "lp.frequency": 800.0,
                        "lp.Q": lpQ
                    ],
                    extras: [:]
                )
            ]
        )
    }

    func test_migrate_repairs_corrupt_Q_to_default_not_range_maximum() throws {
        let migrated = try PresetMigrator.migrate(
            eqPreset(hpQ: Self.corruptSentinel, lpQ: Self.corruptSentinel)
        )
        let parameters = migrated.nodes[0].parameters

        XCTAssertEqual(
            parameters["hp.Q"] ?? 0, 0.707, accuracy: 0.001,
            "Corrupt hp.Q must be reset to the catalog default. A value of 4.0 means the " +
            "repair did not run and EQNode.restore clamped to the range maximum instead."
        )
        XCTAssertEqual(parameters["lp.Q"] ?? 0, 0.707, accuracy: 0.001)
    }

    func test_migrate_leaves_frequencies_untouched() throws {
        let migrated = try PresetMigrator.migrate(
            eqPreset(hpQ: Self.corruptSentinel, lpQ: Self.corruptSentinel)
        )
        XCTAssertEqual(migrated.nodes[0].parameters["hp.frequency"], 80.0)
        XCTAssertEqual(migrated.nodes[0].parameters["lp.frequency"], 800.0)
    }

    /// The repair must not touch a Q the user could plausibly have chosen —
    /// including one sitting exactly at the top of the declared range, which
    /// is the value most easily confused with the clamped corruption.
    func test_migrate_preserves_legitimate_Q_values() throws {
        for q in [Float(0.5), 0.707, 2.5, 4.0] {
            let migrated = try PresetMigrator.migrate(eqPreset(hpQ: q, lpQ: q))
            XCTAssertEqual(
                migrated.nodes[0].parameters["hp.Q"], q,
                "Legitimate Q \(q) was modified by the corruption repair."
            )
        }
    }

    func test_migrate_ignores_non_eq_nodes() throws {
        let preset = GraphPreset(
            name: "fixture",
            outputGain: 1.0,
            nodes: [
                EffectState(
                    typeIdentifier: "tnf.reverb",
                    id: UUID(),
                    displayName: "Reverb",
                    bypass: false,
                    wetDryMix: 0.5,
                    parameters: ["hp.Q": Self.corruptSentinel],
                    extras: [:]
                )
            ]
        )
        XCTAssertEqual(
            try PresetMigrator.migrate(preset).nodes[0].parameters["hp.Q"],
            Self.corruptSentinel,
            "The repair is scoped to tnf.eq and must not reinterpret another type's parameters."
        )
    }

    /// End-to-end: a repaired preset must land on the node as the default,
    /// which is the property that actually protects the user's ears.
    func test_repaired_preset_restores_onto_node_at_default_Q() throws {
        let migrated = try PresetMigrator.migrate(
            eqPreset(hpQ: Self.corruptSentinel, lpQ: Self.corruptSentinel)
        )
        let node = EQNode(id: migrated.nodes[0].id)
        try node.restore(from: migrated.nodes[0])

        XCTAssertEqual(
            node.parameterValue("hp.Q") ?? 0, 0.707, accuracy: 0.01,
            "A preset saved by a corrupt build must load at the default Q, not at maximum " +
            "resonance."
        )
    }
}

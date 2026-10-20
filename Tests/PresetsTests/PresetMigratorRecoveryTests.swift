import Effects
import Foundation
import Graph
import XCTest
@testable import Presets

final class PresetMigratorRecoveryTests: XCTestCase {

    // Future-version input must be a recoverable error, never a process trap.
    func test_future_format_throws_typed_error_with_offending_version() {
        for version in [PresetMigrator.currentFormatVersion + 1, Int.max] {
            let preset = GraphPreset(formatVersion: version, name: "future", outputGain: 0.25, nodes: [])

            XCTAssertThrowsError(try PresetMigrator.migrate(preset)) { error in
                guard case PresetMigrationError.unsupportedFormatVersion(let actual) = error else {
                    XCTFail("Expected a recoverable migration error, got \(error)")
                    return
                }
                XCTAssertEqual(actual, version)
            }
        }
    }

    func test_supported_versions_round_trip_repair_without_losing_legal_Q_or_reverb_extras() throws {
        // Version 0 is synthetic: preserve the existing <= current acceptance,
        // without claiming that a historical version-0 schema ever shipped.
        for version in [0, PresetMigrator.currentFormatVersion] {
            let eq = EffectState(
                typeIdentifier: "tnf.eq", id: UUID(), displayName: "Custom EQ",
                bypass: true, wetDryMix: 0.75,
                parameters: ["hp.frequency": 80, "hp.Q": 14_426.951, "lp.frequency": 800, "lp.Q": 4],
                extras: ["fixture": .string("preserve")]
            )
            let reverb = EffectState(
                typeIdentifier: "tnf.reverb", id: UUID(), displayName: "Custom Reverb",
                bypass: false, wetDryMix: 0.7, parameters: [:], extras: ["preset": .string("largeHall")]
            )
            let original = GraphPreset(
                formatVersion: version, name: "supported", outputGain: 0.4, nodes: [eq, reverb]
            )
            let decoded = try JSONDecoder().decode(GraphPreset.self, from: JSONEncoder().encode(original))
            let migrated = try PresetMigrator.migrate(decoded)
            var expectedParameters = eq.parameters
            expectedParameters["hp.Q"] = 0.707
            let expectedEQ = EffectState(
                typeIdentifier: eq.typeIdentifier, id: eq.id, displayName: eq.displayName,
                bypass: eq.bypass, wetDryMix: eq.wetDryMix, parameters: expectedParameters, extras: eq.extras
            )
            XCTAssertEqual(migrated, GraphPreset(
                formatVersion: version, name: original.name, outputGain: original.outputGain,
                nodes: [expectedEQ, reverb]
            ))
            let roundTripped = try JSONDecoder().decode(
                GraphPreset.self, from: JSONEncoder().encode(migrated)
            )
            XCTAssertEqual(try PresetMigrator.migrate(roundTripped), migrated, "Repair must be idempotent")
        }
    }

    func test_bundled_presets_remain_unchanged_by_migration() throws {
        for bundled in FactoryPresets.all {
            let preset = try FactoryPresets.load(named: bundled.name)
            XCTAssertEqual(try PresetMigrator.migrate(preset), preset)
        }
    }
}

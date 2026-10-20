import Effects
import Foundation
import Graph

/// Recoverable failures when migrating a decoded preset.
public enum PresetMigrationError: Error, Equatable, LocalizedError {
    /// The input requires a format newer than this build understands.
    case unsupportedFormatVersion(Int)

    /// Description suitable for a user-facing load error.
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "Preset format version \(version) is newer than supported version "
                + "\(PresetMigrator.currentFormatVersion)."
        }
    }
}

/// Repairs a decoded preset before it becomes a `Graph`.
///
/// Two distinct jobs live here. The first is format-version migration: V1
/// ships `formatVersion = 1` with no prior versions, so the version switch
/// does not exist yet, but the entry point is in the right place for when
/// V2 bumps the format.
///
/// The second is value repair, which turned out to be the job that arrived
/// first. A preset can be schema-valid and still contain a value no user
/// chose, written by a bug in an earlier build. Those are invisible to a
/// version check, so they are repaired unconditionally — see
/// `repairCorruptEQQ`.
///
/// Every load path routes through here (`loadPreset`, `loadFactoryPreset`,
/// and session restore in `AppViewModel`), so a repair added here reaches
/// every preset the app opens.
public enum PresetMigrator {

    /// Current format version this build understands.
    public static let currentFormatVersion: Int = 1

    /// Identifiers of the EQ Q parameters that could be written corrupt.
    private static let eqQParameterIdentifiers: Set<String> = ["hp.Q", "lp.Q"]

    /// Any Q at or above this is not a Q a user could have chosen.
    ///
    /// The declared range is 0.5...4.0. The corruption wrote 14426.951, so
    /// anything three orders of magnitude above the legal maximum is the
    /// sentinel rather than an aggressive setting. Matching on a threshold
    /// rather than the exact float avoids depending on the bit pattern of a
    /// value produced by a transcendental function.
    private static let corruptQThreshold: Float = 100.0

    /// Q restored in place of a corrupt value. Matches `EQNode`'s catalog
    /// default; deliberately not the range maximum, which is what the
    /// unmigrated clamp would have produced.
    private static let defaultQ: Float = 0.707

    /// Migrate `preset` forward to the current format version, and repair
    /// values that earlier builds could write incorrectly.
    ///
    /// The format itself is still at version 1, so there is no version switch
    /// yet. The repair below is deliberately not gated on `formatVersion`:
    /// the corruption did not change the schema, so a corrupt file is
    /// indistinguishable from a clean one by version alone.
    ///
    /// - Throws: `PresetMigrationError.unsupportedFormatVersion` when the
    ///   decoded preset targets a newer format. No values are repaired first.
    public static func migrate(_ preset: GraphPreset) throws -> GraphPreset {
        guard preset.formatVersion <= currentFormatVersion else {
            throw PresetMigrationError.unsupportedFormatVersion(preset.formatVersion)
        }
        return repairCorruptEQQ(preset)
    }

    /// Repair EQ Q values written by builds that stored Q on a filter type
    /// which discarded it.
    ///
    /// Until the resonant-filter fix, `EQNode` kept the user-facing Q in
    /// `AVAudioUnitEQFilterParameters.bandwidth` on `.highPass` / `.lowPass`
    /// bands. Those filter types have no bandwidth parameter: the write was
    /// discarded and the property read back 0.0. On macOS 15 and later,
    /// `snapshot()` therefore wrote 14426.951 into the `.tnf` file — the old
    /// `max(bandwidth, 0.0001)` floor run through the Q conversion.
    ///
    /// Left alone, `EQNode.restore` clamps that to the top of the declared
    /// 0.5...4.0 range. That was harmless while Q was inert, but the resonant
    /// filters make Q audible, so an untouched file would now load at maximum
    /// resonance — the fix would convert silent data corruption into a loud
    /// surprise. Reset to the default instead: the value was never a user's
    /// choice, and the default is what the preset effectively sounded like
    /// when it was saved.
    private static func repairCorruptEQQ(_ preset: GraphPreset) -> GraphPreset {
        var didRepairAny = false

        let repairedNodes: [EffectState] = preset.nodes.map { node in
            guard node.typeIdentifier == "tnf.eq" else { return node }

            var parameters = node.parameters
            var didRepairNode = false
            for identifier in eqQParameterIdentifiers {
                guard let value = parameters[identifier], value >= corruptQThreshold else {
                    continue
                }
                parameters[identifier] = defaultQ
                didRepairNode = true
            }
            guard didRepairNode else { return node }
            didRepairAny = true

            return EffectState(
                typeIdentifier: node.typeIdentifier,
                id: node.id,
                displayName: node.displayName,
                bypass: node.bypass,
                wetDryMix: node.wetDryMix,
                parameters: parameters,
                extras: node.extras
            )
        }

        guard didRepairAny else { return preset }

        return GraphPreset(
            formatVersion: preset.formatVersion,
            name: preset.name,
            outputGain: preset.outputGain,
            nodes: repairedNodes
        )
    }
}

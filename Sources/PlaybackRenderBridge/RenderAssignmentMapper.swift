import Foundation
import EffectCatalog
import PlaybackDSP
import SoundModel

public enum RenderBridgeError: Error, Equatable {
    case invalidIdentity
    case invalidConfiguration
    case invalidSnapshot(String)
    case nonIncreasingIntent
    case staleEpoch
    case exhaustedGeneration
    case native(UInt32, Int32)
    case closed
    case consumerNotQuiesced
}

public struct RenderProcessingFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: UInt32
    public let maximumFrames: UInt32
    public init(sampleRate: Double, channels: UInt32, maximumFrames: UInt32) throws {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels), (1...4_096).contains(maximumFrames) else {
            throw RenderBridgeError.invalidConfiguration
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.maximumFrames = maximumFrames
    }

    public var configuration: FRConfig {
        var config = FRConfig()
        config.abi_version = UInt32(FR_ABI_VERSION)
        config.channels = channels
        config.maximum_frames = maximumFrames
        config.sample_rate = sampleRate
        config.transition_frames = UInt32(ceil(sampleRate * 0.020))
        config.smoothing_frames = UInt32(ceil(sampleRate * 0.010))
        config.parameter_quantum = 16
        config.transition_curve = FR_LINEAR.rawValue
        config.peak_ceiling = 0.95
        config.limiter_release_seconds = 0.080
        return config
    }
}

public struct RenderOccurrence: Hashable, Sendable {
    public let path: [UUID]
    public let part: UUID
    public init(path: [UUID], part: UUID) { self.path = path; self.part = part }
}

public struct NativeRenderPart: Equatable, Sendable {
    public let key: UInt64
    public let kind: UInt32
    public let preset: UInt32
    public let parameterMask: UInt32
}

public struct CutoffAdaptation: Equatable, Sendable {
    public let occurrence: RenderOccurrence
    public let parameter: String
    public let authoredHz: Double
    public let loweredHz: Double
}

public struct LoweredRenderState {
    public var program: FRProgram
    public var frame: FRFrame
    public let signature: [NativeRenderPart]
    public let adaptations: [CutoffAdaptation]
}

public struct RenderAssignmentMapper {
    private var keys: [RenderOccurrence: UInt64] = [:]
    private var nextKey: UInt64 = 1
    public init() {}

    public mutating func lower(_ assignment: ListeningAssignment, format: RenderProcessingFormat,
                               token: FRToken) throws -> LoweredRenderState {
        try lower(ListeningRenderAssignment(legacy: assignment), format: format, token: token)
    }

    public mutating func lower(_ assignment: ListeningRenderAssignment, format: RenderProcessingFormat,
                               token: FRToken) throws -> LoweredRenderState {
        var candidate = self
        guard !assignment.bundleIdentifier.isEmpty,
              assignment.bundleIdentifier == assignment.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw RenderBridgeError.invalidSnapshot("bundle identity")
        }
        let result = try candidate.map(assignment.parts, format: format, token: token)
        self = candidate
        return result
    }

    /// Nominal structural/capability witness only, not the eventual capture/device format.
    /// No runtime mapper keys or lowered/adapted values escape this admission boundary.
    public static func admitCapabilities(_ snapshot: ListeningRenderSnapshot) throws {
        let format = try RenderProcessingFormat(sampleRate: 48_000, channels: 2, maximumFrames: 512)
        for assignment in snapshot.assignments {
            var mapper = Self()
            let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
            _ = try mapper.lower(assignment, format: format, token: token)
        }
    }

    public static func admitParts(_ parts: [ListeningRenderPart]) throws {
        let format = try RenderProcessingFormat(sampleRate: 48_000, channels: 2, maximumFrames: 512)
        var mapper = Self()
        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
        _ = try mapper.map(parts, format: format, token: token)
    }

    private mutating func map(_ parts: [ListeningRenderPart], format: RenderProcessingFormat,
                              token: FRToken) throws -> LoweredRenderState {
        guard parts.count <= Int(FR_MAX_PARTS) else { throw RenderBridgeError.invalidSnapshot("part capacity") }
        var program = FRProgram(), frame = FRFrame(), config = format.configuration
        frame.token = token
        var signature: [NativeRenderPart] = [], adaptations: [CutoffAdaptation] = []
        var occurrences: Set<RenderOccurrence> = []
        for (index, part) in parts.enumerated() {
            let occurrence = RenderOccurrence(path: part.path, part: part.id)
            guard occurrences.insert(occurrence).inserted else {
                throw RenderBridgeError.invalidSnapshot("duplicate occurrence")
            }
            guard let spec = EffectCatalog.effect(part.type) else {
                throw RenderBridgeError.invalidSnapshot("unsupported part type \(part.type)")
            }
            var values: [String: Double] = [:]
            for parameter in part.parameters {
                guard parameter.value.isFinite, values.updateValue(parameter.value, forKey: parameter.key) == nil else {
                    throw RenderBridgeError.invalidSnapshot("duplicate or nonfinite parameter \(parameter.key)")
                }
            }
            var required = Set(spec.parameters.filter { !$0.optional }.map(\.key))
            var allowed = Set(spec.parameters.map(\.key))
            if let preset = spec.presetKey { required.insert(preset); allowed.insert(preset) }
            guard required.isSubset(of: Set(values.keys)), Set(values.keys).isSubset(of: allowed) else {
                throw RenderBridgeError.invalidSnapshot("missing or extra parameter for \(part.type)")
            }
            let preset: UInt32
            if let name = spec.presetKey, let value = values[name] {
                guard value >= 0, value <= Double(UInt32.max), value.rounded(.towardZero) == value,
                      spec.presets.contains(UInt32(value)) else {
                    throw RenderBridgeError.invalidSnapshot("unsupported preset \(name)")
                }
                preset = UInt32(value)
            } else { preset = 0 }
            let parameters = spec.parameters.filter { values[$0.key] != nil }
            let mask = parameters.reduce(UInt32(0)) { $0 | (1 << $1.id) }
            let key: UInt64
            if let known = keys[occurrence] { key = known }
            else {
                guard nextKey < UInt64.max else { throw RenderBridgeError.exhaustedGeneration }
                key = nextKey; nextKey += 1; keys[occurrence] = key
            }
            signature.append(NativeRenderPart(key: key, kind: spec.kind, preset: preset, parameterMask: mask))
            _ = pd_program_part(&program, UInt32(index), key, spec.kind, preset, mask)
            for parameter in parameters {
                guard let raw = values[parameter.key], (parameter.lower...parameter.upper).contains(raw) else {
                    throw RenderBridgeError.invalidSnapshot("out-of-range parameter \(parameter.key)")
                }
                let lowered: Double
                if parameter.cutoff {
                    lowered = min(raw, min(parameter.upper, 0.49 * format.sampleRate))
                    if lowered != raw {
                        adaptations.append(CutoffAdaptation(occurrence: occurrence, parameter: parameter.key,
                                                            authoredHz: raw, loweredHz: lowered))
                    }
                } else { lowered = raw }
                _ = pd_frame_value(&frame, frame.count, key, parameter.id, Float(lowered))
            }
        }
        let result = fr_validate(&config, &program, &frame)
        guard result == FR_OK else { throw RenderBridgeError.native(result.rawValue, 0) }
        return LoweredRenderState(program: program, frame: frame, signature: signature, adaptations: adaptations)
    }
}

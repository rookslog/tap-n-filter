import Foundation
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

    private struct Parameter {
        let name: String
        let id: UInt32
        let range: ClosedRange<Double>
        init(_ name: String, _ id: FRParameter, _ range: ClosedRange<Double>) {
            self.name = name; self.id = id.rawValue; self.range = range
        }
    }

    private struct Kind {
        let id: FRPartKind
        let parameters: [Parameter]
        let preset: String?
        let presets: ClosedRange<Double>
    }

    private func kind(_ name: String) throws -> Kind {
        switch name {
        case "deviceEQ": return Kind(id: FR_DEVICE_EQ, parameters: [
            Parameter("highPassHz", FR_HP_HZ, 20...20_000),
            Parameter("lowPassHz", FR_LP_HZ, 20...20_000)], preset: nil, presets: 0...0)
        case "deviceColour": return Kind(id: FR_DEVICE_COLOUR, parameters: [
            Parameter("wetPercent", FR_WET_PERCENT, 0...100),
            Parameter("preGainDb", FR_PREGAIN_DB, -80...20)], preset: "factoryPreset", presets: 1...2)
        case "placeEQ": return Kind(id: FR_PLACE_EQ, parameters: [
            Parameter("lowPassHz", FR_LP_HZ, 20...20_000)], preset: nil, presets: 0...0)
        case "reverb": return Kind(id: FR_REVERB, parameters: [
            Parameter("wetPercent", FR_WET_PERCENT, 0...100)], preset: "roomPreset", presets: 1...3)
        case "sizedReverb": return Kind(id: FR_SIZED_REVERB, parameters: [
            Parameter("wetPercent", FR_WET_PERCENT, 0...100),
            Parameter("roomSize", FR_ROOM_SIZE, 0...1)], preset: "roomPreset", presets: 1...3)
        case "dynamics": return Kind(id: FR_DYNAMICS, parameters: [
            Parameter("thresholdDb", FR_THRESHOLD_DB, -40...20),
            Parameter("headroomDb", FR_HEADROOM_DB, 0.1...40),
            Parameter("expansionRatio", FR_EXPANSION_RATIO, 1...50),
            Parameter("expansionThresholdDb", FR_EXPANSION_THRESHOLD_DB, -120...0),
            Parameter("attackSeconds", FR_ATTACK_SECONDS, 0.001...0.2),
            Parameter("releaseSeconds", FR_RELEASE_SECONDS, 0.01...3),
            Parameter("makeupDb", FR_MAKEUP_DB, -40...40)], preset: nil, presets: 0...0)
        case "gain": return Kind(id: FR_GAIN, parameters: [
            Parameter("gainDb", FR_GAIN_DB, -96...6)], preset: nil, presets: 0...0)
        default: throw RenderBridgeError.invalidSnapshot("unsupported part type \(name)")
        }
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
            let spec = try kind(part.type)
            var values: [String: Double] = [:]
            for parameter in part.parameters {
                guard parameter.value.isFinite, values.updateValue(parameter.value, forKey: parameter.key) == nil else {
                    throw RenderBridgeError.invalidSnapshot("duplicate or nonfinite parameter \(parameter.key)")
                }
            }
            var expected = Set(spec.parameters.map(\.name))
            if let preset = spec.preset { expected.insert(preset) }
            guard Set(values.keys) == expected else {
                throw RenderBridgeError.invalidSnapshot("missing or extra parameter for \(part.type)")
            }
            let preset: UInt32
            if let name = spec.preset, let value = values[name] {
                guard spec.presets.contains(value), value.rounded(.towardZero) == value else {
                    throw RenderBridgeError.invalidSnapshot("unsupported preset \(name)")
                }
                preset = UInt32(value)
            } else { preset = 0 }
            let key: UInt64
            if let known = keys[occurrence] { key = known }
            else {
                guard nextKey < UInt64.max else { throw RenderBridgeError.exhaustedGeneration }
                key = nextKey; nextKey += 1; keys[occurrence] = key
            }
            signature.append(NativeRenderPart(key: key, kind: spec.id.rawValue, preset: preset))
            _ = pd_program_part(&program, UInt32(index), key, spec.id.rawValue, preset)
            for parameter in spec.parameters {
                guard let raw = values[parameter.name], parameter.range.contains(raw) else {
                    throw RenderBridgeError.invalidSnapshot("out-of-range parameter \(parameter.name)")
                }
                let lowered: Double
                if parameter.id == FR_HP_HZ.rawValue || parameter.id == FR_LP_HZ.rawValue {
                    lowered = min(raw, min(20_000, 0.49 * format.sampleRate))
                    if lowered != raw {
                        adaptations.append(CutoffAdaptation(occurrence: occurrence, parameter: parameter.name,
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

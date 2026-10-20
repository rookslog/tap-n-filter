import AVFoundation
import Foundation

/// Reverberation effect built on `AVAudioUnitReverb`'s factory presets.
///
/// The preset (a categorical choice) is held in `EffectState.extras` as a
/// stable string name. We map the string to `AVAudioUnitReverbPreset` rather
/// than serializing the raw `Int` rawValue so future SDK reorderings don't
/// break older `.tnf` files.
///
/// `wetDryMix` is implemented using the same parallel-mixer pattern as
/// `EQNode`, not the underlying `AVAudioUnitReverb.wetDryMix` parameter. Owning
/// the mix externally keeps every node's wet/dry behaviour consistent with the
/// protocol's "Wet/dry mixing convention" section. The underlying reverb unit
/// runs at 100% wet internally.
public final class ReverbNode: EffectNode {

    // MARK: Type-level metadata

    public static let typeIdentifier: String = "tnf.reverb"

    private static let defaultDisplayName: String = "Reverb"

    private static let roomParameterIdentifier: String = "room"

    /// Default preset chosen to produce a noticeable but musical hall sound
    /// suitable as the ear-test baseline. Documented in the
    /// `distant-engines` preset spec.
    public static let defaultPreset: AVAudioUnitReverbPreset = .largeHall

    /// Bus index where the dry path connects on `outputBus`. Conventionally 0.
    private static let dryInputBusIndex: AVAudioNodeBus = 0

    /// Bus index where the wet path connects on `outputBus`. Conventionally 1.
    private static let wetInputBusIndex: AVAudioNodeBus = 1

    /// See `EQNode.sourceFanOutBus`: the input mixer's only output bus.
    private static let sourceFanOutBus: AVAudioNodeBus = 0

    // MARK: Instance state

    /// Per-instance identifier preserved across save/load cycles.
    public var id: UUID
    /// User-visible name for this node instance (may differ from the type default).
    public var displayName: String

    public var bypass: Bool {
        didSet { applyMixGains() }
    }

    public var wetDryMix: Float {
        didSet { applyMixGains() }
    }

    /// The currently-loaded factory preset. Setting it re-loads the underlying
    /// `AVAudioUnitReverb`'s preset.
    public var preset: AVAudioUnitReverbPreset {
        didSet { reverb.loadFactoryPreset(preset) }
    }

    /// The graph connects audio into this node on bus 0.
    public let inputBus: AVAudioMixerNode
    /// The graph reads audio from this node on bus 0.
    public let outputBus: AVAudioMixerNode
    private let dryMixer: AVAudioMixerNode
    /// See note on `EQNode.wetMixer`: a small trampoline mixer between the
    /// `AVAudioUnit` (which does not conform to `AVAudioMixing`) and
    /// `outputBus`.
    private let wetMixer: AVAudioMixerNode
    private let reverb: AVAudioUnitReverb

    private weak var attachedEngine: AVAudioEngine?

    // MARK: Init

    /// Convenience initializer used by the registry — produces a node in
    /// the default state.
    public convenience init() {
        self.init(preset: Self.defaultPreset)
    }

    /// Full initializer. `displayName` defaults to `"Reverb"` when nil.
    /// `wetDryMix` defaults to 0.5 (equal blend), matching the typical
    /// "add some room" use case. The underlying unit runs at 100% wet;
    /// the parallel-mixer pattern manages the mix externally.
    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        bypass: Bool = false,
        wetDryMix: Float = 0.5,
        preset: AVAudioUnitReverbPreset
    ) {
        self.id = id
        self.displayName = displayName ?? Self.defaultDisplayName
        self.bypass = bypass
        self.wetDryMix = wetDryMix
        self.preset = preset
        self.inputBus = AVAudioMixerNode()
        self.outputBus = AVAudioMixerNode()
        self.dryMixer = AVAudioMixerNode()
        self.wetMixer = AVAudioMixerNode()
        self.reverb = AVAudioUnitReverb()

        // The underlying unit runs at 100% wet; the parallel mixer pattern
        // implements wet/dry externally for parity with other effect nodes.
        reverb.wetDryMix = 100.0
        reverb.loadFactoryPreset(preset)
    }

    // MARK: Parameters

    /// The room picker uses zero-based indices into `supportedPresets`.
    /// Indices are UI values only; snapshots persist the stable legacy name.
    public static let parameterCatalog: [EffectParameter] = [
        EffectParameter(
            identifier: roomParameterIdentifier,
            displayName: "Room",
            range: 0 ... Float(supportedPresets.count - 1),
            defaultValue: Float(supportedPresets.firstIndex { $0.preset == defaultPreset } ?? 0),
            unit: .enumValue(cases: [
                "Small Room", "Medium Room", "Large Room", "Large Room 2",
                "Medium Hall", "Medium Hall 2", "Medium Hall 3", "Large Hall",
                "Large Hall 2", "Plate", "Medium Chamber", "Large Chamber", "Cathedral",
            ])
        ),
    ]

    public var parameters: [EffectParameter] { Self.parameterCatalog }

    public func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = Self.parameterCatalog.first(where: { $0.identifier == identifier }) else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        // Check finiteness, range, and integrality before converting to Int;
        // malformed enum values must neither trap nor select a different room.
        guard value.isFinite, parameter.range.contains(value), value.rounded() == value else {
            throw EffectParameterError.valueOutOfRange(
                identifier: identifier,
                value: value,
                range: parameter.range
            )
        }
        preset = Self.supportedPresets[Int(value)].preset
    }

    /// Read the current room index, including changes made through `preset`.
    /// Unknown identifiers or unsupported direct preset values return `nil`.
    public func parameterValue(_ identifier: String) -> Float? {
        guard identifier == Self.roomParameterIdentifier,
            let index = Self.supportedPresets.firstIndex(where: { $0.preset == preset })
        else { return nil }
        return Float(index)
    }

    // MARK: Attach / detach

    public func attach(to engine: AVAudioEngine) throws {
        engine.attach(inputBus)
        engine.attach(outputBus)
        engine.attach(dryMixer)
        engine.attach(wetMixer)
        engine.attach(reverb)

        let fanOut: [AVAudioConnectionPoint] = [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: reverb, bus: 0)
        ]
        engine.connect(
            inputBus,
            to: fanOut,
            fromBus: Self.sourceFanOutBus,
            format: nil
        )

        engine.connect(reverb, to: wetMixer, format: nil)
        engine.connect(
            dryMixer,
            to: outputBus,
            fromBus: 0,
            toBus: Self.dryInputBusIndex,
            format: nil
        )
        engine.connect(
            wetMixer,
            to: outputBus,
            fromBus: 0,
            toBus: Self.wetInputBusIndex,
            format: nil
        )

        applyMixGains()
        attachedEngine = engine
    }

    public func detach() {
        guard let engine = attachedEngine else { return }
        engine.detach(reverb)
        engine.detach(wetMixer)
        engine.detach(dryMixer)
        engine.detach(outputBus)
        engine.detach(inputBus)
        attachedEngine = nil
    }

    private func applyMixGains() {
        let clampedMix = min(max(wetDryMix, 0.0), 1.0)
        let wetGain: Float = bypass ? 0.0 : clampedMix
        let dryGain: Float = bypass ? 1.0 : (1.0 - clampedMix)

        // EXP-031 fix: always keep the internal mixers' master `.volume`
        // at unity. The documented way to control wet/dry mix in
        // AVAudioMixing is via `AVAudioMixingDestination.volume` on the
        // downstream mixer's per-input-bus destination, NOT via the
        // upstream mixer's `.volume`. The previous fallback path
        // (`mixer.volume = gain` when `destination(forMixer:bus:)`
        // returned nil) could silently set `dryMixer.volume = 0` at
        // attach time when the destination was transiently unavailable;
        // once set, the master volume stayed at 0 and the dry path was
        // muted forever, regardless of later destination.volume sets.
        // Observed in EXP-031 run 2 with `dryMixerVol=0.0` while
        // `dryDestVol=1.0` — bypass=true should have routed audio
        // through the dry path but the upstream mixer was muted.
        dryMixer.volume = 1.0
        wetMixer.volume = 1.0

        if let dryDestination = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        ) {
            dryDestination.volume = dryGain
        }
        // Intentionally no fallback if destination is nil — see comment
        // above. Subsequent `applyMixGains()` calls (slider drag, bypass
        // toggle) will set the destination volume correctly once the
        // connection is fully realised.
        if let wetDestination = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        ) {
            wetDestination.volume = wetGain
        }
    }

    /// Re-apply mix gains once the engine is running. The mixer destinations
    /// `applyMixGains()` writes to are nil while the engine is stopped, so the
    /// gains set during `attach(to:)` (and any preset restored before
    /// power-on) only land when this is called after `engine.start()`.
    /// (Codex PR #10 review — saved bypass / wet-dry honored on power-on.)
    public func refreshMixState() {
        applyMixGains()
    }

    // MARK: - EXP-031 diagnostic

    /// `[EXP-031.*]` instrumentation. Exposes the parallel-mixer state +
    /// per-mixer output formats so we can detect format-negotiation
    /// asymmetries between Reverb (which cuts audio on bypass) and EQ
    /// (which doesn't).
    public func debugStateDescription() -> String {
        let dryDest = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        )
        let wetDest = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        )
        return "bypass=\(bypass) wetDryMix=\(wetDryMix) "
            + "dryDestExists=\(dryDest != nil) "
            + "dryDestVol=\(dryDest?.volume.description ?? "nil") "
            + "dryMixerVol=\(dryMixer.volume) "
            + "wetDestExists=\(wetDest != nil) "
            + "wetDestVol=\(wetDest?.volume.description ?? "nil") "
            + "wetMixerVol=\(wetMixer.volume) "
            + "attached=\(attachedEngine != nil) "
            + "inFmt=\(Self.fmt(inputBus.outputFormat(forBus: 0))) "
            + "dryFmt=\(Self.fmt(dryMixer.outputFormat(forBus: 0))) "
            + "reverbInFmt=\(Self.fmt(reverb.inputFormat(forBus: 0))) "
            + "reverbOutFmt=\(Self.fmt(reverb.outputFormat(forBus: 0))) "
            + "wetFmt=\(Self.fmt(wetMixer.outputFormat(forBus: 0))) "
            + "outFmt=\(Self.fmt(outputBus.outputFormat(forBus: 0))) "
            + "reverbAUBypass=\(reverb.bypass) "
            + "reverbUnitWetDryMix=\(reverb.wetDryMix)"
    }

    private static func fmt(_ format: AVAudioFormat) -> String {
        return "\(format.sampleRate)Hz×\(format.channelCount)ch"
    }

    // MARK: Snapshot / restore

    public func snapshot() -> EffectState {
        EffectState(
            typeIdentifier: Self.typeIdentifier,
            id: id,
            displayName: displayName,
            bypass: bypass,
            wetDryMix: wetDryMix,
            parameters: [:],
            extras: [
                "preset": .string(Self.name(for: preset))
            ]
        )
    }

    /// Legacy extras are authoritative, including when numeric room data is
    /// also present. Missing extras keep the current room (the default on a
    /// fresh node); invalid extras throw without loading a different room.
    public func restore(from state: EffectState) throws {
        guard state.typeIdentifier == Self.typeIdentifier else {
            throw EffectRestoreError.typeIdentifierMismatch(
                expected: Self.typeIdentifier,
                actual: state.typeIdentifier
            )
        }
        // Preserve the identity from saved state. See EQNode.restore for the
        // rationale; the same drift risk applies to every concrete EffectNode.
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = min(max(state.wetDryMix, 0.0), 1.0)

        if let extra = state.extras["preset"] {
            switch extra {
            case .string(let name):
                guard let resolved = Self.preset(forName: name) else {
                    throw EffectRestoreError.invalidExtra(
                        key: "preset",
                        reason: "Unknown preset name '\(name)'"
                    )
                }
                preset = resolved
            case .int(let raw):
                // ObjC enum construction accepts unknown raw values; validate
                // against the app's supported rooms before loading the unit.
                guard let resolved = Self.supportedPresets.first(where: { $0.preset.rawValue == raw }) else {
                    throw EffectRestoreError.invalidExtra(
                        key: "preset",
                        reason: "Reverb preset rawValue \(raw) is not a supported room"
                    )
                }
                preset = resolved.preset
            default:
                throw EffectRestoreError.invalidExtra(
                    key: "preset",
                    reason: "Expected string or int, got \(extra)"
                )
            }
        }
        applyMixGains()
    }

    // MARK: Preset name mapping

    /// All `AVAudioUnitReverbPreset` cases supported in V1, each paired with
    /// its stable string name used in `.tnf` files.
    ///
    /// Keep the macOS-14.4-compatible set and picker ordering. Any deliberate
    /// expansion must update the picker labels too. Existing names must not
    /// change because older `.tnf` files use them.
    public static let supportedPresets: [(name: String, preset: AVAudioUnitReverbPreset)] = [
        ("smallRoom", .smallRoom),
        ("mediumRoom", .mediumRoom),
        ("largeRoom", .largeRoom),
        ("largeRoom2", .largeRoom2),
        ("mediumHall", .mediumHall),
        ("mediumHall2", .mediumHall2),
        ("mediumHall3", .mediumHall3),
        ("largeHall", .largeHall),
        ("largeHall2", .largeHall2),
        ("plate", .plate),
        ("mediumChamber", .mediumChamber),
        ("largeChamber", .largeChamber),
        ("cathedral", .cathedral)
    ]

    /// Return the stable string name for a preset. Falls back to `"largeHall"`
    /// for unrecognised presets added in future SDKs.
    public static func name(for preset: AVAudioUnitReverbPreset) -> String {
        for entry in supportedPresets where entry.preset == preset {
            return entry.name
        }
        return "largeHall"
    }

    /// Return the preset for a stable string name, or `nil` if unrecognised.
    public static func preset(forName name: String) -> AVAudioUnitReverbPreset? {
        supportedPresets.first { $0.name == name }?.preset
    }
}

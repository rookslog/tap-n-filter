import AVFoundation
import AudioToolbox
import Foundation
import os

/// A two-band parametric EQ exposing a high-pass and a low-pass band.
///
/// Wraps `AVAudioUnitEQ` with two bands configured as resonant filters:
///
/// - Band 0 (`hp.*`): high-pass, default 80 Hz with Q 0.707.
/// - Band 1 (`lp.*`): low-pass, default 800 Hz with Q 0.707.
///
/// `wetDryMix` exists on the protocol but is unhelpful for spectral-shaping
/// effects (see ADR-007 and the protocol's "When wet/dry is meaningful"
/// section). The UI hides the slider by default via
/// `showsWetDryByDefault = false`; this class still implements the parallel-
/// mixer pattern correctly so the protocol surface stays uniform.
public final class EQNode: EffectNode {

    // MARK: Type-level metadata

    public static let typeIdentifier: String = "tnf.eq"

    /// Override the protocol default: dragging wet/dry on a filter reintroduces
    /// the very frequencies being removed. The slider is still reachable in
    /// the expanded controls panel; this only hides it from the default row.
    public static let showsWetDryByDefault: Bool = false

    private static let defaultDisplayName: String = "EQ"

    /// Bus index where the dry path connects on `outputBus`. Conventionally 0.
    private static let dryInputBusIndex: AVAudioNodeBus = 0

    /// Bus index where the wet path connects on `outputBus`. Conventionally 1.
    private static let wetInputBusIndex: AVAudioNodeBus = 1

    /// The mixer's only output bus. Fan-out is implemented via
    /// `connect(_:toConnectionPoints:fromBus:format:)`, not by using multiple
    /// output buses (a mixer has exactly one output bus).
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

    /// The graph connects audio into this node on bus 0.
    public let inputBus: AVAudioMixerNode
    /// The graph reads audio from this node on bus 0.
    public let outputBus: AVAudioMixerNode
    private let dryMixer: AVAudioMixerNode
    /// A small mixer placed between the wet processor and `outputBus`. The
    /// processor (`AVAudioUnitEQ`) does not conform to `AVAudioMixing`, so
    /// we cannot set its volume on the downstream mixer directly. This
    /// trampoline mixer does conform and lets us route per-input-bus volume
    /// changes through the standard API.
    private let wetMixer: AVAudioMixerNode
    private let eq: AVAudioUnitEQ

    private weak var attachedEngine: AVAudioEngine?

    // MARK: Init

    /// Convenience initializer matching `DefaultConstructibleEffectNode`'s
    /// requirement. Equivalent to `init(id: UUID(), displayName: nil, ...)`.
    public convenience init() {
        self.init(id: UUID())
    }

    /// Full initializer. `displayName` defaults to `"EQ"` when nil.
    /// `wetDryMix` defaults to 1.0 (fully wet) because the EQ's filter is
    /// only meaningful at 100% wet; see ADR-007 and `showsWetDryByDefault`.
    public init(
        id: UUID = UUID(),
        displayName: String? = nil,
        bypass: Bool = false,
        wetDryMix: Float = 1.0
    ) {
        self.id = id
        self.displayName = displayName ?? Self.defaultDisplayName
        self.bypass = bypass
        self.wetDryMix = wetDryMix
        self.inputBus = AVAudioMixerNode()
        self.outputBus = AVAudioMixerNode()
        self.dryMixer = AVAudioMixerNode()
        self.wetMixer = AVAudioMixerNode()
        self.eq = AVAudioUnitEQ(numberOfBands: 2)
        configureEQBands()
    }

    /// Bands whose configured frequency did not survive the write at init, as
    /// `"<band>: wrote <x> read <y>"`. Empty in the normal case.
    ///
    /// A CI run once observed `hp.frequency` reading back as 20.0 — the band
    /// minimum — for a value that had been written as 100.0, on one OS leg
    /// only, and never reproduced (U-015). If an `AVAudioUnitEQ` can come up
    /// unconfigured, the shipping app has the same exposure: an EQ whose
    /// cutoffs sit at the band minimums, doing nothing audible, with no error
    /// anywhere. That is invisible by construction, so the condition reports
    /// itself here instead of waiting to be caught by an assertion diff.
    public private(set) var configurationWarnings: [String] = []

    private func configureEQBands() {
        // AVAudioUnitEQ's `globalGain` is in dB; the unit's overall gain is
        // unity at globalGain = 0.
        eq.globalGain = 0.0

        // The filter type is load-bearing for Q, not just for the response
        // shape. `AVAudioUnitEQFilterParameters.bandwidth` is only a live
        // parameter for the filter types that actually have a bandwidth;
        // for `.lowPass`, `.highPass`, `.lowShelf` and `.highShelf` a write
        // is accepted and silently discarded, and the property reads back
        // 0.0. Measured on macOS 27 (probe in
        // docs/investigations/probes/eq_bandwidth_persistence.swift):
        //
        //     parametric        wrote 0.944821  read 0.944821
        //     lowPass           wrote 0.944821  read 0.000000
        //     highPass          wrote 0.944821  read 0.000000
        //     resonantLowPass   wrote 0.944821  read 0.944821
        //     resonantHighPass  wrote 0.944821  read 0.944821
        //
        // The resonant variants are what this class documents itself as using
        // ("two bands configured as resonant filters") and what the README
        // advertises ("adjustable cutoff and resonance"). They keep the same
        // pass-band shape while making Q a real, readable parameter.
        let hpBand = eq.bands[0]
        hpBand.filterType = .resonantHighPass
        hpBand.frequency = 80.0
        hpBand.bandwidth = qToBandwidth(0.707)
        hpBand.bypass = false

        let lpBand = eq.bands[1]
        lpBand.filterType = .resonantLowPass
        lpBand.frequency = 800.0
        lpBand.bandwidth = qToBandwidth(0.707)
        lpBand.bypass = false

        verifyFrequencyWrites(
            stage: "init",
            expected: [("hp", 80.0), ("lp", 800.0)]
        )
    }

    /// Read back the frequency actually held by each band and record — and log
    /// — any that did not take.
    ///
    /// Called after every write path that sets a frequency, not just `init`.
    /// U-015 was observed at *restore* time: the 80 Hz default write succeeded
    /// and the later 100 Hz preset write was the one that did not survive. A
    /// check that ran only at construction would leave `configurationWarnings`
    /// empty for exactly the case that was actually seen, and a loaded preset
    /// could put the shipping EQ at its band minimums in silence.
    ///
    /// Logging happens here rather than at a reader, because the only
    /// production caller of `debugStateDescription()` is a wet/dry or bypass
    /// change — a node that is misconfigured and never touched again would
    /// otherwise leave no trace at all.
    private func verifyFrequencyWrites(stage: String, expected: [(String, Float)]) {
        let bandIndices = [("hp", 0), ("lp", 1)]
        var fresh: [String] = []
        for (label, wrote) in expected {
            guard let bandIndex = bandIndices.first(where: { $0.0 == label })?.1 else { continue }
            let held = readBand(.frequency, band: bandIndex)
            // Retire any prior warning for this band: it has just been
            // rewritten, so the earlier reading is stale either way.
            configurationWarnings.removeAll { $0.hasPrefix("\(label) at ") }
            if abs(held - wrote) > 0.01 {
                fresh.append(
                    "\(label) at \(stage): wrote frequency \(wrote) read \(held)"
                )
            }
        }
        // Warnings for bands this stage did not touch are kept — a preset that
        // omits `lp.frequency` does not make an `lp` failure at init untrue.
        configurationWarnings.append(contentsOf: fresh)
        if !fresh.isEmpty {
            Self.logger.error(
                "EQ band configuration did not take: \(fresh.joined(separator: "; "), privacy: .public)"
            )
        }
    }

    // MARK: Band read-back

    /// Which band value `readBand(_:band:)` returns.
    private enum BandValue {
        case frequency
        case bandwidth
    }

    /// Reads a band's frequency (Hz) or bandwidth (octaves) from the audio
    /// unit's own parameter instead of the `AVAudioUnitEQFilterParameters`
    /// object.
    ///
    /// The band object was seen returning the factory default (about one node
    /// in 1,700 on macOS 26) while the unit held the written value; the unit's
    /// parameter read was correct in every such case. The band object is used
    /// only when the C call returns a non-zero status. Per-band parameter IDs
    /// are the band-0 ID plus the band index, global scope, element 0
    /// (AudioUnitParameters.h, "Parameters for the AUNBandEQ unit").
    private func readBand(_ value: BandValue, band: Int) -> Float {
        let base: Int
        switch value {
        case .frequency: base = Int(kAUNBandEQParam_Frequency)
        case .bandwidth: base = Int(kAUNBandEQParam_Bandwidth)
        }
        var held: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(
            eq.audioUnit,
            AudioUnitParameterID(base + band),
            kAudioUnitScope_Global,
            0,
            &held
        )
        if status == noErr { return held }
        switch value {
        case .frequency: return eq.bands[band].frequency
        case .bandwidth: return eq.bands[band].bandwidth
        }
    }

    /// Logs the misconfiguration above to the unified log, so the evidence
    /// exists whether or not any UI is watching.
    private static let logger = Logger(subsystem: "tnf.effects", category: "EQNode")

    // MARK: Parameters

    /// All tunable parameters for this node type, in display order.
    public static let parameterCatalog: [EffectParameter] = [
        EffectParameter(
            identifier: "hp.frequency",
            displayName: "HP Frequency",
            range: 20.0 ... 500.0,
            defaultValue: 80.0,
            unit: .hertz
        ),
        EffectParameter(
            identifier: "hp.Q",
            displayName: "HP Q",
            range: 0.5 ... 4.0,
            defaultValue: 0.707,
            unit: .ratio
        ),
        EffectParameter(
            identifier: "lp.frequency",
            displayName: "LP Frequency",
            range: 200.0 ... 18_000.0,
            defaultValue: 800.0,
            unit: .hertz
        ),
        EffectParameter(
            identifier: "lp.Q",
            displayName: "LP Q",
            range: 0.5 ... 4.0,
            defaultValue: 0.707,
            unit: .ratio
        )
    ]

    public var parameters: [EffectParameter] { Self.parameterCatalog }

    public func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = Self.parameterCatalog.first(where: { $0.identifier == identifier })
        else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(
                identifier: identifier,
                value: value,
                range: parameter.range
            )
        }
        switch identifier {
        case "hp.frequency":
            eq.bands[0].frequency = value
        case "hp.Q":
            eq.bands[0].bandwidth = qToBandwidth(value)
        case "lp.frequency":
            eq.bands[1].frequency = value
        case "lp.Q":
            eq.bands[1].bandwidth = qToBandwidth(value)
        default:
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
    }

    /// Read the current value for a parameter by identifier.
    ///
    /// Returns `nil` for unknown identifiers. The Q parameters are converted
    /// back from the underlying bandwidth-in-octaves representation before
    /// being returned; the returned value matches the surface-facing Q scale.
    public func parameterValue(_ identifier: String) -> Float? {
        switch identifier {
        case "hp.frequency":
            return readBand(.frequency, band: 0)
        case "hp.Q":
            return bandwidthToQ(readBand(.bandwidth, band: 0))
        case "lp.frequency":
            return readBand(.frequency, band: 1)
        case "lp.Q":
            return bandwidthToQ(readBand(.bandwidth, band: 1))
        default:
            return nil
        }
    }

    // MARK: Attach / detach

    public func attach(to engine: AVAudioEngine) throws {
        // Attach all five nodes; AVAudioEngine.attach is idempotent.
        engine.attach(inputBus)
        engine.attach(outputBus)
        engine.attach(dryMixer)
        engine.attach(wetMixer)
        engine.attach(eq)

        // Fan out the input mixer's single output bus to both the dry path
        // and the wet path. AVAudioMixerNode has exactly one output bus;
        // fan-out is expressed through AVAudioConnectionPoint, not via
        // multiple `fromBus` values.
        let fanOut: [AVAudioConnectionPoint] = [
            AVAudioConnectionPoint(node: dryMixer, bus: 0),
            AVAudioConnectionPoint(node: eq, bus: 0)
        ]
        engine.connect(
            inputBus,
            to: fanOut,
            fromBus: Self.sourceFanOutBus,
            format: nil
        )

        // Bring the wet path through its trampoline mixer and merge into
        // the output summing mixer.
        engine.connect(eq, to: wetMixer, format: nil)
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
        engine.detach(eq)
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
        // at unity. See `ReverbNode.applyMixGains` for the rationale —
        // the documented way to mix is via `AVAudioMixingDestination.volume`
        // on the downstream mixer's per-input-bus destination, not via
        // the upstream mixer's `.volume`. The prior fallback path could
        // silently set `mixer.volume = 0` at attach time when the
        // destination was transiently unavailable, and that mute then
        // persisted across every subsequent call.
        dryMixer.volume = 1.0
        wetMixer.volume = 1.0

        if let dryDestination = dryMixer.destination(
            forMixer: outputBus,
            bus: Self.dryInputBusIndex
        ) {
            dryDestination.volume = dryGain
        }
        if let wetDestination = wetMixer.destination(
            forMixer: outputBus,
            bus: Self.wetInputBusIndex
        ) {
            wetDestination.volume = wetGain
        }
    }

    /// Re-apply mix gains once the engine is running. See
    /// `ReverbNode.refreshMixState` — the mixer destinations are nil while the
    /// engine is stopped, so gains set during `attach(to:)` only land when
    /// this is called after `engine.start()`. (Codex PR #10 review.)
    public func refreshMixState() {
        applyMixGains()
    }

    // MARK: - EXP-031 diagnostic

    /// `[EXP-031.*]` instrumentation. See `ReverbNode.debugStateDescription`
    /// for the rationale; identical shape so we can side-by-side compare
    /// Reverb (cuts audio on bypass) vs EQ (doesn't).
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
            + "eqInFmt=\(Self.fmt(eq.inputFormat(forBus: 0))) "
            + "eqOutFmt=\(Self.fmt(eq.outputFormat(forBus: 0))) "
            + "wetFmt=\(Self.fmt(wetMixer.outputFormat(forBus: 0))) "
            + "outFmt=\(Self.fmt(outputBus.outputFormat(forBus: 0))) "
            + "eqAUBypass=\(eq.bypass) "
            + "hpFreq=\(readBand(.frequency, band: 0)) hpBw=\(readBand(.bandwidth, band: 0)) "
            + "lpFreq=\(readBand(.frequency, band: 1)) lpBw=\(readBand(.bandwidth, band: 1)) "
            + "configWarnings=\(configurationWarnings.isEmpty ? "none" : configurationWarnings.joined(separator: "; "))"
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
            parameters: [
                "hp.frequency": readBand(.frequency, band: 0),
                "hp.Q": bandwidthToQ(readBand(.bandwidth, band: 0)),
                "lp.frequency": readBand(.frequency, band: 1),
                "lp.Q": bandwidthToQ(readBand(.bandwidth, band: 1))
            ],
            extras: [:]
        )
    }

    public func restore(from state: EffectState) throws {
        guard state.typeIdentifier == Self.typeIdentifier else {
            throw EffectRestoreError.typeIdentifierMismatch(
                expected: Self.typeIdentifier,
                actual: state.typeIdentifier
            )
        }
        // Preserve the identity from the saved state so that node IDs remain
        // stable across save/load cycles. Without this, every load would give
        // every node a fresh UUID, making identity-based diffing impossible.
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = min(max(state.wetDryMix, 0.0), 1.0)
        var expectedFrequencies: [(String, Float)] = []
        for parameter in Self.parameterCatalog {
            guard let raw = state.parameters[parameter.identifier] else { continue }
            let clamped = min(max(raw, parameter.range.lowerBound), parameter.range.upperBound)
            // Direct dispatch — avoids re-validating range.
            switch parameter.identifier {
            case "hp.frequency":
                eq.bands[0].frequency = clamped
                expectedFrequencies.append(("hp", clamped))
            case "hp.Q": eq.bands[0].bandwidth = qToBandwidth(clamped)
            case "lp.frequency":
                eq.bands[1].frequency = clamped
                expectedFrequencies.append(("lp", clamped))
            case "lp.Q": eq.bands[1].bandwidth = qToBandwidth(clamped)
            default: break
            }
        }
        // Verify against the values this restore actually wrote — the stage
        // where U-015 was observed. Only bands the preset supplied are checked;
        // one it omitted still holds its verified default.
        verifyFrequencyWrites(stage: "restore", expected: expectedFrequencies)
        applyMixGains()
    }

    // MARK: Q / bandwidth conversion

    /// `AVAudioUnitEQFilterParameters.bandwidth` is in octaves. The relation
    /// between Q and bandwidth (in octaves) is a standard biquad mapping:
    ///
    ///     bw = (2 / ln(2)) * asinh(1 / (2 * Q))
    ///
    /// We keep `Q` on the user-facing surface because it's the value
    /// engineers and ear-tuners think in.
    private func qToBandwidth(_ q: Float) -> Float {
        let qDouble = Double(max(q, 0.0001))
        let bw = (2.0 / log(2.0)) * asinh(1.0 / (2.0 * qDouble))
        return Float(bw)
    }

    /// Default Q, reported when the audio unit has no usable bandwidth to
    /// convert. Matches the `hp.Q` / `lp.Q` catalog defaults.
    private static let defaultQ: Float = 0.707

    private func bandwidthToQ(_ bandwidth: Float) -> Float {
        // A bandwidth at or below zero is not a small bandwidth — it is the
        // audio unit reporting that this band has no bandwidth parameter at
        // all. Feeding it to the inverse formula produced Q = 14426.951 (the
        // old `max(bandwidth, 0.0001)` floor run through the conversion), and
        // because `snapshot()` calls this, that value was written into saved
        // `.tnf` files, where `restore()` then clamped it to the top of the
        // declared 0.5...4.0 range. A save/load cycle silently rewrote the
        // user's Q. Report the default instead: wrong-but-sane beats a
        // nonsense number escaping into a file the user is invited to edit
        // by hand.
        guard bandwidth > 0 else { return Self.defaultQ }

        // Inverse of the formula above:
        //   sinh(bw * ln(2) / 2) = 1 / (2 * Q)
        //   Q = 1 / (2 * sinh(bw * ln(2) / 2))
        let q = 1.0 / (2.0 * sinh(Double(bandwidth) * log(2.0) / 2.0))
        return Float(q)
    }
}

/// Errors raised by `setParameter` and related dispatch.
public enum EffectParameterError: Error, Equatable {
    case unknownParameter(identifier: String)
    case valueOutOfRange(identifier: String, value: Float, range: ClosedRange<Float>)
}

/// Errors raised by `restore(from:)`.
public enum EffectRestoreError: Error, Equatable {
    case typeIdentifierMismatch(expected: String, actual: String)
    case missingExtra(key: String)
    case invalidExtra(key: String, reason: String)
}

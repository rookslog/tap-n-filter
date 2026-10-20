import Combine
import Effects
import SwiftUI
import ViewModel

/// Renders one control per `EffectParameter` exposed by the node.
///
/// The unit→control mapping is:
/// - Continuous units (`.hertz`, `.decibels`, `.ratio`, `.seconds`,
///   `.milliseconds`, `.normalized`, `.percent`) → `Slider`.
/// - `.integer` → `Stepper`.
/// - `.enumValue(cases:)` → `Picker`.
///
/// Slider drags are coalesced through a per-parameter Combine subject that
/// throttles at 30 Hz before calling `viewModel.updateParameter`.
public struct EffectControlsView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public let node: any EffectNode

    public init(node: any EffectNode) {
        self.node = node
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if node.parameters.isEmpty {
                Text("No parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(node.parameters, id: \.identifier) { parameter in
                control(for: parameter)
            }
            // The wet/dry slider lives here for nodes that hide it in the
            // header (EQ, per ADR-007) — this is the only place to reach it.
            // Level/utility nodes (GainNode) have no wet/dry concept, so the
            // control is suppressed entirely rather than shown as a no-op.
            if type(of: node).supportsWetDry {
                wetDryRow
            }
        }
    }

    @ViewBuilder
    private func control(for parameter: EffectParameter) -> some View {
        switch parameter.unit {
        case .integer:
            integerStepper(parameter)
        case .enumValue(let cases):
            enumPicker(parameter, cases: cases)
        case .hertz, .decibels, .ratio, .seconds, .milliseconds, .normalized, .percent:
            continuousSlider(parameter)
        }
    }

    private func continuousSlider(_ parameter: EffectParameter) -> some View {
        ParameterSlider(
            parameter: parameter,
            initialValue: currentValue(for: parameter)
        ) { value in
            viewModel.updateParameter(
                nodeID: node.id,
                paramID: parameter.identifier,
                value: value
            )
        }
    }

    private func integerStepper(_ parameter: EffectParameter) -> some View {
        // The Binding closures read `currentValue(for:)` on each invocation
        // rather than a once-captured local. SwiftUI rebuilds the view body
        // when `viewModel.objectWillChange` fires, but a parameter write that
        // bypasses `updateParameter` (preset load, programmatic restore) does
        // not trigger an immediate rebuild; reading live means the displayed
        // value always reflects the node's current state.
        return HStack {
            Text(parameter.displayName)
                .font(.caption)
            Spacer()
            Stepper(
                value: Binding<Double>(
                    get: { Double(currentValue(for: parameter)) },
                    set: { newValue in
                        viewModel.updateParameter(
                            nodeID: node.id,
                            paramID: parameter.identifier,
                            value: Float(newValue)
                        )
                    }
                ),
                in: Double(parameter.range.lowerBound) ... Double(parameter.range.upperBound),
                step: 1
            ) {
                Text("\(Int(currentValue(for: parameter)))")
            }
            .labelsHidden()
            .accessibilityLabel(parameter.displayName)
            .accessibilityValue("\(Int(currentValue(for: parameter)))")
        }
    }

    private func enumPicker(_ parameter: EffectParameter, cases: [String]) -> some View {
        // Same live-read pattern as `integerStepper`: the binding getter
        // reads through to the node on each call, so the displayed selection
        // tracks programmatic parameter updates (preset load, etc.) even when
        // SwiftUI hasn't yet re-evaluated the parent body.
        return HStack {
            Text(parameter.displayName)
                .font(.caption)
            Picker(
                parameter.displayName,
                selection: Binding<Int>(
                    get: {
                        let current = Int(currentValue(for: parameter))
                        return min(max(current, 0), max(cases.count - 1, 0))
                    },
                    set: { newIndex in
                        viewModel.objectWillChange.send()
                        viewModel.updateParameter(
                            nodeID: node.id,
                            paramID: parameter.identifier,
                            value: Float(newIndex)
                        )
                    }
                )
            ) {
                ForEach(0 ..< cases.count, id: \.self) { index in
                    Text(cases[index]).tag(index)
                }
            }
            .labelsHidden()
            .accessibilityLabel(parameter.displayName)
            .accessibilityValue(accessibilityValueForEnum(parameter, cases: cases))
        }
    }

    /// Resolve the accessibility value for an enum picker by reading live.
    /// Pulled out of `enumPicker`'s view tree because it's not a view — it's a
    /// string read at modifier-evaluation time.
    private func accessibilityValueForEnum(_ parameter: EffectParameter, cases: [String]) -> String {
        let current = Int(currentValue(for: parameter))
        return cases.indices.contains(current) ? cases[current] : ""
    }

    private var wetDryRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Wet/Dry")
                    .font(.caption)
                Spacer()
                Text("\(Int(node.wetDryMix * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { node.wetDryMix },
                    set: { viewModel.updateWetDryMix(nodeID: node.id, value: $0) }
                ),
                in: 0.0 ... 1.0
            )
            .accessibilityLabel("Wet/Dry mix")
            .accessibilityValue("\(Int(node.wetDryMix * 100)) percent")
        }
    }

    /// Read the current parameter value off the node via the protocol-level
    /// reader. Nodes that don't recognise the identifier (or have no
    /// read-back path) return `nil`; we fall back to `parameter.defaultValue`
    /// so the control always has a valid initial value.
    private func currentValue(for parameter: EffectParameter) -> Float {
        return node.parameterValue(parameter.identifier) ?? parameter.defaultValue
    }
}

/// A continuous slider plus numeric readout. Drags are throttled at 30 Hz
/// using Combine's `throttle` so the underlying audio-unit parameter setter
/// is not flooded.
private struct ParameterSlider: View {

    let parameter: EffectParameter
    let initialValue: Float
    let onChange: (Float) -> Void

    @State private var liveValue: Float
    @State private var subject = PassthroughSubject<Float, Never>()
    @State private var cancellable: AnyCancellable?

    init(parameter: EffectParameter, initialValue: Float, onChange: @escaping (Float) -> Void) {
        self.parameter = parameter
        self.initialValue = initialValue
        self.onChange = onChange
        _liveValue = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.displayName)
                    .font(.caption)
                Spacer()
                Text(format(liveValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { liveValue },
                    set: { newValue in
                        liveValue = newValue
                        subject.send(newValue)
                    }
                ),
                in: parameter.range.lowerBound ... parameter.range.upperBound
            )
            .accessibilityLabel(parameter.displayName)
            .accessibilityValue(accessibilityValue)
        }
        .onAppear {
            cancellable = subject
                .throttle(
                    for: .milliseconds(33),
                    scheduler: DispatchQueue.main,
                    latest: true
                )
                .sink(receiveValue: onChange)
        }
        .onDisappear {
            cancellable?.cancel()
            cancellable = nil
        }
        // Resync `liveValue` from the latest `initialValue` whenever the
        // parent passes a new one. Without this, `@State` seeds the slider
        // once at view-identity creation and a preset load (or any
        // programmatic parameter write that bypasses the slider's own set)
        // would leave the thumb stuck at the prior value even as the
        // underlying node moves. The parent rebuilds `initialValue` from
        // `currentValue(for:)` on each body evaluation, so a change here
        // means the node actually moved.
        .onChange(of: initialValue) { _, newValue in
            liveValue = newValue
        }
    }

    private func format(_ value: Float) -> String {
        switch parameter.unit {
        case .hertz:
            return "\(Int(value)) Hz"
        case .decibels:
            return String(format: "%.1f dB", value)
        case .ratio:
            return String(format: "%.2f", value)
        case .seconds:
            return String(format: "%.2f s", value)
        case .milliseconds:
            return "\(Int(value)) ms"
        case .normalized:
            return String(format: "%.2f", value)
        case .percent:
            return "\(Int(value * 100))%"
        case .integer:
            return "\(Int(value))"
        case .enumValue:
            return "\(Int(value))"
        }
    }

    private var accessibilityValue: String {
        switch parameter.unit {
        case .hertz:
            return "\(Int(liveValue)) Hertz"
        case .decibels:
            return String(format: "%.1f decibels", liveValue)
        case .ratio:
            return String(format: "%.2f", liveValue)
        case .seconds:
            return String(format: "%.2f seconds", liveValue)
        case .milliseconds:
            return "\(Int(liveValue)) milliseconds"
        case .normalized:
            return String(format: "%.2f", liveValue)
        case .percent:
            return "\(Int(liveValue * 100)) percent"
        case .integer, .enumValue:
            return "\(Int(liveValue))"
        }
    }
}

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
/// Slider drags are coalesced at 30 Hz before calling `viewModel.updateParameter`.
/// Exact numeric commits, reset, and the final drag value bypass that delay.
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
            writer: ParameterNodeWriter(node: node, parameter: parameter, viewModel: viewModel),
            initialValue: currentValue(for: parameter)
        )
        // Reset view state when presets retain a UUID but replace the node.
        // ParameterNodeWriter also rejects stale delivery before teardown.
        .id(ObjectIdentifier(node))
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
    /// read-back path) return `nil`; only then do we use `parameter.defaultValue`.
    /// Non-nil readback, including invalid/out-of-range values, stays diagnostic.
    private func currentValue(for parameter: EffectParameter) -> Float {
        return node.parameterValue(parameter.identifier) ?? parameter.defaultValue
    }
}

/// Native continuous slider with a discoverable exact-value field and reset.
private struct ParameterSlider: View {

    let parameter: EffectParameter
    let initialValue: Float
    @Environment(\.locale) private var locale
    @FocusState private var inputFocused: Bool
    @StateObject private var editor: ParameterValueEditor

    init(writer: ParameterNodeWriter, initialValue: Float) {
        self.parameter = writer.parameter
        self.initialValue = initialValue
        _editor = StateObject(wrappedValue: writer.makeEditor())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.displayName)
                    .font(.caption)
                Spacer()
                Text(editor.presentation.displayValue(editor.value))
                    .font(.caption)
                    .foregroundStyle(editor.presentation.isValid(editor.value) ? Color.secondary : Color.red)
            }
            Slider(
                value: Binding(
                    get: { editor.presentation.position(for: editor.value) },
                    set: { editor.drag(to: $0) }
                ),
                in: 0 ... 1,
                onEditingChanged: { dragging in
                    if dragging {
                        inputFocused = false
                    } else {
                        editor.finishDragging()
                    }
                }
            )
            .accessibilityLabel(parameter.displayName)
            .accessibilityValue(editor.presentation.displayValue(editor.value))
            .accessibilityHint("Use arrow keys to adjust, or enter an exact value below.")

            HStack(spacing: 6) {
                TextField("Exact value", text: $editor.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .focusedValue(\.parameterNumericEditing, true)
                    .accessibilityLabel("\(parameter.displayName), exact value in \(editor.presentation.inputUnit)")
                    .accessibilityHint("Type a number. Press Return to apply or Escape to cancel.")
                    .onSubmit {
                        if editor.commit(locale: locale) { inputFocused = false }
                    }
                    .onExitCommand {
                        editor.cancel()
                        inputFocused = false
                    }
                Text(editor.presentation.inputUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset") {
                    editor.reset()
                    inputFocused = false
                }
                .accessibilityLabel("Reset \(parameter.displayName) to default")
                .help("Default: \(editor.presentation.displayValue(parameter.defaultValue))")
            }
            if let error = editor.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            editor.resync(value: initialValue)
        }
        .onDisappear {
            editor.stop()
        }
        .onChange(of: inputFocused) { _, focused in
            if focused {
                editor.beginEditing(locale: locale)
            } else if editor.isEditing {
                editor.cancel()
            }
        }
        // The parent reads the node again after object/preset updates. Keep
        // that readback authoritative without echoing it into the audio unit.
        // Unchanged NaN must not look like new model data during a recovery drag.
        .onChange(of: initialValue.isNaN ? nil : initialValue) { _, _ in
            editor.receiveModelValue(initialValue)
        }
    }
}

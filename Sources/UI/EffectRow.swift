import Effects
import SwiftUI
import ViewModel

/// One row in the chain editor: header with chevron / name / bypass / optional
/// wet-dry slider / remove button, plus an expanded controls panel when
/// `viewModel.expandedEffectID == node.id`.
///
/// The wet/dry slider visibility is controlled by the node's static
/// `showsWetDryByDefault` per ADR-007. EQ overrides to false; reverb keeps
/// the default true.
public struct EffectRow: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public let index: Int
    public let node: any EffectNode

    public init(index: Int, node: any EffectNode) {
        self.index = index
        self.node = node
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                EffectControlsView(node: node)
                    .padding(.leading, 18)
                    .padding(.top, 4)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            chevron
            reorderButtons
            Text(node.displayName)
                .font(.body)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            bypassToggle
            if showsWetDry {
                wetDrySlider
            }
            removeButton
        }
    }

    /// Stacked up/down icon buttons for reordering this row in the chain.
    /// Disabled at the boundaries (first row can't move up, last can't move
    /// down). Drag-and-drop reorder was rejected per ADR-013 because
    /// `MenuBarExtra` historically does not play well with drag gestures
    /// and the keyboard/VoiceOver story for drag handles is poor.
    private var reorderButtons: some View {
        VStack(spacing: 3) {
            Button {
                viewModel.moveEffect(from: index, to: index - 1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 14, height: 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .accessibilityLabel("Move \(node.displayName) up")
            .accessibilityHint("Move this effect earlier in the chain.")

            Button {
                // Graph.move's destination is the post-removal index. To move
                // this row one slot later, remove at `index` (the array shrinks
                // by one) and reinsert at `index + 1` so the next sibling — now
                // at `index` after the removal — keeps its position and our
                // node lands behind it. Passing `index + 2` would skip past
                // the next sibling and move two slots forward.
                viewModel.moveEffect(from: index, to: index + 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 14, height: 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(index >= viewModel.graph.nodes.count - 1)
            .accessibilityLabel("Move \(node.displayName) down")
            .accessibilityHint("Move this effect later in the chain.")
        }
    }

    private var chevron: some View {
        Button {
            if isExpanded {
                viewModel.expandedEffectID = nil
            } else {
                viewModel.expandedEffectID = node.id
            }
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(node.displayName)" : "Expand \(node.displayName)")
        .accessibilityHint("Show or hide the parameter controls for this effect.")
    }

    private var bypassToggle: some View {
        Toggle(
            isOn: Binding(
                get: { !node.bypass },
                set: { newValue in viewModel.setBypass(nodeID: node.id, bypass: !newValue) }
            )
        ) {
            Text("On")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .accessibilityLabel("\(node.displayName) enabled")
        .accessibilityValue(node.bypass ? "Bypassed" : "Active")
        .accessibilityHint("Toggle to bypass or enable this effect.")
    }

    private var wetDrySlider: some View {
        Slider(
            value: Binding(
                get: { node.wetDryMix },
                set: { viewModel.updateWetDryMix(nodeID: node.id, value: $0) }
            ),
            in: 0.0 ... 1.0
        )
        .frame(width: 88)
        .accessibilityLabel("\(node.displayName) wet/dry")
        .accessibilityValue("\(Int(node.wetDryMix * 100)) percent")
    }

    private var removeButton: some View {
        Button {
            viewModel.removeEffect(at: index)
        } label: {
            Image(systemName: "minus.circle")
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(node.displayName)")
        .accessibilityHint("Remove this effect. Use Undo Remove or Command-Option-Z to restore it.")
    }

    private var isExpanded: Bool {
        viewModel.expandedEffectID == node.id
    }

    /// Pick up the type-level default from the concrete node's metatype. A
    /// node that has no wet/dry concept at all (`supportsWetDry == false`)
    /// never shows the header slider regardless of `showsWetDryByDefault`.
    private var showsWetDry: Bool {
        let type = type(of: node)
        return type.supportsWetDry && type.showsWetDryByDefault
    }
}

import Effects
import Graph
import SwiftUI
import ViewModel

/// Ordered editor for the effect chain. Renders one `EffectRow` per node
/// followed by persistent removal recovery and an `AddEffectButton` whose menu
/// pulls available effect types from the view model's injected registry.
public struct ChainEditorView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.graph.nodes.enumerated()), id: \.element.id) { index, node in
                        EffectRow(index: index, node: node)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A ScrollView has no intrinsic height — it fills whatever it is
            // given. Inside a `MenuBarExtra(.window)` the window sizes to the
            // content's fitting height, so a `maxHeight`-only constraint lets
            // the scroll region collapse to nothing whenever the OS resolves
            // the fitting size to its minimum (observed on macOS 27). The
            // `minHeight` floor keeps the chain editor open across OS versions;
            // `maxHeight` still caps it so a long chain scrolls.
            .frame(minHeight: 200, maxHeight: 440)

            if let name = viewModel.lastRemovedEffectName {
                removalRecoveryRow(name: name)
            }

            AddEffectButton()
        }
    }

    private func removalRecoveryRow(name: String) -> some View {
        HStack(spacing: 6) {
            Text("Removed \(name)")
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Removed \(name)")
                .accessibilityLabel("Removed \(name)")
            Spacer(minLength: 0)
            Button {
                viewModel.undoLastRemoval()
            } label: {
                HStack(spacing: 4) {
                    Text("Undo Remove")
                    Text("⌥⌘Z")
                        .accessibilityHidden(true)
                }
            }
            .fixedSize()
            .controlSize(.small)
            .disabled(!viewModel.canUndoRemoval)
            .keyboardShortcut("z", modifiers: [.command, .option])
            .help("Undo remove (⌥⌘Z)")
            .accessibilityLabel("Undo Remove")
            .accessibilityHint("Restore \(name) to its original position. Shortcut: Command-Option-Z.")
        }
        .font(.caption)
    }
}

/// Menu button that appends a new effect to the chain. The menu items are
/// sourced from `AppViewModel.availableEffectTypes` (which forwards to the
/// view model's injected `EffectNodeRegistry`). Using the view model's
/// registry — not `EffectNodeRegistry.shared` — keeps the menu options
/// aligned with what the view model can actually construct.
public struct AddEffectButton: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        Menu {
            ForEach(viewModel.availableEffectTypes, id: \.self) { identifier in
                Button(displayName(for: identifier)) {
                    viewModel.addEffect(of: identifier)
                }
                .accessibilityLabel("Add \(displayName(for: identifier))")
            }
        } label: {
            Label("Add Effect", systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Add effect")
        .accessibilityHint("Choose an effect type to append to the chain.")
    }

    /// Map a `typeIdentifier` to a user-visible label. V1 hard-codes the two
    /// built-ins; adding a new effect type means adding an entry here.
    private func displayName(for typeIdentifier: String) -> String {
        switch typeIdentifier {
        case "tnf.eq": return "Parametric EQ"
        case "tnf.gain": return "Gain"
        case "tnf.reverb": return "Reverb"
        default: return typeIdentifier
        }
    }
}

import SwiftUI
import ViewModel

/// Root view shown in the menu bar dropdown.
///
/// Composed of `HeaderView`, `SourcePickerView`, `ChainEditorView`, and
/// `FooterView`, with an optional `SettingsSectionView` rendered below the
/// footer when `viewModel.showSettings` is true (the Settings action in
/// `HeaderView`’s Settings menu), and an optional `DebugPanel` below that when
/// `viewModel.showDebugPanel` is true (the Diagnostics action in that menu).
/// Width is fixed at 380 pt per `docs/specs/ui.md`.
/// Height is dynamic, capped at 700 pt by default and lifted to 900 pt
/// while the debug panel or settings panel is shown.
public struct ControlPanelView: View {

    /// View model injected via `@EnvironmentObject` from the scene root.
    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView()
                .padding(.horizontal, 12)
                .padding(.top, 12)

            SourcePickerView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ChainEditorView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Above the footer, not inside it: FooterView lays its actions out
            // in one centre-aligned row, and a multi-line banner nested in the
            // power control would drag the presets and quit buttons out of
            // alignment with it.
            if viewModel.lastError != nil {
                ErrorBanner()
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            FooterView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if viewModel.showSettings {
                Divider()
                SettingsSectionView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            if viewModel.showDebugPanel {
                Divider()
                DebugPanel()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
        // Floor the overall height as well as cap it. Without a `minHeight`,
        // the menu-bar window's fitting-size pass can collapse the whole panel
        // when an interior flexible view (the chain editor's ScrollView)
        // reports a small ideal height — the macOS 27 regression. The floor
        // guarantees the window stays usable regardless of how a given OS
        // resolves the fitting size; the cap still bounds growth.
        // Either drawer lifts the cap: both append a section below the footer,
        // so gating the lift on the debug panel alone let an expanded settings
        // section push the chain editor against the 700 pt cap.
        .frame(
            minHeight: 420,
            maxHeight: (viewModel.showDebugPanel || viewModel.showSettings) ? 900 : 700
        )
    }
}

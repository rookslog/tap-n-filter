import AppKit
import SwiftUI
import ViewModel

/// Preset identity and recovery notice above the bottom action row: presets
/// menu on the left, power toggle in the middle, quit button on the right.
public struct FooterView: View {

    @EnvironmentObject private var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(viewModel.presetName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(viewModel.presetName)
                Spacer(minLength: 0)
                Text(presetStatus)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Current preset")
            .accessibilityValue("\(viewModel.presetName), \(presetStatus)")

            if let notice = viewModel.presetRecoveryNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Preset partially recovered")
                    .accessibilityValue(notice)
            }

            HStack(spacing: 8) {
                PresetMenu()
                    .frame(width: 100, alignment: .leading)
                PowerToggle()
                quitButton
            }
        }
    }

    private var presetStatus: String {
        let origin: String
        switch viewModel.presetOrigin {
        case .factory: origin = "Factory"
        case .session: origin = "Session"
        case .file: origin = "File"
        case .recovered: origin = "Recovered"
        case .unsaved: origin = "Unsaved"
        }
        return viewModel.isPresetModified ? "\(origin) · Modified" : origin
    }

    /// Closes the entire application. MenuBarExtra apps stay alive after the
    /// dropdown closes by design, so without an explicit terminate the only
    /// way out is Activity Monitor. Per user feedback (2026-05-22): "having
    /// an exit button" was a Day-One ask.
    ///
    /// Keyboard shortcut: Cmd-Q matches the macOS convention; AppKit handles
    /// the shortcut even when no NSWindow is keyWindow because the
    /// MenuBarExtra window receives the key event.
    ///
    /// The glyph is deliberately not `power.circle`. This button sits directly
    /// beside the Start/Stop control, and a power symbol next to an audio
    /// on/off button reads as "turn the audio off" — a user reaching to stop
    /// filtering would quit the app instead. `xmark.circle` carries the
    /// close-the-thing meaning without competing with the power metaphor.
    private var quitButton: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q", modifiers: .command)
        .help("Quit tap-n-filter (⌘Q)")
        .accessibilityLabel("Quit tap-n-filter")
        .accessibilityHint("Closes the application entirely.")
    }
}

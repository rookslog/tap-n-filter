import SwiftUI
import ViewModel

/// Top of the menubar window. Shows the project name plus a status pill
/// that reflects `captureState` so the user knows at a glance whether
/// audio is actively being filtered. Phase 3 §3.1 also calls for a
/// "status line showing capture state and current source"; the pill
/// satisfies that requirement with a compact, accessible affordance.
public struct HeaderView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Text("tap-n-filter")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            statusPill
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Settings panel") {
                viewModel.toggleSettings()
            }
            .accessibilityLabel("Settings panel")
            .accessibilityValue(viewModel.showSettings ? "Shown" : "Hidden")
            .accessibilityHint("Toggle the settings panel at the bottom of the window.")

            Button("Diagnostics") {
                viewModel.toggleDebugPanel()
            }
            .accessibilityLabel("Diagnostics")
            .accessibilityValue(viewModel.showDebugPanel ? "Enabled" : "Disabled")
            .accessibilityHint("Toggle the debug log panel and detailed effect diagnostics.")
        } label: {
            Image(systemName: drawersVisible ? "gearshape.fill" : "gearshape")
                .frame(width: 14, height: 14)
                .foregroundStyle(drawersVisible ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Settings")
        .accessibilityHint("Open Settings panel and Diagnostics actions.")
    }

    private var drawersVisible: Bool {
        viewModel.showSettings || viewModel.showDebugPanel
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(pillColor)
                .frame(width: 8, height: 8)
            Text(pillLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capture status")
        .accessibilityValue(pillLabel)
    }

    /// True when an error is outstanding *and* no audio is reaching the user,
    /// so the pill must report the failure rather than a healthy state.
    ///
    /// Two distinct paths produce that combination, and both must be caught:
    ///
    /// - **`.idle` with an error.** A failed start rolls back and publishes
    ///   `.idle`, so the pill would read "Off" and hide the failure.
    /// - **`.running` with a stopped engine.** The device-configuration-change
    ///   handler leaves `captureState == .running` when an engine restart
    ///   throws; `AppViewModel` sets `engineIsRunning = false` and publishes
    ///   the error. Audio is silent while capture claims to be running.
    ///
    /// Letting *any* non-nil `lastError` win was the original bug: a stale
    /// error from an earlier attempt pinned the pill red while capture ran
    /// fine. Narrowing it to `.idle` alone was the opposite bug, reporting a
    /// green "Filtering …" over a dead pipeline. The condition is neither
    /// state alone — it is "there is an error and audio is not flowing".
    private var isSilentlyFailed: Bool {
        switch viewModel.captureState {
        case .idle:
            // A failed start rolls back to idle; only the error records it.
            return viewModel.lastError != nil
        case .running:
            // Not conditioned on `lastError`. Dismissing the banner
            // acknowledges the message, not the silence — if the pill went
            // green on dismissal it would report a healthy capture over a
            // stopped engine, which is the failure this branch exists for.
            return viewModel.engineStalled
        case .starting, .stopping, .failed:
            return false
        }
    }

    private var pillColor: Color {
        if isSilentlyFailed { return .red }
        switch viewModel.captureState {
        case .idle: return .secondary
        case .starting, .stopping: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var pillLabel: String {
        // Status only — short and stable. The full error text is shown in the
        // inline banner above the power toggle (and in the debug log), so the
        // header stays compact and a long error string never has to fit here.
        if isSilentlyFailed { return "Failed" }
        switch viewModel.captureState {
        case .idle: return "Off"
        case .starting: return "Starting"
        case .running:
            if let name = viewModel.currentSource?.displayName {
                return "Filtering \(name)"
            }
            return "On"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }
}

import Capture
import SwiftUI
import ViewModel

/// Large rounded button that toggles the capture chain on and off.
///
/// State drives label, style, and action per `docs/specs/ui.md` §PowerToggle:
/// idle → "Start", starting/stopping → spinner, running → "Stop", failed →
/// "Retry".
public struct PowerToggle: View {

    @EnvironmentObject public var viewModel: AppViewModel
    @FocusedValue(\.parameterNumericEditing) private var parameterNumericEditing

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: tap) {
                Group {
                    switch viewModel.captureState {
                    case .idle:
                        Label("Start", systemImage: "play.fill")
                    case .starting:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                    case .running:
                        Label("Stop", systemImage: "stop.fill")
                    case .stopping:
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Stopping…")
                        }
                    case .failed:
                        Label("Retry", systemImage: "exclamationmark.triangle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(parameterNumericEditing == true ? nil : KeyboardShortcut(.space, modifiers: []))
            .tint(buttonTint)
            .disabled(isDisabled)
            .accessibilityLabel("Power")
            .accessibilityValue(stateLabel)
            .accessibilityHint("Start or stop audio capture.")
        }
    }

    private func tap() {
        switch viewModel.captureState {
        case .idle:
            Task { await viewModel.powerOn() }
        case .running:
            Task { await viewModel.powerOff() }
        case .failed:
            // Per the button label, "Retry" should restart capture, not just
            // clear the error. The capture controller is already stopped in
            // .failed (powerOn's failure paths tear down before publishing
            // .failed), so calling powerOn directly is correct — no powerOff
            // first.
            viewModel.clearError()
            Task { await viewModel.powerOn() }
        case .starting, .stopping:
            // No-op; the button is disabled in these states.
            break
        }
    }

    private var isDisabled: Bool {
        switch viewModel.captureState {
        case .starting, .stopping: return true
        case .idle, .running, .failed: return false
        }
    }

    private var stateLabel: String {
        switch viewModel.captureState {
        case .idle: return "Off"
        case .starting: return "Starting"
        case .running: return "On"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }

    private var buttonTint: Color {
        switch viewModel.captureState {
        case .failed: return .red
        case .running: return .secondary
        default: return .accentColor
        }
    }
}

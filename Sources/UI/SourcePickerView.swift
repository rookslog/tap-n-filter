import AppKit
import Capture
import Darwin
import SwiftUI
import ViewModel

/// Source-selection control. Lists running applications with capturable audio
/// output and lets the user pick one. Disabled during capture state transitions.
public struct SourcePickerView: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Source")
                .font(.caption)
                .foregroundStyle(.secondary)

            // The picker selects by `pid` (Hashable). The closure maps the
            // selected pid back to the matching CaptureSource on set, which
            // is the only place we need the full value.
            //
            // The getter returns nil when `currentSource.pid` is no longer in
            // `availableSources` — otherwise SwiftUI binds to a "ghost" tag
            // that has no row, prints a runtime warning about the missing
            // selection, and can drop the user's pick on the next refresh
            // (because the picker silently coerces the unknown tag to the
            // first row). Returning nil maps to the "Select a source"
            // placeholder, which is the right visual when the previously
            // chosen process has quit.
            Picker(
                "Source",
                selection: Binding<pid_t?>(
                    get: {
                        guard let pid = viewModel.currentSource?.pid,
                              viewModel.availableSources.contains(where: { $0.pid == pid })
                        else { return nil }
                        return pid
                    },
                    set: { pid in
                        if let pid, let match = viewModel.availableSources.first(where: { $0.pid == pid }) {
                            viewModel.setSource(match)
                        } else {
                            viewModel.setSource(nil)
                        }
                    }
                )
            ) {
                Text("Select a source")
                    .tag(Optional<pid_t>.none)
                ForEach(viewModel.availableSources) { source in
                    SourceRow(source: source)
                        .tag(Optional(source.pid))
                }
            }
            .labelsHidden()
            .disabled(isInTransition)
            .help(
                "Audio is captured per process, not per browser tab. "
                + "For one site, try Safari's File → Add to Dock and choose its source here."
            )
            .accessibilityLabel("Audio source")
            .accessibilityValue(viewModel.currentSource?.displayName ?? "None")
            .accessibilityHint(
                "Pick a process, not a browser tab. For one site, try Safari's File → Add to Dock. "
                + "Changing while running stops capture."
            )
        }
    }

    /// True during `.starting` or `.stopping`; the source list must not change
    /// underneath an in-flight transition.
    private var isInTransition: Bool {
        switch viewModel.captureState {
        case .starting, .stopping: return true
        case .idle, .running, .failed: return false
        }
    }
}

/// One row in the source picker. Shows the app icon and display name.
public struct SourceRow: View {

    public let source: CaptureSource

    public init(source: CaptureSource) {
        self.source = source
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }
            Text(source.displayName)
        }
    }

    /// Resolve the app icon for this row's process.
    ///
    /// Looks the process up by pid, which is both O(1) and exact. The previous
    /// implementation filtered the entire `NSWorkspace.runningApplications`
    /// array by bundle identifier on every render of every row — O(rows ×
    /// running apps) per layout pass — and, when several instances of one app
    /// were running, could return a different instance's icon than the row
    /// actually refers to.
    ///
    /// Falls back to a bundle-identifier lookup for the case where the process
    /// has exited between enumeration and render. Returns nil when neither
    /// resolves; the row still renders its display name.
    private var icon: NSImage? {
        if let running = NSRunningApplication(processIdentifier: source.pid) {
            return running.icon
        }
        guard let bundleID = source.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .icon
    }
}

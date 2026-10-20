import AppKit
import SwiftUI
import ViewModel

/// Scrollable list of recent log lines, mounted below the footer when the
/// user chooses Diagnostics from the header's Settings menu.
///
/// The panel reads from `AppViewModel.debugLog`, which captures every
/// `info`/`warning`/`error` the view model emits — including the full
/// error text for `powerOn` failures that the compact status pill no
/// longer shows. The same lines also go to the OS unified log, so the
/// debug panel is a convenience surface, not a separate sink.
public struct DebugPanel: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            entries
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "ladybug.fill")
                .foregroundStyle(.secondary)
            Text("Debug log")
                .font(.caption)
                .fontWeight(.semibold)
            Spacer()
            Text("\(viewModel.debugLog.entries.count) entries")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Reveal log file in default text editor. The in-panel list
            // is a cramped subset; the file at ~/Library/Logs/tap-n-filter/
            // app.log has the full history with full ISO timestamps.
            Button {
                openLogFile()
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("Open log file in default editor")
            .accessibilityLabel("Open log file in default editor")
            // One-click copy of the entire log file to the clipboard.
            // Saves the "select all, scroll, scroll, scroll" dance in a
            // cramped MenuBarExtra window.
            Button {
                copyLogToClipboard()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("Copy entire log file to clipboard")
            .accessibilityLabel("Copy log file to clipboard")
            Button {
                viewModel.debugLog.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .help("Clear in-app debug log (file log is untouched)")
            .accessibilityLabel("Clear in-app debug log")
        }
    }

    private var entries: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if viewModel.debugLog.entries.isEmpty {
                    Text("No log entries yet. Press Power to capture; warnings and errors will appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(viewModel.debugLog.entries) { entry in
                    row(for: entry)
                }
            }
        }
        .frame(maxHeight: 180)
    }

    private func row(for entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: levelIcon(entry.level))
                .foregroundStyle(levelColor(entry.level))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(timeFormatter.string(from: entry.timestamp))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(entry.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(entry.message)
                    .font(.caption2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func levelIcon(_ level: DebugLogLevel) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func levelColor(_ level: DebugLogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }

    // MARK: - Log file actions

    /// Open the persistent log file in the default app for `.log` files
    /// (typically TextEdit; users with VS Code / BBEdit see it open there).
    /// The MenuBarExtra panel is too narrow to read the file inline; this
    /// gives a full-window, searchable view in one click.
    private func openLogFile() {
        guard let url = FileLogSink.shared.logFileURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copy the entire log file to the clipboard. Saves the
    /// "select all, scroll forever, paste" dance — useful for sharing
    /// diagnostics with anyone (or pasting into a chat with the
    /// orchestrator).
    private func copyLogToClipboard() {
        guard let url = FileLogSink.shared.logFileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contents, forType: .string)
    }
}

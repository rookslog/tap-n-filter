import AppKit
import Presets
import SwiftUI
import UniformTypeIdentifiers
import ViewModel

/// Preset save/load menu. "Save As…" and "Open…" trigger AppKit panels
/// (`NSSavePanel` / `NSOpenPanel`) directly because the SwiftUI
/// `.fileImporter` / `.fileExporter` modifiers are known-flaky from a
/// `MenuBarExtra` window. See ADR-012.
public struct PresetMenu: View {

    @EnvironmentObject public var viewModel: AppViewModel

    public init() {}

    public var body: some View {
        Menu {
            Button("Save") { savePreset() }
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityLabel("Save preset")
                .accessibilityHint("Save to the current file, or choose a file if needed.")

            Button("Save As…") { presentSavePanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .accessibilityLabel("Save preset as")
                .accessibilityHint("Write the current effect chain to a .tnf file.")

            Button("Open…") { presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Open preset")
                .accessibilityHint("Load an effect chain from a .tnf file.")

            Divider()

            Menu("Factory Presets") {
                ForEach(Presets.FactoryPresets.all, id: \.name) { preset in
                    Button(preset.displayName) {
                        viewModel.loadFactoryPreset(named: preset.name)
                    }
                    .accessibilityLabel("Load \(preset.displayName) preset")
                }
            }
        } label: {
            Label("Presets", systemImage: "doc")
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Presets menu")
        .accessibilityHint("Save, open, or pick a factory preset.")
    }

    private func savePreset() {
        if let url = viewModel.presetFileURL {
            viewModel.savePreset(to: url)
        } else {
            presentSavePanel()
        }
    }

    /// Present `NSSavePanel` for the .tnf file type. The panel is run modal
    /// against the menubar window when available, falling back to a detached
    /// modal session otherwise.
    private func presentSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [presetContentType]
        panel.nameFieldStringValue = viewModel.suggestedPresetFilename
        panel.canCreateDirectories = true
        runModalPanel(panel) { response, url in
            if response == .OK, let url = url {
                viewModel.savePreset(to: url)
            }
        }
    }

    /// Present `NSOpenPanel` for the .tnf file type. Single-file selection only.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [presetContentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        runModalPanel(panel) { response, url in
            if response == .OK, let url = url {
                viewModel.loadPreset(from: url)
            }
        }
    }

    /// Common run-modal helper. Tries to attach the panel to the current key
    /// window (the menubar popover when open); falls back to `runModal()` when
    /// no key window is available. AppKit dismisses the popover when the panel
    /// runs modal, which is the expected user-facing behaviour.
    private func runModalPanel(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse, URL?) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                completion(response, panel.url)
            }
        } else {
            let response = panel.runModal()
            completion(response, panel.url)
        }
    }

    /// The UTI for tap-n-filter presets. `.tnf` extension; treat as a JSON
    /// payload so Quick Look and friends do something reasonable by default.
    private var presetContentType: UTType {
        UTType(filenameExtension: "tnf") ?? .json
    }
}

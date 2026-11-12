import SoundModel
import SwiftUI

struct TNFEditorRenameSheet: View {
    @ObservedObject var commands: TNFEditorCommands
    let name: TNFEditorRename
    @TNFViewState private var text: String = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename").font(.headline)
            TextField("Name", text: $text).onSubmit(commit)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Rename", action: commit).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 360).onAppear { text = name.title }
    }
    private func commit() {
        Task {
            do {
                switch name.action {
                case .definition(let id): try commands.requireAccepted(await commands.app.rename(id, name: text).value)
                case .use(let binding): try commands.requireAccepted(await commands.app.nameUse(binding, name: text).value)
                case .control(let token, let path, let id): try await commands.renameControl(token, path: path, control: id, title: text)
                case .option(let token, let path, let id, let option): try await commands.renameOption(token, path: path, control: id, option: option, title: text)
                }
                dismiss()
            } catch { commands.fail(error) }
        }
    }
}

struct TNFEditorNewControl: View {
    @ObservedObject var commands: TNFEditorCommands
    let kind: TNFEditorControlKind
    @TNFViewState private var title: String = ""
    @TNFViewState private var first: String = "Off"
    @TNFViewState private var last: String = "On"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .switchControl ? "New Switch" : "New \(kind.rawValue.capitalized)").font(.headline)
            TextField("Name", text: $title)
            if kind != .slider { HStack { TextField("First Option", text: $first); TextField("Last Option", text: $last) } }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Add") { Task { do { try await commands.createControl(kind, title: title, first: first, last: last); dismiss() } catch { commands.fail(error) } } }.keyboardShortcut(.defaultAction).disabled(title.isEmpty) }
        }.padding(24).frame(width: 380)
    }
}

struct TNFEditorPlace: Identifiable {
    let place: LibraryUpdatePlace
    let name: String
    let bundle: String
    var id: String { place.use.uuidString + place.path.map(\.uuidString).joined() }
}
struct TNFEditorUpdateChooser: View {
    @ObservedObject var commands: TNFEditorCommands
    @TNFViewState private var selected: Set<LibraryUpdatePlace> = []
    @Environment(\.dismiss) private var dismiss
    var places: [TNFEditorPlace] {
        guard let definition = commands.definition else { return [] }
        return (commands.app.snapshot?.uses ?? []).flatMap { use -> [TNFEditorPlace] in
            var result: [TNFEditorPlace] = []
            if use.definition == definition.id { result.append(TNFEditorPlace(place: LibraryUpdatePlace(use: use.id), name: commands.appName(use.target) + " · " + use.name, bundle: use.target)) }
            for occurrence in use.occurrences where occurrence.reference?.definition == definition.id {
                result.append(TNFEditorPlace(place: LibraryUpdatePlace(use: use.id, path: occurrence.path), name: commands.appName(use.target) + " · " + use.name + " · " + (occurrence.controls.map(\.title).joined(separator: ", ")), bundle: use.target))
            }
            return result
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update Library").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(places) { entry in Toggle(isOn: Binding(get: { selected.contains(entry.place) }, set: { value in if value { selected.insert(entry.place) } else { selected.remove(entry.place) } })) { appNamedText(entry.name, bundle: entry.bundle, commands: commands) } }
                }
            }.frame(maxHeight: 280)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Preview…") { Task { do { try await commands.previewUpdate(places: places.filter { selected.contains($0.place) }.map(\.place)); dismiss() } catch { commands.fail(error) } } }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 480).onAppear { selected = Set(places.map(\.place)) }
    }
}

struct TNFEditorDialogs: View {
    @ObservedObject var commands: TNFEditorCommands
    var showing: Bool { commands.windowPresented && (commands.optionPlan != nil || commands.updatePlan != nil || commands.selectorPlan != nil || !commands.reports.isEmpty) }
    var body: some View {
        Color.clear.allowsHitTesting(false).sheet(isPresented: Binding(get: { showing }, set: { _ in })) {
            VStack(alignment: .leading, spacing: 16) {
                if let plan = commands.optionPlan {
                    Text("Change Options").font(.headline)
                    TNFEditorChoiceReport(commands: commands, report: plan.preview.report)
                    HStack { Spacer(); Button("Cancel") { run { try await commands.cancelPreview() } }.keyboardShortcut(.cancelAction); Button("Apply") { run { try await commands.applyOption() } }.keyboardShortcut(.defaultAction) }
                } else if let plan = commands.updatePlan {
                    Text("Update Library").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(plan.preview.places.enumerated()), id: \.offset) { _, place in appNamedText(commands.placeName(place), bundle: commands.app.snapshot?.uses.first { $0.id == place.use }?.target, commands: commands) }
                            ForEach(Array(plan.preview.removals.enumerated()), id: \.offset) { _, removal in
                                HStack {
                                    Text(commands.controlNames[removal.address.control] ?? "Control")
                                    Text(commands.optionNames[removal.removed] ?? "Option")
                                    Image(systemName: "arrow.right")
                                    Menu(commands.optionNames[removal.replacement] ?? "Option") {
                                        ForEach(commands.options(removal.address), id: \.id) { option in
                                            Button(option.title) { run { try await commands.replaceUpdate(removal, with: option.id) } }
                                        }
                                    }
                                }.font(.system(size: 12))
                            }
                            ForEach(plan.preview.brokenBindings, id: \.self) { id in
                                Label(commands.brokenBindingName(id), systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            TNFEditorChoiceReport(commands: commands, report: plan.preview.choices)
                        }
                    }.frame(maxHeight: 340)
                    HStack { Spacer(); Button("Cancel") { run { try await commands.cancelPreview() } }.keyboardShortcut(.cancelAction); Button("Update Library") { run { try await commands.confirmUpdate() } }.keyboardShortcut(.defaultAction) }
                } else if let (_, preview) = commands.selectorPlan {
                    Text("Use This Option for All?").font(.headline)
                    Text(commands.optionNames[preview.option] ?? "Option")
                    HStack { Spacer(); Button("Cancel") { run { try await commands.cancelPreview() } }.keyboardShortcut(.cancelAction); Button("Use for All") { run { try await commands.applySameForAll() } }.keyboardShortcut(.defaultAction) }
                } else if let receipt = commands.reports.first {
                    Text("Changes").font(.headline)
                    switch receipt.report {
                    case .choice(let report): TNFEditorChoiceReport(commands: commands, report: report)
                    case .update(let report):
                        TNFEditorChoiceReport(commands: commands, report: report.choices)
                    }
                    HStack { Spacer(); Button("Done") { commands.acknowledgeReport(receipt.request.command) }.keyboardShortcut(.defaultAction) }

                }
            }.padding(24).frame(minWidth: 480).interactiveDismissDisabled()
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { commands.fail(error) } } }
}
struct TNFEditorChoiceReport: View {
    @ObservedObject var commands: TNFEditorCommands
    let report: LibraryChoiceReport
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(report.changes.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    (appNamedText(commands.placeName(row.place), bundle: { if case .use(let bundle, _) = row.place { return bundle }; return nil }(), commands: commands)
                     + Text(" · \(commands.controlNames[row.address.control] ?? "Control"): \(commands.optionNames[row.before] ?? "Option") → \(commands.optionNames[row.after] ?? "Option")"))
                }.font(.system(size: 12))
            }
        }
    }
}


@MainActor private func appNamedText(_ name: String, bundle: String?, commands: TNFEditorCommands) -> Text {
    guard let bundle else { return Text(name) }
    let identity = commands.appIdentity(bundle)
    guard identity.isMissing, name.hasPrefix(identity.name) else { return Text(name) }
    return Text(identity.name).foregroundColor(.secondary) + Text(String(name.dropFirst(identity.name.count)))
}

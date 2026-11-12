import AppKit
import SoundModel
import SwiftUI

private struct TNFCardWidth: EnvironmentKey { static let defaultValue: CGFloat = 900 }
extension EnvironmentValues { var tnfCardWidth: CGFloat { get { self[TNFCardWidth.self] } set { self[TNFCardWidth.self] = newValue } } }

/// Window86.ProtoWindow: the panels and floating bar retain the source's own geometry.
struct TNFEditorSurface: View {
    @ObservedObject var commands: TNFEditorCommands
    var titleChanged: (String) -> Void = { _ in }
    var body: some View {
        GeometryReader { geo in
            let main = geo.size.width - 44 - (commands.sidebarVisible ? 296 : 0)
            HStack(alignment: .top, spacing: 0) {
                if commands.sidebarVisible {
                    VStack(spacing: 14) {
                        TNFEditorTreePanel(commands: commands)
                            .frame(width: 250, alignment: .topLeading).padding(14)
                            .tnfFloating(radius: 24)
                            .frame(maxHeight: geo.size.height * 0.52, alignment: .top)
                        ScrollView { TNFEditorLibraryShelf(commands: commands).frame(width: 250, alignment: .topLeading) }
                            .scrollIndicators(.automatic).padding(14).tnfFloating(radius: 24)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding(.bottom, commands.editing ? TNFEditorWindowBudget.sidebarBottom : 0).padding(.trailing, 18)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ScrollView { TNFEditorMainCard(commands: commands).padding(.bottom, TNFEditorWindowBudget.cardBottom) }
                    .scrollIndicators(.automatic).frame(width: main)
                    .environment(\.tnfCardWidth, main - 44)
            }
            .padding(.horizontal, TNFEditorWindowBudget.margin).padding(.top, TNFEditorWindowBudget.top).padding(.bottom, TNFEditorWindowBudget.margin)
            .overlay(alignment: .bottom) {
                if commands.editing {
                    TNFEditorQuickBar(commands: commands).padding(.bottom, TNFEditorWindowBudget.gap)
                        .frame(maxWidth: .infinity).padding(.horizontal, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(TNFEditorGround()).environment(\.colorScheme, .dark)
        .onChange(of: commands.title) { _, title in titleChanged(title) }
        .animation(.snappy(duration: 0.3), value: commands.sidebarVisible)
        .animation(.snappy(duration: 0.3), value: commands.editing)
        .sheet(item: $commands.renameSheet) { name in TNFEditorRenameSheet(commands: commands, name: name) }
        .sheet(isPresented: $commands.updateChooser) { TNFEditorUpdateChooser(commands: commands) }
        .sheet(item: $commands.newControlKind) { kind in TNFEditorNewControl(commands: commands, kind: kind) }
        .overlay { TNFEditorDialogs(commands: commands) }
        .onExitCommand { commands.perform { try await commands.cancelPreview() }; commands.renameSheet = nil; commands.updateChooser = false; commands.newControlKind = nil }
    }
}

/// Proto.MainCard, without unsupported LiveView/slots/right column.
struct TNFEditorMainCard: View {
    @ObservedObject var commands: TNFEditorCommands
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if commands.target != nil {
                header.zIndex(2)
                TNFEditorBlockFace(commands: commands)
                if let edit = commands.edit {
                    TNFEditorPieces(commands: commands, edit: edit, token: commands.adapter.token)
                    if let id = commands.openPart, let part = edit.parts.first(where: { $0.id == id }) {
                        TNFEditorPartTray(commands: commands, part: part, token: commands.adapter.token)
                    }
                    if let path = commands.openBlock { TNFEditorSection(commands: commands, path: path, depth: path.count) }
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
    private var header: some View {
        let token = commands.adapter.token
        return HStack(spacing: 10) {
            TNFEditorBlockTile(definition: commands.definition, name: commands.title, size: 34)
            Text(commands.title).font(.system(size: 19, weight: .semibold))
                .onTapGesture(count: 2) { commands.requestRename() }
                .contextMenu { Button("Rename…") { commands.requestRename() }.disabled(!commands.canAuthor) }
            TNFEditorLinkBadge(commands: commands)
            Spacer()
            TNFEditorEar(commands: commands).frame(width: 28, height: 28).background(Color.primary.opacity(0.07), in: Circle())
            if let warning = commands.durabilityWarning {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.yellow)
                    .help(warning).accessibilityLabel(warning)
            }
            if commands.editing {
                Menu {
                    Button("Discard Changes") { commands.perform(token: token) { try await commands.discard() } }
                } label: {
                    HStack(spacing: 6) { Text("Done"); Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
                        .font(.system(size: 14, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                } primaryAction: { commands.perform(token: token) { try await commands.done() } }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().tnfFloating(radius: 22)
            } else {
                Button { commands.perform(token: token) { try commands.startEditing() } } label: {
                    Text("Edit").font(.system(size: 14, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 7)
                }.buttonStyle(.plain).tnfFloating(radius: 22).disabled(!commands.canAuthor)
            }
        }
    }
}

/// Edit.BlockFace: no analysis producer, and no substitute show-live-view button.
struct TNFEditorBlockFace: View {
    @ObservedObject var commands: TNFEditorCommands
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commands.controls, id: \.id) { control in
                    if control.face != .xy { TNFEditorControlRow(commands: commands, control: control, token: commands.adapter.token, rename: $commands.renameSheet) }
                }
            }.padding(4)
        }
    }
}

/// Edit.Section: nested controls use their qualified path, never a browse-created edit.
struct TNFEditorSection: View {
    @ObservedObject var commands: TNFEditorCommands
    let path: [UUID]
    let depth: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if path.count > 1 { TNFEditorTopStrip(commands: commands, path: (0..<path.count).map { Array(path.prefix($0)) }) }
                Button { withAnimation(.snappy(duration: 0.25)) { commands.openBlock = nil } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(90)).foregroundStyle(.secondary).frame(width: 18, height: 18).contentShape(.rect)
                }.buttonStyle(.plain).help("Close")
                TNFEditorBlockTile(definition: commands.blockDefinition(path), name: commands.blockName(path), size: 24)
                Text(commands.blockName(path)).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(commands.projection?.mappings.descriptors.filter { $0.address.path == path } ?? [], id: \.address) { descriptor in
                    if let control = descriptor.presentation, control.face != .xy {
                        TNFEditorControlRow(commands: commands, control: control, token: commands.adapter.token, path: path, rename: $commands.renameSheet)
                    }
                }
            }.padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2).padding(.leading, 4) }
                .transition(.opacity.combined(with: .move(edge: .top)))
        }.padding(12)
            .background(.quaternary.opacity(depth > 1 ? 0.2 : 0.35), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Blocks73.LinkBadge, with the exact FOLLOWUP noninteractive state projection.
struct TNFEditorLinkBadge: View {
    @ObservedObject var commands: TNFEditorCommands
    var body: some View {
        if let help = commands.linkHelp {
            HStack(spacing: 4) {
                Image(systemName: commands.binding == nil ? "books.vertical.fill" : commands.edit?.pendingStructural == true ? "link.badge.plus" : "link").font(.system(size: 12, weight: .semibold))
                if commands.changedHere { Circle().fill(Color.accentColor).frame(width: 6, height: 6) }
            }.padding(.horizontal, 8).frame(height: 22).foregroundStyle(.secondary)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .help(help).accessibilityElement(children: .ignore).accessibilityLabel(commands.title + ": " + help)
        }
    }
}

/// Proto.TopStrip is retained only for an inline nested path; never an outside breadcrumb/output row.
struct TNFEditorTopStrip: View {
    @ObservedObject var commands: TNFEditorCommands
    let path: [[UUID]]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(path, id: \.self) { part in
                    Button { commands.openBlock = part.isEmpty ? nil : part } label: {
                        HStack(spacing: 6) { TNFEditorBlockTile(definition: commands.blockDefinition(part), name: commands.blockName(part), size: 22); Text(commands.blockName(part)).font(.system(size: 13, weight: part == commands.openBlock ? .semibold : .regular)) }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(part == commands.openBlock ? AnyShapeStyle(Color.primary.opacity(0.09)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }.buttonStyle(.plain)
                    HStack(spacing: 0) { Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 14, height: 2); Circle().fill(Color.accentColor).frame(width: 5, height: 5) }.accessibilityHidden(true)
                }
            }.padding(.vertical, 4)
        }.scrollIndicators(.hidden)
    }
}

struct TNFEditorFlowMark: View {
    let block: Bool
    var body: some View {
        ZStack {
            Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 2)
            if block { Circle().strokeBorder(Color.accentColor, lineWidth: 2).background(Circle().fill(Color(nsColor: .windowBackgroundColor))).frame(width: 9, height: 9) }
            else { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
        }.frame(width: 12).frame(maxHeight: .infinity).accessibilityHidden(true)
    }
}
struct TNFEditorTreePanel: View {
    @ObservedObject var commands: TNFEditorCommands
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands.app.snapshot?.assignments ?? [], id: \.id) { assignment in
                    let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
                    if let use = commands.app.snapshot?.uses.first(where: { $0.id == assignment.use }) {
                        HStack(spacing: 8) { TNFEditorAppIcon(identity: commands.appIdentity(assignment.target), size: 24); Text(commands.appName(assignment.target)).font(.system(size: 13, weight: .semibold)).foregroundStyle(commands.appIdentity(assignment.target).isMissing ? .secondary : .primary); Spacer(minLength: 0) }.padding(.vertical, 4)
                        TNFEditorTreeRow(commands: commands, binding: binding, name: use.name, path: [], part: nil, type: nil, depth: 0)
                        if commands.binding == binding, !commands.collapsedTree.contains(TNFEditorTreeKey(use: binding.use, path: [])), let edit = commands.edit {
                            ForEach(Array(edit.pieces.enumerated()), id: \.offset) { _, piece in
                                switch piece {
                                case .part(let id): if let part = edit.parts.first(where: { $0.id == id }) { TNFEditorTreeRow(commands: commands, binding: binding, name: TNFEditorNames.part(part.type), path: [], part: id, type: part.type, depth: 1) }
                                case .embedded(let site, _), .reference(let site, _, _):
                                    TNFEditorTreeRows(commands: commands, binding: binding, path: [site], depth: 1)
                                }
                            }
                        }
                    }
                }
            }
        }.scrollIndicators(.automatic)
    }
}
/// Proto.TreeRows: recurse only current read-projection occurrences, no second node store.
struct TNFEditorTreeRows: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryBinding
    let path: [UUID]
    let depth: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TNFEditorTreeRow(commands: commands, binding: binding, name: commands.blockName(path), path: path, part: nil, type: nil, depth: depth)
            if !commands.collapsedTree.contains(TNFEditorTreeKey(use: binding.use, path: path)) {
                ForEach(commands.edit?.occurrences.filter { $0.path.count == path.count + 1 && Array($0.path.prefix(path.count)) == path } ?? [], id: \.path) { occurrence in
                    TNFEditorTreeRows(commands: commands, binding: binding, path: occurrence.path, depth: depth + 1)
                }
            }
        }
    }
}
struct TNFEditorTreeRow: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryBinding
    let name: String
    let path: [UUID]
    let part: UUID?
    let type: String?
    let depth: Int
    var body: some View {
        let here = commands.binding == binding && (part != nil ? commands.openPart == part : path.isEmpty ? commands.openPart == nil && commands.openBlock == nil : commands.openBlock == path)
        HStack(spacing: 7) {
            Color.clear.frame(width: 12, height: 1)
            HStack(spacing: 7) {
                Color.clear.frame(width: CGFloat(depth) * 14, height: 1)
                if type == nil {
                    let key = TNFEditorTreeKey(use: binding.use, path: path)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(commands.collapsedTree.contains(key) ? 0 : 90))
                        .frame(width: 12, height: 20).contentShape(.rect)
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { if commands.collapsedTree.contains(key) { commands.collapsedTree.remove(key) } else { commands.collapsedTree.insert(key) } } }
                } else { Color.clear.frame(width: 12, height: 1) }
                if let type { TNFEditorTile(tint: .tnfPortGrey, symbol: TNFEditorNames.symbol(type), size: 20) }
                else { TNFEditorBlockTile(definition: commands.blockDefinition(path, binding: binding), name: name, size: 24) }
                Text(name).font(.system(size: 13, weight: type == nil ? .medium : .regular)).lineLimit(1).foregroundStyle(type == nil ? .primary : .secondary)
                Spacer(minLength: 0)
            }.padding(.vertical, 4)
        }.padding(.horizontal, 6)
            .background(alignment: .leading) { TNFEditorFlowMark(block: type == nil).padding(.leading, 6) }
            .background(here ? AnyShapeStyle(Color.primary.opacity(0.09)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(.rect).onTapGesture {
                commands.perform { try await commands.select(.use(binding)); commands.openPart = part; commands.openBlock = path.isEmpty ? nil : path }
            }
            .contextMenu {
                if part == nil && path.isEmpty {
                    Button("Rename…") { commands.renameSheet = TNFEditorRename(title: name, action: .use(binding)) }
                    Button("Use the Library’s Name") { commands.perform { try await commands.select(.use(binding)); try await commands.useLibraryName() } }
                }
            }
    }
}
struct TNFEditorAppIcon: View {
    let identity: TNFEditorAppIdentity
    let size: CGFloat
    var body: some View {
        Group {
            if let image = identity.image {
                Image(nsImage: image).renderingMode(identity.isMissing ? .template : .original).resizable()
            }
        }.frame(width: size, height: size).foregroundStyle(identity.isMissing ? .secondary : .primary)
            .accessibilityLabel(identity.name)
    }
}

/// Edit72.LibraryShelf: original search/section/row expressions, real library identities.
struct TNFEditorLibraryShelf: View {
    @ObservedObject var commands: TNFEditorCommands
    var definitions: [LibraryDefinitionSummary] { (commands.app.snapshot?.definitions ?? []).filter { commands.librarySearch.isEmpty || $0.name.localizedCaseInsensitiveContains(commands.librarySearch) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Library", text: $commands.librarySearch).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(.horizontal, 8).frame(height: 26)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous)).padding(.bottom, 6)
            section("Your Blocks", plus: {
                commands.perform { let result = await commands.app.createEmpty(name: "Untitled Block").value; try commands.requireAccepted(result); await commands.app.coordinator.refresh(); if let ref = result.creation?.acceptedReference { try await commands.select(.definition(ref.definition)) } }
            }) { ForEach(definitions.filter { $0.origin == "custom" }, id: \.id) { blockRow($0) } }
            section("Built In") { ForEach(definitions.filter { $0.origin != "custom" }, id: \.id) { blockRow($0) } }
            section("Parts") {
                ForEach((commands.edit?.kinds ?? []).filter { commands.librarySearch.isEmpty || TNFEditorNames.part($0.type).localizedCaseInsensitiveContains(commands.librarySearch) }, id: \.type) { kind in
                    Button { commands.perform { try await commands.command(.addPart(type: kind.type, at: commands.edit?.parts.count ?? 0)) } } label: {
                        HStack(spacing: 8) { TNFEditorTile(tint: .tnfPortGrey, symbol: TNFEditorNames.symbol(kind.type), size: 22); Text(TNFEditorNames.part(kind.type)).font(.system(size: 13)).lineLimit(1); Spacer(minLength: 0) }
                            .frame(height: 28).padding(.horizontal, 6).contentShape(.rect)
                    }.buttonStyle(.plain).disabled(!commands.editing || !commands.canAuthor || !kind.canInsert)
                }
            }
        }
    }
    @ViewBuilder private func section<C: View>(_ name: String, plus: (() -> Void)? = nil, @ViewBuilder rows: () -> C) -> some View {
        HStack { Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary); Spacer(); if let plus { Button(action: plus) { Image(systemName: "plus").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 18) }.buttonStyle(.plain).foregroundStyle(.secondary).help("New Block").accessibilityLabel("New Block") } }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
        rows()
    }
    private func blockRow(_ definition: LibraryDefinitionSummary) -> some View {
        let here = commands.definition?.id == definition.id
        return HStack(spacing: 8) {
            TNFEditorBlockTile(definition: definition, name: definition.name, size: 22)
            Text(definition.name).font(.system(size: 13, weight: here ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if here {
                ForEach((commands.app.snapshot?.uses ?? []).filter { use in use.definition == definition.id && commands.app.snapshot?.assignments.contains(where: { $0.use == use.id }) == true }.prefix(2), id: \.id) { use in TNFEditorAppIcon(identity: commands.appIdentity(use.target), size: 16).help(commands.appIdentity(use.target).isMissing ? "" : "On \(commands.appName(use.target))") }
            }
        }.frame(height: 28).padding(.horizontal, 6).contentShape(.rect)
            .background(here ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture(count: 2) { if definition.origin == "custom" { commands.renameSheet = TNFEditorRename(title: definition.name, action: .definition(definition.id)) } }
            .onTapGesture { commands.perform { try await commands.select(.definition(definition.id)) } }
            .contextMenu {
                Button("Rename…") { commands.renameSheet = TNFEditorRename(title: definition.name, action: .definition(definition.id)) }.disabled(definition.origin != "custom")
                Button("Duplicate") { commands.perform { try commands.requireAccepted(await commands.app.duplicate(LibraryReference(definition: definition.id, revision: definition.revision), name: definition.name + " Copy").value) } }
                Toggle("In the Menu", isOn: Binding(get: { definition.inTheMenu }, set: { visible in commands.perform { try commands.requireAccepted(await commands.app.setInMenu(definition.id, visible: visible).value) } }))
            }
    }
}

/// Proto.QuickBar and BarItem: admitted insertion actions only, no inert customization.
struct TNFEditorQuickBar: View {
    @ObservedObject var commands: TNFEditorCommands
    var body: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                items.padding(.horizontal, 16).padding(.vertical, TNFEditorWindowBudget.barVerticalPadding)
                ScrollView(.horizontal) { items.padding(.horizontal, 16).padding(.vertical, TNFEditorWindowBudget.barVerticalPadding) }.scrollIndicators(.hidden)
            }.fixedSize(horizontal: false, vertical: true).tnfFloating(radius: 100)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var items: some View {
        HStack(spacing: 10) {
            ForEach(commands.edit?.kinds ?? [], id: \.type) { kind in
                item(TNFEditorNames.part(kind.type), symbol: TNFEditorNames.symbol(kind.type), tint: .tnfPortGrey) { commands.perform { try await commands.command(.addPart(type: kind.type, at: commands.edit?.parts.count ?? 0)) } }.disabled(!commands.canAuthor || !kind.canInsert)
            }
            Divider().frame(height: 26)
            item("Slider", symbol: "slider.horizontal.3", tint: .tnfPortOrange) { commands.newControlKind = .slider }
            item("Choice", symbol: "rectangle.split.2x1", tint: .tnfPortOrange) { commands.newControlKind = .choice }
            item("Switch", symbol: "switch.2", tint: .tnfPortOrange) { commands.newControlKind = .switchControl }
        }.buttonStyle(.plain)
    }
    private func item(_ name: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 3) { TNFEditorTile(tint: tint, symbol: symbol, size: TNFEditorWindowBudget.barIcon).frame(width: TNFEditorWindowBudget.barIcon, height: TNFEditorWindowBudget.barIcon).contentShape(.rect) } }.help(name).accessibilityLabel(name)
    }
}

@MainActor extension TNFEditorCommands {
    var blockTint: Color { definition.map(tint) ?? .tnfPortOrange }
    var blockSymbol: String { definition.map(symbol) ?? "square.stack.3d.up.fill" }
    func tint(_ definition: LibraryDefinitionSummary) -> Color {
        switch definition.builtin {
        case .everyday: return Color(tnfPortHex: 0x30B0C7)
        case .filters: return Color(tnfPortHex: 0x0A84FF)
        case nil: return Color(nsColor: .systemPurple)
        }
    }
    func symbol(_ definition: LibraryDefinitionSummary) -> String {
        switch definition.builtin { case .everyday: return "cup.and.saucer.fill"; case .filters: return "slider.horizontal.3"; case nil: return "" }
    }
    func targetBound(_ mapping: LibraryMappingSummary, upper: Bool) -> String {
        switch mapping.target {
        case .setting(let id, let key):
            guard let setting = edit?.parts.first(where: { $0.id == id })?.settings.first(where: { $0.parameter == key }) else { return "" }
            return TNFEditorNames.value(upper ? setting.specification.upper : setting.specification.lower, key: key) + (setting.unit.isEmpty ? "" : " " + setting.unit)
        case .control: return ""
        }
    }
}

/// Uses the app's existing MenuDecoration identity, inside the reference Tile drawing.
struct TNFEditorBlockTile: View {
    let definition: LibraryDefinitionSummary?
    let name: String
    let size: CGFloat
    var body: some View {
        let tint: Color = definition?.builtin == .everyday ? Color(tnfPortHex: 0x30B0C7) : definition?.builtin == .filters ? Color(tnfPortHex: 0x0A84FF) : Color(nsColor: .systemPurple)
        let symbol = definition?.builtin == .everyday ? "cup.and.saucer.fill" : "slider.horizontal.3"
        TNFEditorTile(tint: tint, symbol: symbol, monogram: definition?.builtin == nil ? String((definition?.name ?? name).prefix(1)).uppercased() : nil, size: size)
    }
}

import AppKit
import SoundModel
import SwiftUI

/// Edit.ControlRow and Proto.LeverRow: original columns, disclosure and track body.
struct TNFEditorControlRow: View {
    @ObservedObject var commands: TNFEditorCommands
    let control: LibraryControl
    let token: LibraryEditorToken?
    var path: [UUID] = []
    @Binding var rename: TNFEditorRename?
    @Environment(\.tnfCardWidth) private var availableWidth
    @TNFViewState private var namingOption = false
    @TNFViewState private var optionName = ""
    var address: LibraryControlAddress { LibraryControlAddress(path: path, control: control.id) }
    var opened: Bool { commands.openControls.contains(address) }
    var bindings: [LibraryMappingSummary] { commands.projection?.mappings.bindings.filter { $0.path == path && $0.source.control == control.id } ?? [] }
    var trackWidth: CGFloat { TNFEditorAxis.cardTrack(width: Double(availableWidth)).width }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: TNFEditorCols.gap) {
                disclosure
                HStack(spacing: 6) {
                    Text(control.title).font(.system(size: 14, weight: opened ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(opened ? Color.accentColor : Color.primary)
                        .onTapGesture(count: 2) { commands.restoreNameToggle(address, interval: NSEvent.doubleClickInterval); beginRename() }
                    if controlIsChoice && commands.editing { Spacer(minLength: 0); addOption }
                }.frame(width: 96, alignment: .leading)
                face.frame(width: trackWidth, alignment: .leading)
            }.padding(.vertical, controlIsChoice ? 6 : 8).padding(.horizontal, 8)
                .modifier(TNFEditorHeaderClick(commands: commands, key: address))
                .contextMenu { rowMenu }
            if opened, let selector = bindings.compactMap(\.selector).first { optionTabs(selector) }
            if opened { TNFEditorCurveLanes(commands: commands, bindings: bindings, token: token, width: trackWidth) }
        }
    }
    /// pass2 Edit.ControlRow.optionTabs: one real segmented selector above its lane set.
    @ViewBuilder private func optionTabs(_ selector: UUID) -> some View {
        let key = LibraryControlAddress(path: path, control: selector)
        if let descriptor = commands.projection?.mappings.descriptors.first(where: { $0.address == key }),
           let presentation = descriptor.presentation, case .choice(let options) = presentation.face {
            HStack(spacing: TNFEditorCols.gap) {
                Color.clear.frame(width: TNFEditorLayout.trackX - 12, height: 1)
                Picker("", selection: Binding(get: { options.min { abs($0.position - commands.scalar(key)) < abs($1.position - commands.scalar(key)) }?.id ?? selector }, set: { id in
                    if let option = options.first(where: { $0.id == id }) { commands.perform(token: token) { try await commands.move(key, to: option.position) } }
                })) { ForEach(options, id: \.id) { option in Text(option.title).tag(option.id) } }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize().help("For each \(presentation.title)")
                Spacer(minLength: 0)
            }
        }
    }
    private var controlIsChoice: Bool { if case .choice = control.face { return true }; return false }
    private var disclosure: some View {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(opened ? 90 : 0)).foregroundStyle(opened ? Color.accentColor : .secondary)
            .frame(width: 16, height: 22).contentShape(.rect)
            .onTapGesture { commands.toggleOpen(address, clicks: NSApp?.currentEvent?.clickCount ?? 1) }.accessibilityLabel(opened ? "Close \(control.title)" : "Open \(control.title)")
    }
    @ViewBuilder private var face: some View {
        switch control.face {
        case .slider:
            TNFEditorTrack(value: commands.scalar(address), label: control.title, onStep: step,
                           locked: !commands.editing && commands.binding == nil,
                           onBegin: { do { try commands.beginPositionGesture(address) } catch { commands.fail(error) } }, onEnd: endPosition) { value in
                do { try commands.validateCallback(token); let receipt = try commands.admitMove(address, to: value); commands.perform(token: token) { try await commands.consume(receipt) } } catch { commands.fail(error) }
            }.overlay(alignment: .bottom) { ticks.offset(y: 12) }
        case .choice(let options):
            HStack(spacing: TNFEditorCols.gap) {
                ScrollView(.horizontal) {
                    Picker("", selection: Binding(get: { options.min { abs($0.position - commands.scalar(address)) < abs($1.position - commands.scalar(address)) }?.id ?? control.id }, set: { id in if let option = options.first(where: { $0.id == id }) { commands.perform(token: token) { try await commands.move(address, to: option.position) } } })) {
                        ForEach(options, id: \.id) { option in Text(option.title).tag(option.id) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel(control.title)
                        .disabled(!commands.editing && commands.binding == nil)
                }.scrollIndicators(.automatic).fixedSize(horizontal: false, vertical: true)

            }
        case .xy: EmptyView()
        }
    }
    private var addOption: some View {
                    Button { namingOption = true } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 22).background(Color.primary.opacity(0.07), in: Circle())
                    }.buttonStyle(.plain).help("Add an option to \(control.title)")
                        .popover(isPresented: $namingOption, arrowEdge: .bottom) {
                            TextField("Option", text: $optionName).textFieldStyle(.roundedBorder).frame(width: 170).padding(12)
                                .onSubmit { let name = optionName.trimmingCharacters(in: .whitespaces); if !name.isEmpty { commands.perform(token: token) { try await commands.previewOption(address, mutation: .add(id: UUID(), title: name, at: commands.options(address).count)); try await commands.applyOption() } }; namingOption = false; optionName = "" }
                        }.disabled(!commands.canAuthor)
    }
    private var ticks: some View {
        let points = commands.projection?.mappings.descriptors.first { $0.address == address }?.waypoints[.value] ?? []
        return GeometryReader { geo in
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                TNFEditorWaypointGlyph(index: index, count: points.count, lit: abs(commands.scalar(address) - point) < 1e-9, adaptive: false)
                    .frame(width: 26, height: 16).position(x: geo.size.width * point, y: 4)
            }
        }.frame(height: 8).allowsHitTesting(false).accessibilityHidden(true)
    }
    @ViewBuilder private var rowMenu: some View {
        Button(opened ? "Close" : "Open") { commands.toggleOpen(address, clicks: 1) }
        Button("Rename…", action: beginRename).disabled(!commands.canAuthor)
        if case .choice(let options) = control.face {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Menu(option.title) {
                    Button("Rename…") { if let token { rename = TNFEditorRename(title: option.title, action: .option(token, path, control.id, option.id)) } }.disabled(!commands.canAuthor)
                    if options.count > 2 {
                        Menu("Remove Option") { ForEach(options.filter { $0.id != option.id }, id: \.id) { replacement in Button("Replace with \(replacement.title)") { commands.perform(token: token) { try await commands.previewOption(address, mutation: .remove(id: option.id, replacement: replacement.id)) } } } }.disabled(!commands.editing || !commands.canAuthor)
                    }
                    if index > 0 { Button("Move Left") { reorder(options, from: index, to: index - 1) }.disabled(!commands.editing || !commands.canAuthor) }
                    if index + 1 < options.count { Button("Move Right") { reorder(options, from: index, to: index + 1) }.disabled(!commands.editing || !commands.canAuthor) }
                }
            }
        }
        if commands.editing {
            Menu("Different for Each Option") {
                ForEach(commands.controls.filter { if case .choice = $0.face { return $0.id != control.id }; return false }, id: \.id) { selector in Button(selector.title) { commands.perform(token: token) { try await commands.mapping(.differentForOptions(source: control.id, selector: selector.id), path: path) } } }
            }.disabled(!commands.canAuthor)
            if bindings.contains(where: { $0.selector != nil }) { Button("Use This Option for All…") { commands.perform(token: token) { try await commands.previewSameForAll(path: path, source: control.id) } }.disabled(!commands.canAuthor) }
            Button("Remove Control", role: .destructive) { commands.perform(token: token) { try await commands.mapping(.removeControl(control.id), path: path) } }.disabled(!commands.canAuthor)
        }
    }
    private func beginRename() { if let token, commands.canAuthor { rename = TNFEditorRename(title: control.title, action: .control(token, path, control.id)) } }
    private func endPosition() {
        do { try commands.validateCallback(token); let receipt = try commands.admitEndPositionGesture(); commands.perform(token: token) { try await commands.consume(receipt) } } catch { commands.fail(error) }
    }
    private func step(_ delta: Int) {
        let points = commands.projection?.mappings.descriptors.first { $0.address == address }?.waypoints[.value] ?? []
        let value = commands.scalar(address), next = delta > 0 ? points.first { $0 > value + 1e-9 } : points.last { $0 < value - 1e-9 }
        if let next { commands.perform(token: token) { try await commands.move(address, to: next) } }
    }
    private func reorder(_ options: [LibraryOption], from: Int, to: Int) {
        var result = options; result.swapAt(from, to)
        result = result.enumerated().map { LibraryOption(id: $0.element.id, title: $0.element.title, position: Double($0.offset) / Double(result.count - 1)) }
        commands.perform(token: token) { try await commands.mapping(.choiceOptions(control: control.id, options: result, tables: [:]), path: path) }
    }
}

/// Proto.PiecesRow and RowFlow. Tile power is deliberately omitted (F8); tray power stays real.
struct TNFEditorPieces: View {
    @ObservedObject var commands: TNFEditorCommands
    let edit: LibraryEditSnapshot
    let token: LibraryEditorToken?
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(edit.pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .part(let id):
                    if let part = edit.parts.first(where: { $0.id == id }) {
                        Button { commands.openPart = commands.openPart == id ? nil : id; commands.openBlock = nil } label: {
                            VStack(spacing: 6) { TNFEditorTile(tint: .tnfPortGrey, symbol: TNFEditorNames.symbol(part.type), size: 52).opacity(part.bypassed ? 0.4 : 1); Text(TNFEditorNames.part(part.type)).font(.system(size: 11, weight: .medium)).lineLimit(1) }.frame(width: 84)
                        }.buttonStyle(.plain).help("Open \(TNFEditorNames.part(part.type))")
                            .contextMenu {
                                Button("Move Left") { move(id, by: -1) }.disabled(!commands.editing || edit.parts.first?.id == id)
                                Button("Move Right") { move(id, by: 1) }.disabled(!commands.editing || edit.parts.last?.id == id)
                                Button("Remove Part", role: .destructive) { commands.perform(token: token) { try await commands.command(.removePart(id)) } }.disabled(!commands.editing || !commands.canAuthor)
                            }
                    }
                case .embedded(let site, _), .reference(let site, _, _):
                    Button { commands.openBlock = commands.openBlock == [site] ? nil : [site]; commands.openPart = nil } label: {
                        VStack(spacing: 6) { TNFEditorBlockTile(definition: commands.blockDefinition([site]), name: commands.blockName([site]), size: 52); Text(commands.blockName([site])).font(.system(size: 11, weight: .medium)).lineLimit(1) }.frame(width: 84)
                    }.buttonStyle(.plain).help("Open \(commands.blockName([site]))")
                        .contextMenu { Button("Make It Its Own") { commands.perform(token: token) { try await commands.mapping(.makeLocal(path: [site])) } }.disabled(!commands.editing || !commands.canAuthor) }
                }
            }
        }.background { TNFEditorRowFlow(slots: edit.pieces.map { _ in 84 }, gap: 14, open: false) }.padding(.leading, 2)
    }
    private func move(_ id: UUID, by delta: Int) {
        var order = edit.parts.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        commands.perform(token: token) { try await commands.command(.reorderParts(order)) }
    }
}
struct TNFEditorRowFlow: View {
    var slots: [CGFloat]
    var gap: CGFloat
    var open: Bool
    var body: some View {
        let total = slots.reduce(0, +) + gap * CGFloat(max(0, slots.count - 1))
        Canvas { ctx, size in
            ctx.translateBy(x: 18, y: 0)
            let y: CGFloat = 26, ink = Color.accentColor.opacity(0.5)
            var line = Path(); line.move(to: CGPoint(x: -10, y: y)); line.addLine(to: CGPoint(x: open ? size.width - 18 : total + 12, y: y))
            ctx.stroke(line, with: .color(ink), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: -14, y: y - 4, width: 8, height: 8)), with: .color(ink))
            if !open {
                var x: CGFloat = 0
                for (i, w) in slots.enumerated() {
                    x += w
                    if i < slots.count - 1 {
                        let c = x + gap / 2
                        var ch = Path(); ch.move(to: CGPoint(x: c - 2, y: y - 4)); ch.addLine(to: CGPoint(x: c + 2, y: y)); ch.addLine(to: CGPoint(x: c - 2, y: y + 4))
                        ctx.stroke(ch, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                    x += gap
                }
                var head = Path(); let e = total + 12
                head.move(to: CGPoint(x: e - 5, y: y - 5)); head.addLine(to: CGPoint(x: e + 1, y: y)); head.addLine(to: CGPoint(x: e - 5, y: y + 5))
                ctx.stroke(head, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: total + 44, height: 52).offset(x: -18)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
/// Proto.Tray: same coloured band/header and underlying PartCard.
struct TNFEditorPartTray: View {
    @ObservedObject var commands: TNFEditorCommands
    let part: LibraryEditPart
    let token: LibraryEditorToken?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TNFEditorPartCard(commands: commands, part: part, token: token)
        }.padding(16).padding(.top, 34)
            .background(commands.blockTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    Image(systemName: TNFEditorNames.symbol(part.type)).font(.system(size: 12, weight: .semibold))
                    Text(TNFEditorNames.part(part.type)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { commands.perform(token: token) { try await commands.quickBypass(part.id, bypassed: !part.bypassed) } } label: { Image(systemName: "power").font(.system(size: 12, weight: .semibold)) }.buttonStyle(.plain).disabled(!commands.canAuthor).help(part.bypassed ? "Turn On" : "Turn Off")
                    Button { commands.openPart = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }.buttonStyle(.plain).help("Close Part")
                }.foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                    .background(commands.blockTint.opacity(0.85), in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
            }.overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(commands.blockTint.opacity(0.35), lineWidth: 1.5))
    }
}
/// Proto.PartLarge: supported ParamRows only; no unsupported plot or inner card.
struct TNFEditorPartCard: View {
    @ObservedObject var commands: TNFEditorCommands
    let part: LibraryEditPart
    let token: LibraryEditorToken?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(part.settings, id: \.parameter) { setting in TNFEditorSettingRow(commands: commands, part: part, setting: setting, token: token) }
        }
        .contextMenu { Button("Remove \(TNFEditorNames.part(part.type))", role: .destructive) { commands.perform(token: token) { try await commands.command(.removePart(part.id)) } }.disabled(!commands.editing || !commands.canAuthor) }
    }
}
/// Proto.ParamRow/ValueField: real physical commands, no unsupported graph/overlay producers.
struct TNFEditorSettingRow: View {
    @ObservedObject var commands: TNFEditorCommands
    let part: LibraryEditPart
    let setting: LibraryEditSetting
    let token: LibraryEditorToken?
    @TNFViewState private var typing = false
    @TNFViewState private var typed = ""
    var body: some View {
        HStack(spacing: TNFEditorCols.gap) {
            Text(TNFEditorNames.parameter(setting.parameter)).font(.system(size: 13)).foregroundStyle(reached ? Color.tnfPortOrange : Color.primary).frame(width: TNFEditorCols.name, alignment: .leading).lineLimit(1)
            TNFEditorTrack(value: (try? setting.specification.normalized(setting.physicalValue)) ?? setting.base,
                           label: TNFEditorNames.parameter(setting.parameter), spoken: readout,
                           locked: !commands.editing || !commands.canAuthor, onBegin: { do { try commands.beginPhysicalGesture(part: part.id, parameter: setting.parameter) } catch { commands.fail(error) } }, onEnd: endPhysical) { normalized in
                do {
                    try commands.validateCallback(token)
                    let value = try setting.specification.physical(normalized)
                    let receipt = try commands.admitPhysical(part: part.id, parameter: setting.parameter, value: setting.specification.discrete ? value.rounded() : value)
                    commands.perform(token: token) { try await commands.consume(receipt) }
                } catch { commands.fail(error) }
            }.frame(minWidth: TNFEditorCols.trackMin, maxWidth: TNFEditorCols.trackMax)
            Group {
                if typing {
                    TextField("", text: $typed).textFieldStyle(.roundedBorder).font(.system(size: 12).monospacedDigit())
                        .onSubmit {
                            guard let value = Double(typed) else { commands.fail(LibraryError.unsupportedEdit); return }
                            commands.perform(token: token) { try await commands.command(.setPhysical(part: part.id, parameter: setting.parameter, value: value)) }; typing = false
                        }.onExitCommand { typing = false }
                } else {
                    Text(readout).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .onTapGesture { if commands.editing && commands.canAuthor { typed = TNFEditorNames.value(setting.physicalValue, key: setting.parameter); typing = true } }.help("Type a value")
                }
            }.frame(width: 64, alignment: .leading)
            HStack(spacing: 3) {
                if commands.editing { ForEach(setting.sourceControls, id: \.self) { id in Circle().fill(commands.settingIsReached(sourceControls: [id], path: []) ? Color.tnfPortOrange : Color.tnfPortOrange.opacity(0.45)).frame(width: 7, height: 7).help("Moved by \(commands.controlNames[id] ?? "Control")") } }
            }.frame(width: TNFEditorCols.trail, alignment: .leading)
            Spacer(minLength: 0)
        }.padding(.vertical, 4).padding(.horizontal, 8)
            .contextMenu {
                ForEach(commands.projection?.mappings.descriptors.filter { $0.address.path.isEmpty && $0.presentation?.face != .xy } ?? [], id: \.address) { source in
                    Button("Map \(source.presentation?.title ?? "Control") to This") { commands.perform(token: token) { try await commands.connect(source: source, target: .setting(part: part.id, parameter: setting.parameter)) } }.disabled(!commands.editing || !commands.canAuthor)
                }
                Button("Show at the Top") { commands.perform(token: token) { try await commands.command(.showAtTop(part: part.id, parameter: setting.parameter, title: TNFEditorNames.parameter(setting.parameter))) } }.disabled(!commands.editing || !commands.canAuthor)
                Button("Type a Value") { typed = TNFEditorNames.value(setting.physicalValue, key: setting.parameter); typing = true }.disabled(!commands.editing || !commands.canAuthor)
            }
    }
    private var reached: Bool { commands.settingIsReached(sourceControls: setting.sourceControls, path: []) }
    private var readout: String { TNFEditorNames.value(setting.physicalValue, key: setting.parameter) + (setting.unit.isEmpty ? "" : " " + setting.unit) }
    private func endPhysical() { do { try commands.validateCallback(token); let receipt = try commands.admitEndPhysicalGesture(); commands.perform(token: token) { try await commands.consume(receipt) } } catch { commands.fail(error) } }
}

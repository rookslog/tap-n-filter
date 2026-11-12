import AppKit
import SoundModel
import SwiftUI

enum MenuHeadMetrics {
    static let verticalPadding: CGFloat = 10
    static let capsuleHeight: CGFloat = 28
    static let earWidth: CGFloat = 34
    static let dividerWidth: CGFloat = 1
    static let switchWidth: CGFloat = 54
    static let trailingInset: CGFloat = 14
    static let switchInset: CGFloat = 6
    static let capsuleWidth = earWidth + dividerWidth + switchWidth
    static let totalHeight = capsuleHeight + verticalPadding * 2
}

struct MenuHead: View {
    @ObservedObject var state: MenuPresentation
    let compare: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            MenuVisualization(state: state.visualization,
                tint: state.snapshot.assignments.first { $0.isEnabled && $0.bundleIdentifier == "com.apple.Safari" }?.block.tint ?? .accentColor,
                comparing: state.comparing)
            capsule
        }.padding(.horizontal, MenuHeadMetrics.trailingInset)
            .frame(height: MenuHeadMetrics.totalHeight)
            .onChange(of: state.interactionEpoch) { _, _ in state.headHovered = false }
            .onChange(of: state.compareAvailable) { _, available in
                if !available { state.headHovered = false }
            }
    }

    @ViewBuilder private var capsule: some View {
        if #available(macOS 26.0, *) {
            controls.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            controls.background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            ZStack {
                if state.compareAvailable {
                    if state.comparing {
                        Circle().fill(Color.accentColor).frame(width: 23, height: 23)
                        Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                            .frame(width: 27, height: 27)
                    } else if state.headHovered {
                        Circle().fill(Color.primary.opacity(0.08)).frame(width: 23, height: 23)
                    }
                }
                CompareButton(available: state.compareAvailable, comparing: state.comparing,
                              cancelEpoch: state.interactionEpoch, change: compare, capsuleStyle: true)
                    .frame(width: 26, height: 26)
            }.frame(width: MenuHeadMetrics.earWidth, height: MenuHeadMetrics.capsuleHeight)
                .onHover { state.headHovered = $0 && state.compareAvailable }
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: MenuHeadMetrics.dividerWidth, height: 14)
            Toggle("All apps", isOn: Binding(get: { state.snapshot.isEnabled }, set: { state.perform(.setEnabled($0)) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel("All apps")
                .background(MenuAnchor("power")).fixedSize()
                .padding(.trailing, MenuHeadMetrics.switchInset)
                .frame(width: MenuHeadMetrics.switchWidth, height: MenuHeadMetrics.capsuleHeight, alignment: .trailing)
        }.frame(width: MenuHeadMetrics.capsuleWidth, height: MenuHeadMetrics.capsuleHeight)
    }
}

struct MenuCardHeader: View {
    @ObservedObject var state: MenuPresentation
    let id: UUID

    var body: some View {
        if let assignment = state.snapshot.assignments.first(where: { $0.id == id }),
           let definition = state.definition(assignment) {
            let source = state.source(assignment.bundleIdentifier)
            let on = assignment.isEnabled
            VStack(spacing: 0) {
              HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let icon = source.icon { Image(nsImage: icon).resizable() }
                        else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
                    }.frame(width: 30, height: 30).saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)
                    MenuBlockMark(decoration: assignment.block, size: 8)
                        .foregroundStyle(.white).frame(width: 15, height: 15)
                        .background(assignment.block.tint, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.background, lineWidth: 1.5))
                        .saturation(on ? 1 : 0).offset(x: 4.8, y: 3.6)
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Button { state.toggleChooser(id) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium))
                                .rotationEffect(.degrees(state.interaction.choosing == id ? 180 : 0))
                            Text(definition.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(.primary).padding(.horizontal, 3)
                            .background(state.interaction.hoveredPill == id || (state.highlighted == id && state.keyboardInput) || state.interaction.choosing == id
                                        ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 4))
                            .contentShape(RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).onHover { inside in
                        if inside { state.interaction.hoveredPill = id }
                        else if state.interaction.hoveredPill == id { state.interaction.hoveredPill = nil }
                    }
                        .help(assignment.nameHelp ?? "Choose block")
                        .accessibilityLabel("Choose block for \(source.name)")
                        .background(MenuAnchor("block-\(id)"))
                }
                Spacer(minLength: 4)
                Toggle(source.name, isOn: Binding(get: { on }, set: { if let binding = assignment.binding { state.perform(.libraryPower(binding, $0)) }
                        else { state.perform(.setAppEnabled(id, $0)) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel(source.name)
                    .background(MenuAnchor("switch-\(id)"))
              }.frame(height: 30)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, on ? 8 : 10)
              if state.interaction.choosing == id {
                  MenuBlockChooser(state: state, assignment: assignment)
              }
            }
            .frame(height: MenuCardMetrics.headerHeight(enabled: on,
                choosing: state.interaction.choosing == id, blockCount: assignment.choices.count), alignment: .top)
            .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: on ? 0 : 14,
                bottomTrailingRadius: on ? 0 : 14, topTrailingRadius: 14)
                .fill(assignment.block.tint.opacity(on ? 0.12 : 0.04)))
            .overlay {
                if on { CardSliceChrome(top: true).stroke(assignment.block.tint.opacity(0.3), lineWidth: 1) }
                else { RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(assignment.block.tint.opacity(0.1), lineWidth: 1) }
            }.padding(.horizontal, 10)
        }
    }
}

private struct MenuBlockChooser: View {
    @ObservedObject var state: MenuPresentation
    let assignment: MenuSoundCard

    var body: some View {
        VStack(spacing: 0) {
            ForEach(assignment.choices, id: \.id) { block in
                MenuBlockChoiceRow(state: state, choiceID: block.id, title: block.title, block: block.decoration,
                    selected: block.id == assignment.definitionID) {
                    state.chooseBlock(block.id, on: assignment.id)
                }
            }
            Divider().frame(height: MenuCardMetrics.chooserDivider)
            MenuBlockChoiceRow(state: state, choiceID: nil, title: "None", block: nil, selected: false) {
                state.chooseBlock(nil, on: assignment.id)
            }
        }.padding(.vertical, MenuCardMetrics.chooserPadding).padding(.horizontal, 10)
    }
}

private struct MenuBlockChoiceRow: View {
    @ObservedObject var state: MenuPresentation
    let choiceID: UUID?
    let title: String
    let block: MenuDecoration?
    let selected: Bool
    let choose: () -> Void
    private var highlight: MenuChoiceHighlight { choiceID.map(MenuChoiceHighlight.block) ?? .none }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                    .opacity(selected ? 1 : 0).frame(width: 14)
                if let block {
                    MenuBlockMark(decoration: block, size: 9)
                        .foregroundStyle(.white).frame(width: 15, height: 15)
                        .background(block.tint, in: RoundedRectangle(cornerRadius: 4))
                } else { Color.clear.frame(width: 15, height: 15) }
                Text(title).font(.system(size: 13)).foregroundStyle(block == nil ? .secondary : .primary)
                Spacer(minLength: 0)
            }.frame(height: MenuCardMetrics.chooserRow).contentShape(.rect)
                .background(state.interaction.hoveredChoice == highlight ? Color.primary.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).onHover { inside in
            if inside { state.interaction.hoveredChoice = highlight }
            else if state.interaction.hoveredChoice == highlight { state.interaction.hoveredChoice = nil }
        }.accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MenuCardControls: View {
    @ObservedObject var state: MenuPresentation
    let id: UUID

    var body: some View {
        if let assignment = state.snapshot.assignments.first(where: { $0.id == id }), assignment.isEnabled,
           let definition = state.definition(assignment) {
            let primary = definition.controls.filter { $0.placement == .primary }
            let more = definition.controls.filter { $0.placement == .more }
            VStack(alignment: .leading, spacing: 8) {
                MenuLiveStrip(frame: state.levels[id], tint: assignment.block.tint,
                              heard: state.snapshot.isEnabled && !state.comparing).frame(height: 28)
                ForEach(primary, id: \.id) { control in
                    controlRows(control, assignment: assignment, definition: definition)
                }
                if !more.isEmpty {
                    Button { state.toggleMore(id) } label: {
                        HStack(spacing: 4) {
                            Text("More").font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(state.more.contains(id) ? 180 : 0))
                            Spacer()
                        }.foregroundStyle(.secondary).contentShape(.rect).frame(height: 14)
                    }.buttonStyle(.plain).accessibilityLabel(state.more.contains(id) ? "Fewer controls" : "More controls")
                        .background(MenuAnchor("more-\(id)"))
                    if state.more.contains(id) {
                        ForEach(more, id: \.id) { control in
                            controlRows(control, assignment: assignment, definition: definition)
                        }
                    }
                }
                if !assignment.heldHelp.isEmpty {
                    MenuHeldLine(names: assignment.heldNames, explanations: assignment.heldHelp)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14)
                .fill(assignment.block.tint.opacity(0.12)))
            .overlay(CardSliceChrome(top: false).stroke(assignment.block.tint.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 10)
        }
    }
    @ViewBuilder private func controlRows(_ control: MenuSoundControl, assignment: MenuSoundCard, definition: MenuSoundCard) -> some View {
        VStack(spacing: 8) {
            MenuControlRow(state: state, assignment: assignment, control: control,
                reserveSymbol: definition.controls.contains { controlSymbol($0.id) != nil } || !assignment.heldHelp.isEmpty)
            if let tab = assignment.optionTabs.first(where: { $0.parent == control.address }), state.tabIsOpen(tab, on: assignment) {
                MenuOptionTab(state: state, assignment: assignment, tab: tab)
                    .id(tab.parent)
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct MenuLiveStrip: View {
    let frame: MenuLevelFrame?
    let tint: Color
    let heard: Bool

    var body: some View {
        Canvas { context, size in
            guard let frame else {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(baseline, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                return
            }
            let count = min(frame.before.count, frame.after.count)
            guard count > 0 else { return }
            for i in 0..<count {
                let x = Double(i) * size.width / Double(count)
                for (value, color, width) in [(frame.before[i], Color.secondary.opacity(0.3), 2.0),
                    (heard ? frame.after[i] : frame.before[i], tint.opacity(heard ? 0.85 : 0.3), 2.0)] {
                    let height = max(1, value * size.height)
                    context.fill(Path(roundedRect: CGRect(x: x, y: (size.height - height) / 2,
                        width: width, height: height), cornerRadius: 1), with: .color(color))
                }
            }
        }.accessibilityLabel(frame == nil ? "Levels unavailable" : "Before and after levels")
    }
}

private struct CardSliceChrome: Shape {
    let top: Bool
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 14
        var path = Path()
        if top {
            path.move(to: CGPoint(x: 0, y: rect.maxY)); path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: .zero); path.addLine(to: CGPoint(x: 0, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: radius, y: rect.maxY), control: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                               control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        }
        return path
    }
}

private struct MenuBlockMark: View {
    let decoration: MenuDecoration
    let size: CGFloat
    var body: some View {
        switch decoration {
        case .builtin(let block): Image(systemName: block.symbol).font(.system(size: size, weight: .semibold))
        case .custom(let monogram): Text(monogram).font(.system(size: 8.5, weight: .semibold))
        }
    }
}
private struct MenuHeldLine: View {
    let names: [String]
    let explanations: [String]
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed").font(.system(size: 11)).frame(width: 16)
            Text(names.joined(separator: " · ")).font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }.foregroundStyle(.secondary).frame(height: 14)
            .help(help).accessibilityElement(children: .ignore).accessibilityLabel(help)
    }
    private var help: String { "Kept with this sound; not adjustable in the menu: " + explanations.joined(separator: " · ") }
}

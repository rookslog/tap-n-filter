import AppKit
import SoundModel
import SwiftUI

/// Edit.CurveLanes: lane labels/axes share the real source control's track.
struct TNFEditorCurveLanes: View {
    @ObservedObject var commands: TNFEditorCommands
    let bindings: [LibraryMappingSummary]
    let token: LibraryEditorToken?
    let width: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bindings, id: \.id) { binding in
                TNFEditorLaneRow(commands: commands, binding: binding, token: token, width: width)
            }
            if let first = bindings.first {
                let places = commands.sourceLabelPlaces(first)
                let shown = Self.fitting(places, width: width)
                HStack(spacing: TNFEditorCols.gap) {
                    Color.clear.frame(width: TNFEditorLayout.trackX - 8 - 12, height: 1)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(places.enumerated()), id: \.offset) { i, p in
                            if shown.contains(i) {
                                Text(p.0).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                                    .alignmentGuide(.leading) { d in d.width * p.1 - width * p.1 }
                            }
                        }
                    }.frame(width: width, height: 14, alignment: .topLeading)
                }
            }
        }.padding(.horizontal, 8).padding(.top, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
    static func fitting(_ names: [(String, Double)], width: CGFloat) -> Set<Int> {
        let span: [(CGFloat, CGFloat)] = names.map { n, pos in
            let tw = CGFloat(n.count) * 5.4 + 2, x = width * pos - tw * pos
            return (x, x + tw)
        }
        let byPos = names.indices.sorted { names[$0].1 < names[$1].1 }
        let order = byPos.count > 1 ? [byPos.first!, byPos.last!] + byPos.dropFirst().dropLast() : byPos
        var kept: [Int] = []
        for i in order where !kept.contains(where: { span[$0].0 < span[i].1 + 8 && span[i].0 < span[$0].1 + 8 }) { kept.append(i) }
        return Set(kept)
    }
}
struct TNFEditorLaneRow: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryMappingSummary
    let token: LibraryEditorToken?
    var width: CGFloat = 300
    @TNFViewState private var selectedStretch: Int?
    var option: UUID? { commands.selectedOption(binding) }
    var lane: LibraryMappingLane? { option.flatMap { binding.cases[$0] } ?? binding.lane }
    var sourceValues: [UUID: Double] { option.flatMap { binding.caseSourceValues[$0] } ?? binding.sourceValues }
    var body: some View {
        HStack(alignment: .top, spacing: TNFEditorCols.gap) {
            ZStack {
                HStack(spacing: 6) {
                    if case .setting(let id, _) = binding.target, let part = commands.edit?.parts.first(where: { $0.id == id }) {
                        TNFEditorTile(tint: .tnfPortGrey, symbol: TNFEditorNames.symbol(part.type), size: 16)
                    }
                    Text(commands.laneName(binding)).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(commands.targetBound(binding, upper: true)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(commands.targetBound(binding, upper: false)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }.frame(width: TNFEditorLayout.trackX - 8 - 12, height: 64)
            Group {
                if let lane {
                    TNFEditorCurveEditor(commands: commands, binding: binding, token: token, option: option, lane: lane, selectedStretch: $selectedStretch, width: width)
                } else if !sourceValues.isEmpty {
                    choiceValues
                }
            }.frame(width: width)
        }.contextMenu {
            Button("Set Here") { commands.perform(token: token) { try await commands.setByEar(binding, option: option, at: commands.sourcePosition(binding), value: commands.targetValue(binding)) } }.disabled(!commands.editing || !commands.canAuthor || lane == nil)
            Button("Remove Mapping", role: .destructive) { commands.perform(token: token) { try await commands.mapping(.removeBinding(binding.id), path: binding.path) } }.disabled(!commands.editing || !commands.canAuthor)
        }
    }
    /// Choice86.ChoiceSteps: separate OptionID landings, not an invented continuous source.
    private var choiceValues: some View {
        let options = commands.sourceOptions(binding)
        let needed = CGFloat(options.count) * (CGFloat(options.map { $0.title.count }.max() ?? 0) * 5.4 + 16)
        let w = max(width, needed), column = w / CGFloat(max(1, options.count))
        let space = "steps-\(binding.id)-\(option?.uuidString ?? "all")"
        return ScrollView(.horizontal) {
            VStack(spacing: 4) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.tnfPortOrange.opacity(0.06))
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, source in
                        Rectangle().fill(Color.accentColor.opacity(abs(commands.sourcePosition(binding) - source.position) < 1e-9 ? 0.12 : 0))
                            .frame(width: column, height: 64).offset(x: CGFloat(index) * column)
                        Capsule().fill(Color.tnfPortOrange).frame(width: max(4, column - 20), height: 3)
                            .frame(width: column, height: 22).contentShape(.rect)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(space)).onChanged { drag in
                                guard commands.editing, commands.canAuthor else { return }
                                do {
                                    try commands.validateCallback(token)
                                    if !commands.positionGestureActive { try commands.beginResponseGesture(binding) }
                                    let receipt = try commands.admitResponse(binding, command: .sourceValue(binding: binding.id, selectorOption: option, sourceOption: source.id, value: min(1, max(0, 1 - drag.location.y / 64))))
                                    commands.perform(token: token) { try await commands.consume(receipt) }
                                } catch { commands.fail(error) }
                            }.onEnded { _ in
                                do { let receipt = try commands.admitEndResponseGesture(binding); commands.perform(token: token) { try await commands.consume(receipt) } } catch { commands.fail(error) }
                            })
                            .position(x: (CGFloat(index) + 0.5) * column, y: 64 * (1 - (sourceValues[source.id] ?? 0)))
                            .accessibilityLabel(source.title)
                    }
                }.frame(width: w, height: 64).coordinateSpace(name: space)
                HStack(spacing: 0) { ForEach(options, id: \.id) { source in Text(source.title).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: column) } }
            }.frame(width: w).padding(.vertical, 8)
        }.scrollIndicators(.automatic).frame(width: width)
    }

}

/// Edit.CurveEditor: source drawing expressions; authoritative lane evaluator replaces prototype shapedValue.
struct TNFEditorCurveEditor: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryMappingSummary
    let token: LibraryEditorToken?
    let option: UUID?
    let lane: LibraryMappingLane
    @Binding var selectedStretch: Int?
    var width: CGFloat
    @TNFViewState private var selectedPoint: Double?
    @TNFViewState private var optionHeld = false
    @TNFViewState private var hoveredPoint: Double?
    @TNFViewState private var draggedPoint: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let axis = TNFEditorAxis(origin: 0, width: Double(w))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.tnfPortOrange.opacity(0.06))
                    ForEach(binding.sourceWaypoints, id: \.self) { point in
                        Path { q in q.move(to: CGPoint(x: axis.x(point), y: 0)); q.addLine(to: CGPoint(x: axis.x(point), y: h)) }
                            .stroke(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    if let s = selectedStretch, lane.points.indices.contains(s), s + 1 < lane.points.count {
                        Rectangle().fill(Color.tnfPortOrange.opacity(0.1))
                            .frame(width: w * (lane.points[s + 1].position - lane.points[s].position), height: h).offset(x: w * lane.points[s].position)
                    }
                    Path { path in
                        for i in 0...120 {
                            let u = Double(i) / 120
                            let pt = CGPoint(x: axis.x(u), y: h * (1 - ((try? lane.value(at: u)) ?? 0)))
                            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                        }
                    }.stroke(Color.tnfPortOrange, lineWidth: 2)
                    Path { path in let x = commands.sourcePosition(binding); path.move(to: CGPoint(x: axis.x(x), y: 0)); path.addLine(to: CGPoint(x: axis.x(x), y: h)) }.stroke(.secondary.opacity(0.5), lineWidth: 1)
                    Color.clear.contentShape(.rect).onTapGesture { loc in
                        let u = min(1, max(0, loc.x / w))
                        if abs(h * (1 - ((try? lane.value(at: u)) ?? 0)) - loc.y) < 10, commands.editing {
                            let snapped = binding.sourceWaypoints.first { abs($0 - u) < 0.03 } ?? u
                            commands.perform(token: token) { try await commands.mapping(.insertPoint(binding: binding.id, option: option, position: snapped), path: binding.path) }
                            selectedPoint = snapped
                        } else { selectedStretch = min(max(0, lane.points.count - 2), lane.points.lastIndex { $0.position <= u } ?? 0); selectedPoint = nil }
                    }
                    ForEach(Array(lane.points.enumerated()), id: \.element.position) { index, point in
                        if commands.editing && (hoveredPoint == point.position || draggedPoint == point.position) {
                            if !optionHeld {
                                Path { p in p.move(to: CGPoint(x: axis.x(point.position), y: 0)); p.addLine(to: CGPoint(x: axis.x(point.position), y: h)) }
                                    .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).allowsHitTesting(false)
                            }
                            Image(systemName: optionHeld ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.up.and.down")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(Color.accentColor)
                                .position(x: axis.x(point.position) + (point.position > 0.9 ? -14 : 14), y: h * (1 - point.value) - 12).allowsHitTesting(false)
                        }
                        TNFEditorPointHandle(commands: commands, binding: binding, token: token, option: option, lane: lane, index: index, w: w, h: h, optionHeld: optionHeld, picked: $selectedPoint, hovered: $hoveredPoint, dragged: $draggedPoint)
                            .position(x: axis.x(point.position), y: h * (1 - point.value))
                    }
                }
            }.frame(height: 64).coordinateSpace(name: coordinate)
                .modifier(TNFEditorOptionModifier(held: $optionHeld))
                .focusable().onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in nudge(press) }
            if commands.editing, let s = selectedStretch, let stretches = try? lane.stretches(), stretches.indices.contains(s) {
                TNFEditorShapeBar(commands: commands, binding: binding, token: token, option: option, lane: lane, selected: s, stretch: stretches[s], width: width)
            }
        }
    }
    private var coordinate: String { "curve-\(binding.id)-\(option?.uuidString ?? "all")" }
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard commands.editing, let p = lane.points.first(where: { $0.position == selectedPoint }) else { return .ignored }
        let step = press.modifiers.contains(.shift) ? 0.1 : press.modifiers.contains(.option) ? 0.002 : 0.01
        var x = p.position, y = p.value
        switch press.key {
        case .upArrow: y = min(1, y + step)
        case .downArrow: y = max(0, y - step)
        case .leftArrow, .rightArrow:
            if !press.modifiers.contains(.option) {
                guard let index = lane.points.firstIndex(where: { $0.position == p.position }) else { return .ignored }
                let next = index + (press.key == .leftArrow ? -1 : 1)
                guard lane.points.indices.contains(next) else { return .ignored }
                selectedPoint = lane.points[next].position; return .handled
            }
            guard p.position > 0, p.position < 1 else { return .ignored }
            x = min(1, max(0, x + (press.key == .leftArrow ? -step : step)))
        default: return .ignored
        }
        commands.perform(token: token) { try await commands.releasePoint(commands.laneIdentity(binding, option: option), lane: lane, waypoints: binding.sourceWaypoints, from: p.position, to: x, value: y) }
        return .handled
    }
}

/// Edit.PointHandle, with the binding H01 point-release contract: pointer previews stay local.
struct TNFEditorPointHandle: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryMappingSummary
    let token: LibraryEditorToken?
    let option: UUID?
    let lane: LibraryMappingLane
    let index: Int
    let w: Double
    let h: Double
    let optionHeld: Bool
    @Binding var picked: Double?
    @TNFViewState private var drag: (Double, Double)?
    @TNFViewState private var identity: TNFEditorLaneIdentity?
    @Binding var hovered: Double?
    @Binding var dragged: Double?
    var point: LibraryLanePoint { lane.points[index] }
    var body: some View {
        Circle().fill(picked == point.position ? Color.tnfPortOrange : .white).overlay(Circle().strokeBorder(Color.tnfPortOrange, lineWidth: 2.5))
            .frame(width: 14, height: 14).contentShape(Circle().inset(by: -6))
            .offset(x: (drag.map { $0.0 - point.position } ?? 0) * w, y: -(drag.map { $0.1 - point.value } ?? 0) * h)
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                guard commands.editing, commands.canAuthor, commands.adapter.token == token else { return }
                if drag == nil { identity = try? commands.laneIdentity(binding, option: option); picked = point.position; dragged = point.position }
                var u = point.position
                let freeform = TNFEditorOptionInput.drag(eventFlags: NSApp?.currentEvent?.modifierFlags, observed: optionHeld)
                if freeform, index > 0, index + 1 < lane.points.count {
                    u = min(1, max(0, point.position + value.translation.width / w))
                    if let snap = binding.sourceWaypoints.first(where: { abs($0 - u) < 0.025 }) { u = snap }
                }
                drag = (u, min(1, max(0, point.value - value.translation.height / h)))
            }.onEnded { value in
                guard let destination = drag, let identity else { return }
                drag = nil; self.identity = nil; dragged = nil
                commands.perform(token: token) {
                    if abs(value.translation.height) > 70, lane.points.count > 2, index > 0, index + 1 < lane.points.count { try await commands.removePoint(identity, lane: lane, position: point.position) }
                    else { try await commands.releasePoint(identity, lane: lane, waypoints: binding.sourceWaypoints, from: point.position, to: destination.0, value: destination.1) }
                }
            })
            .onHover { inside in hovered = inside ? point.position : (hovered == point.position ? nil : hovered) }.onTapGesture { picked = point.position }
            .accessibilityLabel("Point \(index + 1)").accessibilityValue("\(Int(point.value * 100)) percent")
            .contextMenu {
                Button("Set Here") { commands.perform(token: token) { try await commands.mapping(.point(binding: binding.id, option: option, position: point.position, value: commands.targetValue(binding)), path: binding.path) } }.disabled(!commands.editing || !commands.canAuthor)
                Button("Remove Point", role: .destructive) { commands.perform(token: token) { try await commands.removePoint(commands.laneIdentity(binding, option: option), lane: lane, position: point.position) } }.disabled(!commands.editing || !commands.canAuthor || lane.points.count <= 2 || index == 0 || index == lane.points.count - 1)
            }
    }
}
struct TNFEditorShapeBar: View {
    @ObservedObject var commands: TNFEditorCommands
    let binding: LibraryMappingSummary
    let token: LibraryEditorToken?
    let option: UUID?
    let lane: LibraryMappingLane
    let selected: Int
    let stretch: LibraryLaneStretch
    let width: CGFloat
    var body: some View {
        VStack(spacing: 4) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: TNFEditorShapeLayout.width, maximum: TNFEditorShapeLayout.width), spacing: TNFEditorShapeLayout.gap)], alignment: .leading, spacing: TNFEditorShapeLayout.gap) {
                ForEach([LibraryStretch.curve, .straight, .ease, .step], id: \.rawValue) { shape in
                    Button { commands.perform(token: token) { try await commands.mapping(.stretch(binding: binding.id, option: option, index: selected, shape: shape, jump: stretch.jump), path: binding.path) } } label: {
                        TNFEditorShapeIcon(shape: shape).frame(width: 20, height: 15).padding(.horizontal, 6).padding(.vertical, 4)
                            .background(stretch.kind == shape ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).contentShape(.rect)
                    }.buttonStyle(.plain).help(shape.rawValue.capitalized).accessibilityLabel(shape.rawValue.capitalized)
                }
            }.frame(maxWidth: TNFEditorShapeLayout.fullWidth, alignment: .leading)
                .padding(3).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous)).foregroundStyle(Color.tnfPortOrange)
            if stretch.kind == .step {
                Slider(value: Binding(get: { stretch.jump }, set: { value in
                    do { try commands.validateCallback(token); let receipt = try commands.admitResponse(binding, command: .stretch(binding: binding.id, option: option, index: selected, shape: .step, jump: value)); commands.perform(token: token) { try await commands.consume(receipt) } } catch { commands.fail(error) }
                }), in: 0...1, onEditingChanged: { began in
                    do { if began { try commands.beginResponseGesture(binding) } else { let receipt = try commands.admitEndResponseGesture(binding); commands.perform(token: token) { try await commands.consume(receipt) } } } catch { commands.fail(error) }
                }).accessibilityLabel("Step Jump")
            }
        }.frame(maxWidth: TNFEditorShapeLayout.fullWidth + 6, alignment: .leading)
            .padding(.leading, TNFEditorShapeLayout.lead(pts: lane.points, picked: selected, width: width))
            .disabled(!commands.canAuthor)
    }
}
enum TNFEditorShapeLayout {
    static let width: CGFloat = 32
    static let gap: CGFloat = 4
    static var fullWidth: CGFloat { 4 * width + 3 * gap }
    static func lead(pts: [LibraryLanePoint], picked: Int, width: CGFloat) -> CGFloat {
        guard width > 0, pts.indices.contains(picked) else { return 0 }
        let end = picked + 1 < pts.count ? pts[picked + 1].position : 1
        let bar = min(fullWidth + 6, width)
        return max(0, min(width - bar, width * (pts[picked].position + end) / 2 - bar / 2))
    }
}
/// Kit.StretchShape.glyph: same 20-sample picture, with only the four admitted kinds.
struct TNFEditorShapeIcon: View {
    let shape: LibraryStretch
    var body: some View {
        Path { p in
            for i in 0...20 {
                let u = Double(i) / 20
                let v: Double
                switch shape { case .curve, .straight: v = u; case .ease: v = u * u * (3 - 2 * u); case .step: v = u < 0.5 ? 0 : 1 }
                let pt = CGPoint(x: 2 + u * 16, y: 13 - v * 10)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }.stroke(Color.tnfPortOrange, lineWidth: 2)
    }
}

/// The original observer is macOS15+. The fallback observes only this editor's key window.
private struct TNFEditorOptionModifier: ViewModifier {
    @Binding var held: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onModifierKeysChanged(mask: .option) { _, now in held = now.contains(.option) }
        } else {
            content.background(TNFEditorOptionFlags(held: $held))
        }
    }
}

private enum TNFEditorOptionInput {
    static func drag(eventFlags: NSEvent.ModifierFlags?, observed: Bool) -> Bool {
        eventFlags.map { $0.contains(.option) } ?? observed
    }
    static func observation(flags: NSEvent.ModifierFlags, ownsKeyWindow: Bool) -> Bool {
        ownsKeyWindow && flags.contains(.option)
    }
}

private struct TNFEditorOptionFlags: NSViewRepresentable {
    @Binding var held: Bool
    func makeNSView(context: Context) -> TNFEditorOptionFlagsView {
        let view = TNFEditorOptionFlagsView()
        view.changed = { held = $0 }
        return view
    }
    func updateNSView(_ view: TNFEditorOptionFlagsView, context: Context) { view.changed = { held = $0 } }
    static func dismantleNSView(_ view: TNFEditorOptionFlagsView, coordinator: ()) { view.stop() }
}

private final class TNFEditorOptionFlagsView: NSView {
    var changed: (Bool) -> Void = { _ in }
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stop()
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        changed(TNFEditorOptionInput.observation(flags: NSEvent.modifierFlags, ownsKeyWindow: window.isKeyWindow))
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            self.changed(TNFEditorOptionInput.observation(flags: event.modifierFlags, ownsKeyWindow: true))
            return event
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self, let window = self.window else { return }
                self.changed(TNFEditorOptionInput.observation(flags: NSEvent.modifierFlags, ownsKeyWindow: window.isKeyWindow))
            })
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for token in notifications { NotificationCenter.default.removeObserver(token) }
        notifications.removeAll()
        changed(false)
    }
}

import AppKit
import SwiftUI

struct MenuChoiceControl: NSViewRepresentable {
    let options: [MenuSoundOption]
    let selected: UUID?
    let hints: [UUID: String]
    let activate: (MenuSoundOption) -> Void

    func makeNSView(context: Context) -> MenuSegmentedControl { MenuSegmentedControl() }

    func updateNSView(_ view: MenuSegmentedControl, context: Context) {
        view.configure(options: options, selected: selected, hints: hints, activate: activate)
    }
}

final class MenuSegmentedControl: NSSegmentedControl {
    private var confirmedSegment = -1
    private var activation = MenuChoiceAction()
    private var configuration = MenuChoiceConfiguration()
    private var resources: [UUID: (content: MenuChoiceConfiguration.Content, image: NSImage?, element: MenuAccessibleSegment)] = [:]
    private var segments: [MenuAccessibleSegment] = []

    init() {
        super.init(frame: .zero)
        cell = MenuSegmentedCell()
        trackingMode = .selectOne
        segmentStyle = .automatic
        segmentDistribution = .fillEqually
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        target = self
        action = #selector(segmentActivated)
    }

    required init?(coder: NSCoder) { nil }

    func configure(options: [MenuSoundOption], selected: UUID?, hints: [UUID: String],
                   activate: @escaping (MenuSoundOption) -> Void) {
        activation.update(options, callback: activate)
        let changes = configuration.update(options, hints: hints)
        if changes.count { segmentCount = options.count }
        for (index, content) in configuration.content.enumerated() {
            let cached = resources[content.id]
            let element = cached?.element ?? MenuAccessibleSegment(owner: self, index: index, title: content.title, hint: hints[content.id])
            element.index = index
            if cached?.content.title != content.title { element.setAccessibilityLabel(content.title) }
            if changes.hints.contains(content.id) { element.setAccessibilityHelp(hints[content.id]) }
            let image: NSImage?
            if cached?.content == content { image = cached?.image }
            else { image = content.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: content.title) } }
            resources[content.id] = (content, image, element)
            if changes.content.contains(index) {
                if width(forSegment: index) != 0 { setWidth(0, forSegment: index) }
                if self.image(forSegment: index) !== image { setImage(image, forSegment: index) }
                let label = image == nil ? content.title : ""
                if self.label(forSegment: index) != label { setLabel(label, forSegment: index) }
                let tooltip = image == nil ? nil : content.title
                if toolTip(forSegment: index) != tooltip { setToolTip(tooltip, forSegment: index) }
            }
        }
        if changes.order {
            segments = options.compactMap { resources[$0.id]?.element }
            let ids = Set(options.map(\.id))
            for (id, resource) in resources where !ids.contains(id) { resource.element.owner = nil }
            resources = resources.filter { ids.contains($0.key) }
        }
        confirmedSegment = options.firstIndex { $0.id == selected } ?? -1
        if selectedSegment != confirmedSegment { selectedSegment = confirmedSegment }
    }

    @objc private func segmentActivated() { activateSegment(selectedSegment) }

    func activateSegment(_ index: Int) {
        guard isEnabled, activation.options.indices.contains(index), isEnabled(forSegment: index) else { return }
        if selectedSegment != confirmedSegment { selectedSegment = confirmedSegment }
        activation.activate(index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: activateSegment(confirmedSegment)
        case 123, 124:
            let step = event.keyCode == 124 ? 1 : -1
            let index = min(segmentCount - 1, max(0, confirmedSegment + step))
            if index != confirmedSegment { activateSegment(index) }
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityChildren() -> [Any]? { segments }

    fileprivate func segmentFrame(_ index: Int) -> NSRect {
        guard segmentCount > 0, let window else { return .zero }
        let width = bounds.width / CGFloat(segmentCount)
        let rect = NSRect(x: width * CGFloat(index), y: bounds.minY, width: width, height: bounds.height)
        return window.convertToScreen(convert(rect, to: nil))
    }
}

private final class MenuSegmentedCell: NSSegmentedCell {
    override func drawSegment(_ segment: Int, inFrame frame: NSRect, with controlView: NSView) {
        let offset: CGFloat = image(forSegment: segment) == nil ? 0 : (controlView.isFlipped ? -2 : 2)
        super.drawSegment(segment, inFrame: frame.offsetBy(dx: 0, dy: offset), with: controlView)
    }
}

private final class MenuAccessibleSegment: NSAccessibilityElement {
    weak var owner: MenuSegmentedControl?
    var index: Int

    init(owner: MenuSegmentedControl, index: Int, title: String, hint: String?) {
        self.owner = owner
        self.index = index
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint)
    }

    override func accessibilityFrame() -> NSRect { owner?.segmentFrame(index) ?? .zero }
    override func accessibilityValue() -> Any? { NSNumber(value: owner?.selectedSegment == index) }
    override func isAccessibilityEnabled() -> Bool { owner?.isEnabled == true }
    override func accessibilityPerformPress() -> Bool {
        guard let owner, owner.isEnabled else { return false }
        owner.activateSegment(index)
        return true
    }
}

struct MenuChoiceMarks: View {
    let options: [MenuSoundOption]
    let children: [UUID: [String]]
    let selected: UUID?
    let open: Bool
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if children[option.id]?.isEmpty == false {
                    let isOpen = option.id == selected && open
                    MenuChoiceTriangle(down: isOpen)
                        .fill(option.id == selected && !isOpen ? tint : Color.secondary.opacity(0.75))
                        .frame(width: 9, height: 4.5)
                        .position(x: geometry.size.width * (CGFloat(index) + 0.5) / CGFloat(options.count),
                                  y: isOpen ? 25.75 : 20.5)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct MenuChoiceTriangle: Shape {
    let down: Bool
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: down ? rect.minY : rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: down ? rect.maxY : rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: down ? rect.minY : rect.maxY))
            path.closeSubpath()
        }
    }
}

import AppKit

@MainActor
final class OtherAppMenuRow: NSView {
    private let source: SourceAppInfo
    private let choose: () -> Void
    private var committed = false
    private var pending = false

    init(source: SourceAppInfo, choose: @escaping () -> Void) {
        self.source = source
        self.choose = choose
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(source.name)
    }

    required init?(coder: NSCoder) { nil }

    func update(committed: Bool, pending: Bool) {
        self.committed = committed
        self.pending = pending
        setAccessibilityEnabled(!pending)
        setAccessibilityValue(committed ? "Selected" : "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted == true
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let foreground: NSColor = highlighted ? .selectedMenuItemTextColor : pending ? .secondaryLabelColor : .labelColor
        if committed {
            let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
            mark?.withSymbolConfiguration(.init(paletteColors: [foreground]))?.draw(in: NSRect(x: 8, y: 6, width: 12, height: 12))
        }
        source.icon?.draw(in: NSRect(x: 26, y: 4, width: 16, height: 16),
                          from: .zero, operation: .sourceOver, fraction: pending && !committed ? 0.5 : 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (source.name as NSString).draw(in: NSRect(x: 48, y: 4, width: bounds.width - 58, height: 17),
            withAttributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: foreground, .paragraphStyle: paragraph])
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard !pending else { return false }
        choose()
        return true
    }
}

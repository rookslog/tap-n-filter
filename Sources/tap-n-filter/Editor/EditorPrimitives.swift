import AppKit
import SwiftUI
import SoundModel

typealias TNFViewState<Value> = SwiftUI.State<Value>

enum TNFEditorCols {
    static let gap: CGFloat = 12
    static let name: CGFloat = 96
    static let low: CGFloat = 84
    static let high: CGFloat = 100
    static let value: CGFloat = 64
    static let trail: CGFloat = 28
    static let trackMin: CGFloat = 140   // round 84: shorter, so a tray fits beside the main column
    static let trackMax: CGFloat = 480    // capped, so a slider's ends sit near its name (CL19)
    static var lead: CGFloat { name + gap + low }
    static var after: CGFloat { high + gap + value + gap + trail }
}

struct TNFEditorTile: View {
    var tint: Color
    var symbol: String
    var monogram: String? = nil
    var size: CGFloat = 30
    /// Light colours (yellow, mint) take a dark symbol, so it stays readable.
    var light: Bool {
        guard let c = NSColor(tint).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.68
    }
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
             .overlay {
                Group { if let monogram { Text(monogram) } else { Image(systemName: symbol) } }
                    .font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(light ? Color.black.opacity(0.72) : .white)
            }
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
    }
}

struct TNFEditorGround: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.blur(radius: 110))
            for (c, x, y, r, a) in [(Color.tnfPortIndigo, 0.18, 0.22, 0.34, 0.46), (.tnfPortOrange, 0.82, 0.52, 0.28, 0.36), (.tnfPortBrown, 0.32, 0.92, 0.26, 0.30), (.tnfPortTeal, 0.88, 0.08, 0.22, 0.32)] {
                let rr = r * max(size.width, size.height)
                ctx.fill(Path(ellipseIn: CGRect(x: size.width * x - rr, y: size.height * y - rr, width: rr * 2, height: rr * 2)), with: .color(c.opacity(scheme == .dark ? a * 0.7 : a)))
            }
        }
        .background(scheme == .dark ? Color(tnfPortHex: 0x141418) : Color(tnfPortHex: 0xF6F5F8))
        .ignoresSafeArea()
    }
}

struct TNFEditorTrack: View {
    var value: Double
    var band: ClosedRange<Double>? = nil
    var bandColor: Color = .tnfPortOrange
    /// The band end the armed place controls: it glows while setting is armed (D2).
    var mark: Double? = nil
    var dim = false
    var label = ""
    var spoken: String = ""
    var onStep: ((Int) -> Void)? = nil
    var onSelect: (() -> Void)? = nil
    /// Round 65 (W8): a setting that only follows its controls outside Edit. Its knob is a small ring, and it can't be dragged.
    var locked = false
    var onBegin: (() -> Void)? = nil
    var onEnd: (() -> Void)? = nil
    @TNFViewState private var dragging = false
    var onChange: (Double) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let axis = TNFEditorAxis(origin: 0, width: Double(w))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)
                Capsule().fill(Color.accentColor.opacity(dim ? 0.45 : 1)).frame(width: max(5, axis.x(value)), height: 5)
                if let b = band {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(bandColor.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(bandColor.opacity(0.8), lineWidth: 1.5))
                        .frame(width: max(8, w * (b.upperBound - b.lowerBound)), height: 17)
                        .offset(x: w * b.lowerBound)
                        .allowsHitTesting(false)
                }
                if let m = mark {
                    Circle().fill(bandColor.opacity(0.28)).frame(width: 27, height: 27)
                        .overlay(Circle().strokeBorder(bandColor, lineWidth: 2))
                        .shadow(color: bandColor.opacity(0.7), radius: 6)
                        .offset(x: axis.x(m) - 13.5)
                        .allowsHitTesting(false)
                }
                if locked {
                    Circle().strokeBorder(Color.primary.opacity(0.75), lineWidth: 2).background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .frame(width: 11, height: 11).offset(x: axis.x(value) - 5.5)
                } else {
                    Circle().fill(.white).frame(width: 17, height: 17).shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                        .overlay { if focused { Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 3).frame(width: 23, height: 23) } }
                        .offset(x: axis.x(value) - 8.5)
                }
            }
            .frame(height: g.size.height)
            .contentShape(.rect)
            .allowsHitTesting(!locked)
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                if !dragging { dragging = true; onBegin?() }
                // ⌥ while dragging: fine, a tenth of the pointer's movement from where the press began.
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1
                onChange(min(1, max(0, (d.startLocation.x + d.translation.width * fine) / w)))
            }.onEnded { _ in dragging = false; onEnd?() })
        }
        .frame(height: 22)
        
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space]) { press in
            if press.key == .space { onSelect?(); return onSelect == nil ? .ignored : .handled }
            let dir = press.key == .rightArrow ? 1.0 : -1.0
            if press.modifiers.contains(.command), let s = onStep { s(Int(dir)); return .handled }
            let step = press.modifiers.contains(.shift) ? 0.1 : press.modifiers.contains(.option) ? 0.002 : 0.01
            onChange(min(1, max(0, value + dir * step)))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(spoken.isEmpty ? "\(Int(value * 100)) percent" : spoken)
        .accessibilityAdjustableAction { dir in onChange(min(1, max(0, value + (dir == .increment ? 0.05 : -0.05)))) }
    }
}

extension Color {
    init(tnfPortHex: UInt32) {
        self.init(.sRGB, red: Double((tnfPortHex >> 16) & 255) / 255, green: Double((tnfPortHex >> 8) & 255) / 255, blue: Double(tnfPortHex & 255) / 255)
    }
    static let tnfPortOrange = Color(red: 1, green: 149/255, blue: 0)
    static let tnfPortIndigo = Color(red: 94/255, green: 92/255, blue: 230/255)
    static let tnfPortBrown = Color(red: 162/255, green: 132/255, blue: 94/255)
    static let tnfPortTeal = Color(red: 48/255, green: 176/255, blue: 199/255)
    static let tnfPortGrey = Color(red: 142/255, green: 142/255, blue: 147/255)
}
extension View {
    @ViewBuilder func tnfFloating(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) { self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        else { self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous)) }
    }
}
enum TNFEditorLayout {
    static let sidebar: CGFloat = 250
    static let gap: CGFloat = 18
    static let minimumWidth: CGFloat = 2 * 22 + (250 + 28 + 18) + 560 + 18 + 380
    static let minimumHeight: CGFloat = 480
    static let name: CGFloat = 96
    static let trackX: CGFloat = 8 + 16 + 12 + name + 12
}
struct TNFEditorHeaderClick: ViewModifier {
    @ObservedObject var commands: TNFEditorCommands
    let key: LibraryControlAddress
    func body(content: Content) -> some View {
        content.contentShape(.rect).onTapGesture { commands.toggleOpen(key, clicks: NSApp?.currentEvent?.clickCount ?? 1) }
    }
}

struct TNFEditorWaypointGlyph: View {
    var index: Int
    var count: Int
    var lit: Bool
    var adaptive: Bool
    var tint: Color = .secondary
    var body: some View {
        Group {
            if adaptive && count <= 4 {
                HStack(spacing: 1.5) { ForEach(0...index, id: \.self) { _ in Circle().frame(width: 3.5, height: 3.5) } }
            } else {
                Capsule().frame(width: lit ? 3 : 1.5, height: lit ? 9 : 5)
            }
        }
        .foregroundStyle(lit ? Color.accentColor : tint)
    }
}

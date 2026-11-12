import Combine
import SwiftUI

public enum MenuVisualizationMode: Int, CaseIterable, Sendable {
    case waveform, spectrum, levels
    public var next: Self { Self(rawValue: (rawValue + 1) % 3)! }
    public var title: String { switch self { case .waveform: "Waveform"; case .spectrum: "Spectrum"; case .levels: "Levels" } }
}
public struct MenuVisualizationExtrema: Equatable, Sendable {
    public let low, high: Float
    public init(low: Float, high: Float) { self.low = low; self.high = high }
}
public struct MenuVisualizationFrame: Equatable, Sendable {
    public let sequence: UInt64
    public let beforeWave, afterWave: [MenuVisualizationExtrema]
    public let beforeSpectrum, afterSpectrum: [Float]
    public let beforeRMSDBFS, afterRMSDBFS: Float
    public let held, silent: Bool
    public init(sequence: UInt64, beforeWave: [MenuVisualizationExtrema], afterWave: [MenuVisualizationExtrema],
                beforeSpectrum: [Float], afterSpectrum: [Float], beforeRMSDBFS: Float,
                afterRMSDBFS: Float, held: Bool, silent: Bool) {
        self.sequence = sequence; self.beforeWave = beforeWave; self.afterWave = afterWave
        self.beforeSpectrum = beforeSpectrum; self.afterSpectrum = afterSpectrum
        self.beforeRMSDBFS = beforeRMSDBFS; self.afterRMSDBFS = afterRMSDBFS
        self.held = held; self.silent = silent
    }
}
public enum MenuVisualizationState: Equatable, Sendable {
    case off, unavailable, warming
    case live(MenuVisualizationFrame)

    var statusName: String {
        switch self { case .off: "Off"; case .unavailable: "Unavailable"; case .warming: "Warming"; case .live: "" }
    }
    func accessibilityValue(for mode: MenuVisualizationMode) -> String {
        statusName.isEmpty ? mode.title : "\(mode.title), \(statusName.lowercased())"
    }
}

@MainActor
final class MenuVisualizationPresentation: ObservableObject {
    @Published var mode = MenuVisualizationMode.waveform
    @Published var frame = MenuVisualizationState.unavailable
    @Published var hovered = false
    var demand: ((MenuVisualizationMode?) -> Void)?
    var visible = false
    func cycle() {
        mode = mode.next
        if case .live = frame { frame = .warming }
        if visible { demand?(mode) }
    }
}

private struct VisualizationWellStyle: ButtonStyle {
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.07 : 0.04),
                                       in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MenuVisualization: View {
    @ObservedObject var state: MenuVisualizationPresentation
    let appName: String?
    let tint: Color
    let comparing: Bool
    var body: some View {
        Button { state.cycle() } label: {
            ZStack {
                plot.frame(width: 161, height: 22).position(x: 86.5, y: 15)
                HStack(spacing: 4) {
                    ForEach(MenuVisualizationMode.allCases, id: \.rawValue) { mode in
                        Circle().fill(Color.primary.opacity(mode == state.mode ? 1 : 0.25)).frame(width: 4, height: 4)
                    }
                }.position(x: 86.5, y: 31)
            }.frame(width: 173, height: 36).contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(VisualizationWellStyle(hovered: state.hovered))
            .background(MenuAnchor("visualization"))
            .onHover { state.hovered = $0 }
            .accessibilityLabel(appName.map { "\($0) sound" } ?? state.mode.title)
            .accessibilityValue(state.frame.accessibilityValue(for: state.mode))
            .accessibilityHint("Shows \(state.mode.next.title)")
            .help(state.mode.title)
    }
    private var plot: some View {
        Canvas { context, size in
            if state.frame == .warming { return }
            guard case .live(let frame) = state.frame else {
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(.secondary.opacity(state.frame == .off ? 0.5 : 0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                return
            }
            let before = Color.primary.opacity(comparing ? 0.85 : 0.4)
            let after = tint.opacity(comparing ? 0.25 : 0.85)
            switch state.mode {
            case .waveform:
                if frame.silent {
                    var line = Path(); line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(line, with: .color(before), lineWidth: 1); return
                }
                for (samples, color) in [(frame.beforeWave, before), (frame.afterWave, after)] {
                    guard !samples.isEmpty else { continue }
                    let column = size.width / CGFloat(samples.count)
                    var path = Path()
                    for (i, sample) in samples.enumerated() {
                        let x = (CGFloat(i) + 0.5) * column
                        path.move(to: CGPoint(x: x, y: size.height * (1 - CGFloat(min(1, max(-1, sample.high * 3)))) / 2))
                        path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(min(1, max(-1, sample.low * 3)))) / 2 + 0.5))
                    }
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: column, lineCap: .butt))
                }
            case .spectrum:
                for (samples, color) in [(frame.beforeSpectrum, before), (frame.afterSpectrum, after)] {
                    guard !samples.isEmpty else { continue }
                    var path = Path()
                    for (i, sample) in samples.enumerated() {
                        let point = CGPoint(x: CGFloat(i) * size.width / CGFloat(max(1, samples.count - 1)), y: size.height * CGFloat(1 - min(1, max(0, (sample + 80) / 80))))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
            case .levels:
                for (index, value, color) in [(0, frame.beforeRMSDBFS, before), (1, frame.afterRMSDBFS, after)] {
                    let y = CGFloat(index) * 11 + 2
                    let track = CGRect(x: 0, y: y, width: size.width, height: 7)
                    context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.secondary.opacity(0.14)))
                    let fill = CGRect(x: 0, y: y, width: size.width * CGFloat(min(1, max(0, (value + 60) / 60))), height: 7)
                    context.fill(Path(roundedRect: fill, cornerRadius: 3), with: .color(color))
                }
            }
        }
    }
}

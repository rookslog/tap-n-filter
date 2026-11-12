import AppKit
import SoundModel
import SwiftUI

struct MenuControlRow: View {
    @ObservedObject var state: MenuPresentation
    let assignment: MenuSoundCard
    let control: MenuSoundControl
    var reserveSymbol = false

    private var position: Double {
        control.position
    }

    private func move(_ value: Double) {
        state.move(control, on: assignment, to: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = controlSymbol(control.id) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(assignment.block.tint).frame(width: 16)
            } else if reserveSymbol { Color.clear.frame(width: 16) }
            Text(control.title).font(.system(size: 12, weight: .medium))
                .frame(width: 68, alignment: .leading).lineLimit(1)
            switch control.face {
            case .choice(let options):
                let selected = assignment.effectiveOption(control)?.id
                let open = assignment.optionTabs.first(where: { $0.parent == control.address })
                    .map { state.tabIsOpen($0, on: assignment) } ?? false
                MenuChoiceControl(options: options, selected: selected, hints: selected.map { id in
                    guard let titles = control.optionChildren[id], !titles.isEmpty else { return [:] }
                    return [id: (open ? "Hide " : "Show ") + titles.joined(separator: ", ")]
                } ?? [:]) { state.activate($0, control: control, on: assignment) }
                .frame(height: 26)
                .overlay(MenuChoiceMarks(options: options, children: control.optionChildren, selected: selected,
                                         open: open, tint: assignment.block.tint))
                .background(MenuAnchor("control-\(assignment.id)-\(control.id)"))
            case .slider:
                MenuTrack(value: position, label: control.title, spoken: readout,
                          keyboardInput: state.keyboardInput, begin: state.beginGesture, end: state.endGesture, change: move)
                    .background(MenuAnchor("control-\(assignment.id)-\(control.id)"))
                Text(readout).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }.frame(height: 26)
    }

    private var readout: String {
        if let readout = control.readout, let text = try? readout.text(at: position) { return text }
        return "\(Int((position * 100).rounded()))%"
    }
}

/// The approved Track drawing and normalized gesture, without prototype model/edit state.
struct MenuTrack: View {
    let value: Double
    let label: String
    let spoken: String
    let keyboardInput: Bool
    var begin: () -> Void = {}
    var end: () -> Void = {}
    let change: (Double) -> Void
    @FocusState private var focused: Bool
    @StateObject private var dragState = MenuDragState()

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)
                Capsule().fill(Color.accentColor).frame(width: max(5, width * value), height: 5)
                Circle().fill(.white).frame(width: 17, height: 17)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    .overlay {
                        if focused && keyboardInput {
                            Circle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 3)
                                .frame(width: 23, height: 23)
                        }
                    }
                    .offset(x: width * value - 8.5)
            }
            .frame(height: geometry.size.height).contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard width > 0 else { return }
                if !dragState.active { dragState.active = true; begin() }
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.1 : 1.0
                change(min(1, max(0, (drag.startLocation.x + drag.translation.width * fine) / width)))
            }.onEnded { _ in dragState.active = false; end() })
        }
        .frame(height: 22).focusable().focused($focused).focusEffectDisabled()
        .onDisappear { if dragState.active { dragState.active = false; end() } }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let direction = press.key == .rightArrow ? 1.0 : -1.0
            let step = press.modifiers.contains(.shift) ? 0.1 : press.modifiers.contains(.option) ? 0.002 : 0.01
            change(min(1, max(0, value + direction * step)))
            return .handled
        }
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(spoken)
        .accessibilityAdjustableAction { direction in
            change(min(1, max(0, value + (direction == .increment ? 0.05 : -0.05))))
        }
    }
}

private final class MenuDragState: ObservableObject {
    var active = false
}

struct MenuAnchor: NSViewRepresentable {
    let name: String
    init(_ name: String) { self.name = name }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

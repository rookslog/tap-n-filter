import SoundModel
import SwiftUI

struct MenuOptionTab: View {
    @ObservedObject var state: MenuPresentation
    let assignment: MenuSoundCard
    let tab: MenuSoundOptionTab

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16)
            GeometryReader { geometry in
                let pickerX: CGFloat = 76
                let pickerWidth = geometry.size.width - pickerX
                let x = pickerX + pickerWidth * (CGFloat(tab.optionIndex) + 0.5) / CGFloat(tab.optionCount)
                VStack(alignment: .leading, spacing: 0) {
                    OptionTabNotch().fill(.quaternary.opacity(0.75))
                        .frame(width: 14, height: 6).offset(x: x - 7)
                    VStack(spacing: 0) {
                        ForEach(Array(tab.controls.enumerated()), id: \.element.address) { index, control in
                            HStack(spacing: 10) {
                                if let symbol = optionSymbol(tab.option.id) {
                                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(assignment.block.tint)
                                }
                                Text(control.title).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.88))
                                    .lineLimit(1).fixedSize()
                                let readout = (try? control.readout?.text(at: control.position)) ?? "\(Int((control.position * 100).rounded()))%"
                                MenuTrack(value: control.position, label: "\(control.title), \(tab.option.title)", spoken: readout,
                                    keyboardInput: state.keyboardInput, begin: state.beginGesture, end: state.endGesture) { state.move(control, on: assignment, to: $0) }
                                    .background(MenuAnchor("control-\(assignment.id)-\(control.id)"))
                                Text(readout).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }.padding(.horizontal, 10).frame(height: index == 0 ? 30 : 26)
                        }
                    }.background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.75)))
                }
            }
        }.frame(height: tab.netHeight + 6).padding(.top, -6)
    }
}

private struct OptionTabNotch: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

import AppKit
import SoundModel
import SwiftUI

enum EditorPartAction {
    case select(UUID)
    case command(LibraryEditCommand)
    case begin(UUID)
    case sample(UUID, LibraryEditCommand)
    case end(UUID)
    case cancel(UUID)
}
struct EditorPartEvent {
    let handle: LibraryEditHandle
    let generation: UInt64
    let action: EditorPartAction
    init(_ snapshot: LibraryEditSnapshot, _ action: EditorPartAction) {
        handle = snapshot.handle; generation = snapshot.generation; self.action = action
    }
}

enum EditorPartPresentation {
    static func name(_ type: String) -> String {
        switch type {
        case "deviceEQ": return "Device EQ"
        case "deviceColour": return "Distortion"
        case "placeEQ": return "Place EQ"
        case "reverb": return "Reverb"
        case "dynamics": return "Evener"
        case "gain": return "Volume"
        default: return type
        }
    }
    static func symbol(_ type: String) -> String {
        switch type {
        case "deviceEQ": return "speaker.wave.1"
        case "deviceColour": return "waveform.path"
        case "placeEQ": return "door.left.hand.closed"
        case "reverb": return "dot.radiowaves.up.forward"
        case "dynamics": return "arrow.down.and.line.horizontal.and.arrow.up"
        case "gain": return "speaker.wave.2"
        default: return "square"
        }
    }
    static func reordered(_ snapshot: LibraryEditSnapshot, part: UUID, by delta: Int) -> LibraryEditCommand? {
        var ids = snapshot.parts.map(\.id)
        guard let index = ids.firstIndex(of: part), ids.indices.contains(index + delta) else { return nil }
        ids.swapAt(index, index + delta)
        return .reorderParts(ids)
    }
}

struct EditorPartChain: View {
    let snapshot: LibraryEditSnapshot
    let selected: UUID?
    let editing: Bool
    let send: (EditorPartEvent) -> Void
    @StateObject private var viewportState = EditorChainViewport()
    private var canAdd: Bool { editing && snapshot.kinds.contains(where: \.canInsert) }
    private func emit(_ action: EditorPartAction) { send(EditorPartEvent(snapshot, action)) }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(snapshot.parts.enumerated()), id: \.element.id) { index, part in
                                tile(part).id(part.id)
                                if index < snapshot.parts.count - 1 {
                                    Image(systemName: "arrow.right").font(.system(size: 8))
                                        .foregroundStyle(.tertiary).frame(width: 10, height: 44)
                                }
                            }
                        }
                        .padding(.top, 6)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: EditorChainBounds.self,
                                value: geometry.frame(in: .named("part-chain")))
                        })
                    }
                    .coordinateSpace(name: "part-chain")
                    .onPreferenceChange(EditorChainBounds.self) { viewportState.bounds = $0 }
                    .mask {
                        HStack(spacing: 0) {
                            LinearGradient(colors: [viewportState.bounds.minX < -0.5 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                            Color.black
                            LinearGradient(colors: [.black, viewportState.bounds.maxX > viewport.size.width + 0.5 ? .clear : .black], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                        }
                    }
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
                    .onChange(of: snapshot.parts.map(\.id)) { old, current in
                        if let added = current.first(where: { !old.contains($0) }) { proxy.scrollTo(added) }
                        else if let selected { proxy.scrollTo(selected) }
                    }
                }
            }
            if canAdd {
                Menu {
                    ForEach(snapshot.kinds.filter(\.canInsert), id: \.type) { kind in
                        Button(EditorPartPresentation.name(kind.type)) {
                            emit(.command(.addPart(type: kind.type, at: snapshot.pieces.count)))
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.dashed").font(.system(size: 28))
                        .symbolRenderingMode(.monochrome).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.leading, 10).padding(.top, 14)
                .help("Add Part").accessibilityLabel("Add Part")
            }
        }
        .frame(height: 78, alignment: .top)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    private func tile(_ part: LibraryEditPart) -> some View {
        VStack(spacing: 6) {
            Button { emit(.select(part.id)) } label: {
                Image(systemName: EditorPartPresentation.symbol(part.type))
                    .font(.system(size: 20)).frame(width: 44, height: 44)
                    .foregroundStyle(selected == part.id ? Color.accentColor : Color.secondary)
                    .background(EditorPartPalette.tile, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected == part.id ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected == part.id ? 2 : 0.5))
            }
            .buttonStyle(.plain).opacity(part.bypassed ? 0.38 : 1)
            .accessibilityLabel(EditorPartPresentation.name(part.type))
            .accessibilityValue(part.bypassed ? "Bypassed" : "On")
            Text(EditorPartPresentation.name(part.type)).font(.system(size: 11, weight: selected == part.id ? .semibold : .regular))
                .foregroundStyle(selected == part.id ? Color.primary : Color.secondary)
                .opacity(part.bypassed ? 0.38 : 1).fixedSize()
        }
        .frame(width: 62, alignment: .top)
        .overlay(alignment: .topLeading) {
            if editing {
                Button { emit(.command(.removePart(part.id))) } label: {
                    Image(systemName: "minus").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white).frame(width: 16, height: 16)
                        .background(Color(nsColor: .systemGray), in: Circle())
                }
                .buttonStyle(.plain).offset(x: 4, y: -6)
                .help("Remove Part").accessibilityLabel("Remove " + EditorPartPresentation.name(part.type))
            }
        }
        .contextMenu {
            if editing {
                Button(part.bypassed ? "Turn On" : "Bypass") { emit(.command(.bypassPart(part.id, !part.bypassed))) }
                Button("Move Earlier") { if let command = EditorPartPresentation.reordered(snapshot, part: part.id, by: -1) { emit(.command(command)) } }
                    .disabled(EditorPartPresentation.reordered(snapshot, part: part.id, by: -1) == nil)
                Button("Move Later") { if let command = EditorPartPresentation.reordered(snapshot, part: part.id, by: 1) { emit(.command(command)) } }
                    .disabled(EditorPartPresentation.reordered(snapshot, part: part.id, by: 1) == nil)
                Divider()
                Button("Remove Part") { emit(.command(.removePart(part.id))) }
            }
        }
    }
}
private struct EditorChainBounds: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private final class EditorChainViewport: ObservableObject {
    @Published var bounds = CGRect.zero
}

enum EditorPartPalette {
    private static func surface(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static let tile = surface("TNF.Editor.Tile", light: 0xffffff, dark: 0x1e1e20)
    static let inspector = surface("TNF.Editor.Inspector", light: 0xf7f7f9, dark: 0x232326)
}

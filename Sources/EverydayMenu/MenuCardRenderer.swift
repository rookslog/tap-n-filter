import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import SoundModel

private actor RenderStore: LibraryPersistence {
    var data: Data?
    func load() -> Data? { data }
    func commit(_ data: Data) -> LibraryWriteOutcome { self.data = data; return .committed }
}

private struct RenderCard: View {
    @ObservedObject var state: MenuPresentation
    let card: MenuSoundCard
    let height: CGFloat
    let backdrop: Color
    var body: some View {
        VStack(spacing: 0) {
            MenuCardHeader(state: state, id: card.id)
            MenuCardControls(state: state, id: card.id)
        }.frame(width: 300, height: height, alignment: .top)
            .background(backdrop)
    }
}

public enum MenuCardRenderer {
    /// `classic` renders Everyday and Filters; otherwise the three newer sounds.
    @MainActor public static func render(to output: URL, classic: Bool = false) async throws {
        let application = NSApplication.shared
        precondition(application.windows.isEmpty)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let limits = try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128,
            expansion: LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128))
        var frames: [[String: Any]] = []
        let kinds: [BuiltinBlock] = classic ? [.everyday, .filters] : [.bigSpace, .oldRecording, .underwater]
        for kind in kinds {
            // The control the card varies, by position in the first snapshot; one fresh library per (sound, choice).
            var choiceIndex = 0
            while true {
                // A fresh library per sound and choice, so each card shows only that state.
                guard case .fresh(let session) = await SoundLibrarySession.open(persistence: RenderStore(), limits: limits, builtins: .quickMenu) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let initial = try await session.snapshot()
                guard let definition = initial.definitions.first(where: { $0.builtin == kind }) else { throw CocoaError(.fileReadCorruptFile) }
                _ = try await session.select(definition.id, on: "fixture.safari")
                try await session.setEnabled(true, on: "fixture.safari")
                let snapshot = try await session.snapshot()
                guard let use = snapshot.uses.first(where: { $0.target == "fixture.safari" }) else { throw CocoaError(.fileReadCorruptFile) }
                let parents = use.controls.filter { if case .choice = $0.face { return true }; return false }
                let parent: LibraryControl? = parents.indices.contains(choiceIndex) ? parents[choiceIndex] : nil
                if parent == nil && choiceIndex > 0 { break }
                let options: [LibraryOption?]
                if let parent, case .choice(let values) = parent.face { options = values.map(Optional.some) }
                else { options = [nil] }
                for option in options {
                    if let parent, let option { try await session.move(LibraryControlAddress(path: [], control: parent.id), on: "fixture.safari",
                        to: .scalar(option.position)) }
                    let selected = try await session.snapshot()
                    for (theme, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", .darkAqua, .dark)] {
                        for open in [false, true] {
                            let state = MenuPresentation(snapshot: selected, glyph: NSImage(size: NSSize(width: 16, height: 16))) { _ in
                                preconditionFailure("Offscreen rendering must not dispatch UI actions")
                            }
                            state.apps = [SourceAppInfo(bundleIdentifier: "fixture.safari", name: "Safari",
                                icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil))]
                            guard let card = state.snapshot.assignments.first else { throw CocoaError(.fileReadCorruptFile) }
                            if open {
                                guard let parent, let tab = card.optionTabs.first(where: { $0.parent.control == parent.id }),
                                      let key = card.foldKey(tab.parent) else { continue }
                                _ = state.folds.activate(key, effective: tab.option.id, option: tab.option, carriesChildren: true)
                            }
                            let head = MenuCardMetrics.headerHeight(enabled: card.isEnabled, choosing: false, blockCount: card.choices.count)
                            let controls = MenuCardMetrics.controlsHeight(enabled: card.isEnabled,
                                primary: card.controls.filter { $0.placement == .primary }.count,
                                extra: card.controls.filter { $0.placement == .more }.count, expanded: false)
                                + state.folds.visibleTabHeight(on: card, expanded: false)
                                + state.folds.visibleTabStackedHeight(on: card, expanded: false)
                            let height = head + controls
                            let choiceName = parents.count > 1 ? parent.map { [$0.title] } ?? [] : []
                            let name = ([definition.name] + choiceName + (option.map { [$0.title] } ?? []) + [open ? "open" : "folded", theme])
                                .joined(separator: "-").lowercased().replacingOccurrences(of: " ", with: "-") + ".png"
                            let root = RenderCard(state: state, card: card, height: height,
                                backdrop: scheme == .dark ? Color(white: 0.16) : Color(white: 0.97)).environment(\.colorScheme, scheme)
                            var frame = try capture(root, card: card, size: NSSize(width: 300, height: height), appearance: appearance,
                                destination: output.appendingPathComponent(name))
                            frame["file"] = name
                            frame["openTabs"] = card.optionTabs.filter { state.tabIsOpen($0, on: card) }.map { $0.option.title }
                            frames.append(frame)
                        }
                    }
                }
                choiceIndex += 1
                if choiceIndex >= max(1, parents.count) { break }
            }
        }
        precondition(application.windows.isEmpty)
        let mint = NSColor.systemMint.usingColorSpace(.sRGB)!
        let result: [String: Any] = ["frames": frames, "windowsBefore": 0, "windowsAfter": application.windows.count,
            "systemMintRGB": [mint.redComponent, mint.greenComponent, mint.blueComponent],
            "everydayRGB": [Double(0x30) / 255, Double(0xB0) / 255, Double(0xC7) / 255],
            "units": "Frame geometry is in points; the PNGs are 2x. Frames are the card at 300 pt wide.",
            "method": "Complete offscreen NSHostingView cacheDisplay at 2x; no window, menu tracking, capture or audio"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-index.json"))
        print("Rendered \(frames.count) cards; zero windows and UI action dispatches")
    }

    @MainActor private static func capture<V: View>(_ root: V, card: MenuSoundCard, size: NSSize, appearance: NSAppearance.Name,
                                                    destination: URL) throws -> [String: Any] {
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage,
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        var result: [String: Any] = ["pixelWidth": image.width, "pixelHeight": image.height,
            "bounds": NSStringFromRect(host.bounds), "intrinsicSize": NSStringFromSize(host.intrinsicContentSize),
            "fixedCardWidth": Double(size.width), "cardHeight": Double(size.height)]
        result.merge(geometry(of: host, card: card)) { $1 }
        return result
    }

    /// Layout read back from the laid-out views, in points and the card's own coordinates. `cardWidth` is the union
    /// of every laid-out view's frame (excluding the 300 pt host itself), so a body laid out wider than the card shows
    /// as more than 300; `fixedCardWidth` is the frame the renderer forces. Slider tracks are listed per row, tray or main.
    @MainActor private static func geometry(of host: NSView, card: MenuSoundCard) -> [String: Any] {
        var rows: [String: (title: String, tray: Bool, predicted: Double?, stacked: Bool)] = [:]
        for control in card.controls { rows[control.id.uuidString] = (control.title, false, nil, false) }
        for tab in card.optionTabs { for control in tab.controls { rows[control.id.uuidString] = (control.title, true, tab.oneLineTrackWidth(control), tab.stacksLabel(control)) } }
        func rect(_ view: NSView) -> NSRect { host.convert(view.bounds, from: view) }
        var tracks: [[String: Any]] = [], segmented: [[String: Any]] = []
        var minX = Double.infinity, maxX = -Double.infinity, minView = "", maxView = ""
        let choiceTitles = Set(card.controls.compactMap { control -> String? in
            if case .choice = control.face { return control.title }; return nil })
        func visit(_ view: NSView, isHost: Bool) {
            let r = rect(view)
            if !isHost, !view.isHidden, r.width > 0, r.height > 0 {
                if Double(r.minX) < minX { minX = Double(r.minX); minView = String(describing: type(of: view)) }
                if Double(r.maxX) > maxX { maxX = Double(r.maxX); maxView = String(describing: type(of: view)) }
            }
            if let raw = view.identifier?.rawValue, raw.hasPrefix("control-"), raw.count >= 36,
               let row = rows[String(raw.suffix(36))], !choiceTitles.contains(row.title), r.height > 0 {
                var entry: [String: Any] = ["row": row.title, "place": row.tray ? "tray" : "main", "x": Double(r.minX),
                                            "trackWidth": Double(r.width)]
                if let predicted = row.predicted { entry["modelOneLineTrack"] = predicted; entry["stackedLabel"] = row.stacked }
                tracks.append(entry)
            }
            if let segment = view as? NSSegmentedControl {
                segmented.append(["x": Double(rect(segment).minX), "width": Double(rect(segment).width),
                                  "maxX": Double(rect(segment).maxX)])
            }
            for sub in view.subviews { visit(sub, isHost: false) }
        }
        visit(host, isHost: true)
        let width = maxX >= minX ? maxX - minX : 0
        return ["cardWidth": width, "contentMinX": minX, "contentMaxX": maxX, "contentMinXView": minView,
                "contentMaxXView": maxView, "sliderTracks": tracks, "segmentedControls": segmented]
    }
}

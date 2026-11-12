import AppKit
import EverydayMenu
import SessionStore
import SoundModel

@MainActor
private final class CaptureTarget {
    let menu: NSMenu
    init(_ menu: NSMenu) { self.menu = menu }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var surface: EverydayMenu?
    private var session: SoundLibrarySession?
    private var comparing = false
    private var pending: Task<Void, Never>?
    private let interactive = CommandLine.arguments.contains("--interactive")
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tnf-menu-fixture-" + UUID().uuidString)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = LibrarySessionFile(url: directory.appendingPathComponent("library-v5.json"), maximumBytes: 4_000_000)
                let limits = try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128,
                    expansion: LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128))
                guard case .fresh(let session) = await SoundLibrarySession.open(persistence: store, limits: limits, builtins: .quickMenu) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                self.session = session
                let initial = try await session.snapshot()
                guard let everyday = initial.definitions.first(where: { $0.builtin == .everyday }),
                    let url = Bundle.module.url(forResource: "neck1", withExtension: "pdf", subdirectory: "Resources"),
                    let glyph = NSImage(contentsOf: url) else { throw CocoaError(.fileReadNoSuchFile) }
                glyph.isTemplate = true
                _ = try await session.select(everyday.id, on: "fixture.safari")
                let snapshot = try await session.snapshot()
                let surface = EverydayMenu(snapshot: snapshot, glyph: glyph) { [weak self] in self?.send($0) }
                self.surface = surface
                refresh(snapshot)
                let main = NSMenu()
                let app = NSMenuItem(title: "TNF Preview", action: nil, keyEquivalent: "")
                app.submenu = surface.appMenu
                main.addItem(app)
                NSApplication.shared.mainMenu = main
                if let flag = CommandLine.arguments.firstIndex(of: "--capture-dir"), CommandLine.arguments.indices.contains(flag + 1) {
                    try await captureMatrix(session, surface: surface, directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                    NSApplication.shared.terminate(nil)
                } else if !interactive {
                    try await checks(session, surface)
                    NSApplication.shared.terminate(nil)
                }
            } catch { print("FAIL menu fixture: \(error)"); exit(1) }
        }
    }

    private func refresh(_ snapshot: LibrarySnapshot) {
        surface?.update(snapshot: snapshot, pendingApps: [], apps: [
            SourceAppInfo(bundleIdentifier: "fixture.safari", name: "Safari", icon: NSImage(systemSymbolName: "safari", accessibilityDescription: nil)),
            SourceAppInfo(bundleIdentifier: "fixture.iina", name: "IINA", icon: NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil))
        ], comparing: comparing, compareAvailable: snapshot.isEnabled && !snapshot.assignments.isEmpty, problem: nil)
    }

    private func send(_ action: EverydayMenuAction) {
        let previous = pending
        pending = Task { @MainActor in
            await previous?.value
            guard let session else { return }
            do {
                switch action {
                case .setEnabled(let enabled): await session.setEnabled(enabled)
                case .putOn(let bundle):
                    guard let definition = try await session.snapshot().definitions.first(where: { $0.builtin == .everyday }) else { return }
                    _ = try await session.select(definition.id, on: bundle)
                case .selectBlock(let definition, let bundle): _ = try await session.select(definition, on: bundle)
                case .libraryPower(let binding, let enabled): _ = try await session.setEnabled(enabled, expected: binding)
                case .libraryMove(let binding, let address, let position): _ = try await session.move(address, expected: binding, to: position)
                case .libraryOptionMove(let binding, let address, let gesture, let position):
                    _ = try await session.move(address, expected: binding, optionGesture: gesture, to: position)
                case .menuMove(let identity, _, let address, let gesture, let position):
                    _ = try await session.moveForMenu(address, expected: identity, optionGesture: gesture, to: position)
                case .compare(let value): comparing = value; await session.compareOriginal(value)
                case .beginGesture, .endGesture: return
                case .setAppEnabled, .move: throw CocoaError(.validationMissingMandatoryProperty)
                case .quit: NSApplication.shared.terminate(nil)
                case .showProblem, .refreshSources: break
                }
                _ = try await session.checkpoint()
                refresh(try await session.snapshot())
            } catch { print("FAIL menu action: \(error)") }
        }
    }

    private func checks(_ session: SoundLibrarySession, _ surface: EverydayMenu) async throws {
        let snapshot = try await session.snapshot()
        guard let assignment = snapshot.assignments.first,
            surface.menu.items.contains(where: { $0.identifier?.rawValue == "header-\(assignment.id)" }),
            surface.menu.items.contains(where: { $0.identifier?.rawValue == "controls-\(assignment.id)" }),
            surface.menu.items.contains(where: { $0.title == "Apps" && $0.submenu != nil }),
            surface.menu.items.contains(where: { $0.title == "Settings…" }),
            !surface.menu.items.contains(where: { $0.title.contains("Editor") }),
            !surface.appMenu.items.contains(where: { $0.title.contains("Editor") }),
            MenuSoundData(library: snapshot).choices.map(\.title) == ["Everyday", "Filters"] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        print("PASS current hosted card/inline chooser fixture structure; no audio or native appearance verdict")
    }

    private func captureMatrix(_ session: SoundLibrarySession, surface: EverydayMenu, directory: URL) async throws {
        let initial = try await session.snapshot()
        for definition in initial.definitions where definition.origin == "builtin" {
            _ = try await session.select(definition.id, on: "fixture.safari")
            let snapshot = try await session.snapshot()
            guard let use = snapshot.uses.first(where: { $0.id == snapshot.assignments[0].use }) else { continue }
            let parents = use.controls.filter { control in use.optionControls.contains { $0.parent.control == control.id } }
            if parents.isEmpty { refresh(snapshot); try captures(surface.menu, directory: directory, name: definition.name.lowercased()); continue }
            for parent in parents {
                guard case .choice(let options) = parent.face else { continue }
                for option in options {
                    try await session.move(parent.id, on: "fixture.safari", to: .scalar(option.position))
                    refresh(try await session.snapshot())
                    let name = [definition.name, parent.title, option.title].joined(separator: "-").lowercased().replacingOccurrences(of: " ", with: "-")
                    try captures(surface.menu, directory: directory, name: name)
                }
                try await session.move(parent.id, on: "fixture.safari", to: .scalar(0))
            }
        }
    }

    private func captures(_ menu: NSMenu, directory: URL, name prefix: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = CaptureTarget(menu)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApplication.shared.appearance = NSAppearance(named: appearance)
            menu.appearance = NSAppearance(named: appearance)
            let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let menu = target.menu
                    defer { menu.cancelTracking() }
                    do {
                        let destination = directory.appendingPathComponent("\(prefix)-\(name).png")
                        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                        let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
                        let metadata: [String: Any] = [
                            "ownedWindows": owned,
                            "screenCapturePreflight": CGPreflightScreenCaptureAccess(),
                            "applicationActive": NSApplication.shared.isActive,
                            "screenCount": NSScreen.screens.count,
                            "menuWidth": menu.size.width,
                            "menuHeight": menu.size.height,
                            "visibleWindowCount": windows.count,
                            "layerCounts": Dictionary(grouping: windows, by: { String(($0[kCGWindowLayer as String] as? Int) ?? -1) }).mapValues(\.count),
                        ]
                        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                            .write(to: directory.appendingPathComponent("\(prefix)-\(name).windows.json"))
                        guard let visible = owned.first(where: { ($0[kCGWindowLayer as String] as? Int) == 101 }),
                              let bounds = visible[kCGWindowBounds as String] as? [String: Double],
                              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else {
                            throw CocoaError(.fileReadUnknown)
                        }
                        let size = menu.size
                        let rectangle = "\(Int(x + (width - size.width) / 2)),\(Int(y + (height - size.height) / 2)),\(Int(size.width)),\(Int(size.height))"
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-R", rectangle, destination.path]
                        try capture.run()
                        capture.waitUntilExit()
                        guard capture.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                        print("CAPTURE \(destination.path) owned-compositor=\(visible[kCGWindowNumber as String] ?? 0) owned-rect=\(rectangle)")
                    } catch { print("FAIL capture: \(error)") }
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
            NSApplication.shared.activate()
            menu.popUp(positioning: nil, at: NSPoint(x: screen.maxX - 320, y: screen.maxY - 36), in: nil)
            timer.invalidate()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { surface?.dockMenu }
}

@main
struct MenuFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

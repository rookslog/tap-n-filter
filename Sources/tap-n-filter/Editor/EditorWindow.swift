import AppKit
import SoundModel
import SwiftUI

/// Constructed only by the normal App's explicit Open Editor action.
@MainActor final class TNFEditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    let commands: TNFEditorCommands
    private var closing = false
    private var allowClose = false
    private var installedMenus: [NSMenuItem] = []
    private weak var inheritedEditDelegate: NSMenuDelegate?
    private weak var inheritedViewDelegate: NSMenuDelegate?
    private var sidebarItem: NSToolbarItem?
    private let toolbarDelegate = TNFEditorWindowChrome()

    init(app: LibraryAppSession, feedback: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        commands = TNFEditorCommands(app: app, feedback: feedback)
        commands.appIdentityResolver = TNFEditorAppIdentity.resolve
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init(window: window)
        window.title = commands.title
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: TNFEditorLayout.minimumWidth, height: TNFEditorLayout.minimumHeight)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TNFEditorSurface(commands: commands, titleChanged: { [weak window] in window?.title = $0 }))
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        let toolbar = NSToolbar(identifier: "TNF.Editor.Toolbar")
        toolbar.delegate = toolbarDelegate
        toolbarDelegate.toggle = { [weak self] in self?.toggleSidebar(nil) }
        toolbarDelegate.visible = { [weak self] in self?.commands.sidebarVisible ?? true }
        window.toolbar = toolbar
        window.center()
        installMenus()
    }
    required init?(coder: NSCoder) { nil }
    func open(preferredApp: String?) {
        allowClose = false
        Task { @MainActor in
            do {
                if preferredApp != nil { try await commands.selectInitial(preferredApp: preferredApp) }
                else if commands.adapter.token == nil {
                    switch commands.target {
                    case .definition(let id): try await commands.select(.definition(id))
                    case .use(let binding): try await commands.selectInitial(preferredApp: binding.target)
                    case nil: try await commands.selectInitial()
                    }
                }
            }
            catch { commands.fail(error) }
            commands.refreshAppIdentities()
            commands.windowPresented = true
            showWindow(nil)
            window?.title = commands.title
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(window)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func ownerDidChange(compareAvailable: Bool) {
        if commands.compareAvailable != compareAvailable { commands.compareAvailable = compareAvailable }
        commands.receiveOwnerChange()
        window?.title = commands.title
    }
    func prepareQuit() { commands.prepareQuit() }
    func windowDidResignKey(_ notification: Notification) { commands.compare(false) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        guard !closing else { return false }
        closing = true
        Task { @MainActor in
            defer { closing = false }
            do {
                try await commands.close()
                commands.windowPresented = false
                allowClose = true; sender.close()
            } catch { commands.fail(error) }
        }
        return false
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard window?.isKeyWindow == true, !closing, commands.app.coordinator.lifecycle == .running else { return false }
        if let box = menuItem.representedObject as? TNFEditorMenuBox {
            return box.token == commands.adapter.token && box.target == commands.target && (!box.editing || commands.editing) && (!box.authoring || commands.canAuthor)
        }
        switch menuItem.action {
        case NSSelectorFromString("undo:"): return commands.edit?.canUndo == true
        case NSSelectorFromString("redo:"): return commands.edit?.canRedo == true
        case #selector(toggleEdit(_:)), #selector(discard(_:)): return commands.canAuthor
        case #selector(toggleSidebar(_:)):
            menuItem.title = commands.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return true
        default: return false
        }
    }
    @objc func toggleSidebar(_ sender: Any?) {
        guard window?.isKeyWindow == true, !closing else { return }
        commands.sidebarVisible.toggle()
        toolbarDelegate.refresh()
    }
    @objc private func toggleEdit(_ sender: Any?) { route { if self.commands.editing { try await self.commands.done() } else { try self.commands.startEditing() } } }
    @objc(undo:) private func undoEditor(_ sender: Any?) { route { try await self.commands.history(redo: false) } }
    @objc(redo:) private func redoEditor(_ sender: Any?) { route { try await self.commands.history(redo: true) } }
    @objc private func discard(_ sender: Any?) { route { try await self.commands.discard() } }
    private func route(_ work: @escaping @MainActor () async throws -> Void) {
        guard window?.isKeyWindow == true, !closing else { return }
        let token = commands.adapter.token
        Task { do { try commands.validateCallback(token); try await work() } catch { commands.fail(error) } }
    }
    @objc private func performEditorItem(_ item: NSMenuItem) {
        guard validateMenuItem(item), let box = item.representedObject as? TNFEditorMenuBox else { return }
        route(box.perform)
    }
    private func installMenus() {
        guard let main = NSApp.mainMenu else { return }
        func menu(_ title: String, after previous: String?) -> NSMenu {
            if let existing = main.items.first(where: { $0.submenu?.title == title })?.submenu { return existing }
            let result = NSMenu(title: title), root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            root.submenu = result
            let index = previous.flatMap { title in main.items.firstIndex { $0.submenu?.title == title } }.map { $0 + 1 } ?? 1
            main.insertItem(root, at: min(index, main.items.count)); installedMenus.append(root)
            return result
        }
        func hasClose(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                item.action == NSSelectorFromString("performClose:") ||
                (item.keyEquivalent.lowercased() == "w" && item.keyEquivalentModifierMask.contains(.command)) ||
                item.submenu.map(hasClose) == true
            }
        }
        if !hasClose(main) {
            let file = menu("File", after: nil)
            let close = NSMenuItem(title: "Close", action: NSSelectorFromString("performClose:"), keyEquivalent: "w")
            close.target = nil; file.addItem(close)
        }
        let edit = menu("Edit", after: "File")
        inheritedEditDelegate = edit.delegate; edit.delegate = self
        let standard = [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")]
        for (offset, row) in standard.enumerated() {
            let selector = NSSelectorFromString(row.1)
            guard !edit.items.contains(where: { $0.action == selector }) else { continue }
            let next = standard.dropFirst(offset + 1).compactMap { following in edit.items.firstIndex { $0.action == NSSelectorFromString(following.1) } }.first
            let prior = standard.prefix(offset).compactMap { previous in edit.items.lastIndex { $0.action == NSSelectorFromString(previous.1) } }.max()
            let item = NSMenuItem(title: row.0, action: selector, keyEquivalent: row.2)
            item.target = nil; edit.insertItem(item, at: next ?? prior.map { $0 + 1 } ?? 0)
        }
        for selector in ["redo:", "paste:"] {
            if let index = edit.items.firstIndex(where: { $0.action == NSSelectorFromString(selector) }),
               index + 1 < edit.items.count, !edit.items[index + 1].isSeparatorItem { edit.insertItem(.separator(), at: index + 1) }
        }
        if edit.items.last?.isSeparatorItem == false { edit.addItem(.separator()) }
        for (title, selector, key) in [("Edit Block", #selector(toggleEdit(_:)), "e"), ("Discard Changes", #selector(discard(_:)), "")] {
            guard !edit.items.contains(where: { $0.action == selector }) else { continue }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; edit.addItem(item)
        }
        let view = menu("View", after: "Edit")
        inheritedViewDelegate = view.delegate; view.delegate = self
        if !view.items.contains(where: { $0.action == #selector(toggleSidebar(_:)) }) {
            let item = NSMenuItem(title: commands.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
            item.keyEquivalentModifierMask = [.command, .control]; item.target = self; view.addItem(item)
        }
        for title in ["Block", "Parts", "Controls", "Map"] {
            let menu = NSMenu(title: title); menu.delegate = self
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = menu
            main.addItem(item); installedMenus.append(item)
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        commands.menuOpened()
        if menu.title == "Edit" { inheritedEditDelegate?.menuNeedsUpdate?(menu); return }
        if menu.title == "View" {
            inheritedViewDelegate?.menuNeedsUpdate?(menu)
            menu.items.first { $0.action == #selector(toggleSidebar(_:)) }?.title = commands.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            toolbarDelegate.refresh(); return
        }
        guard ["Block", "Parts", "Controls", "Map"].contains(menu.title) else { return }
        menu.removeAllItems()
        func add(_ title: String, editing: Bool = false, authoring: Bool = false, _ operation: @escaping @MainActor () async throws -> Void) {
            let item = NSMenuItem(title: title, action: #selector(performEditorItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = TNFEditorMenuBox(token: commands.adapter.token, target: commands.target, editing: editing, authoring: authoring, perform: operation)
            menu.addItem(item)
        }
        switch menu.title {
        case "Block":
            add("New Block") { let result = await self.commands.app.createEmpty(name: "Untitled Block").value; try self.commands.requireAccepted(result); await self.commands.app.coordinator.refresh(); if let ref = result.creation?.acceptedReference { try await self.commands.select(.definition(ref.definition)) } }
            add("Rename…", authoring: true) { self.commands.requestRename() }
            if commands.binding != nil {
                add("Use the Library’s Name") { try await self.commands.useLibraryName() }
                add("Make It Its Own") { try await self.commands.makeItsOwn() }
            }
            if let definition = commands.definition {
                add("In the Menu") { try await self.commands.setInMenu(!definition.inTheMenu) }
                menu.items.last?.state = definition.inTheMenu ? .on : .off
            }
            add("Update Library…", authoring: true) { self.commands.updateChooser = true }
        case "Parts":
            for kind in commands.edit?.kinds.filter(\.canInsert) ?? [] {
                add("Add " + TNFEditorNames.part(kind.type), editing: true, authoring: true) { try await self.commands.command(.addPart(type: kind.type, at: self.commands.edit?.parts.count ?? 0)) }
            }
            if let part = commands.edit?.parts.first(where: { $0.id == commands.openPart }) {
                menu.addItem(.separator())
                add(part.bypassed ? "Turn On" : "Turn Off", authoring: true) { try await self.commands.quickBypass(part.id, bypassed: !part.bypassed) }
                for delta in [-1, 1] {
                    let order = commands.edit!.parts.map(\.id)
                    if let index = order.firstIndex(of: part.id), order.indices.contains(index + delta) {
                        var moved = order; moved.swapAt(index, index + delta)
                        add(delta == -1 ? "Move Left" : "Move Right", editing: true, authoring: true) { try await self.commands.command(.reorderParts(moved)) }
                    }
                }
                add("Remove Part", editing: true, authoring: true) { try await self.commands.command(.removePart(part.id)) }
            }
        case "Controls":
            for (title, kind) in [("New Slider…", TNFEditorControlKind.slider), ("New Choice…", .choice), ("New Switch…", .switchControl)] {
                add(title, editing: true, authoring: true) { self.commands.newControlKind = kind }
            }
            if let address = commands.focusedControl,
               let control = commands.projection?.mappings.descriptors.first(where: { $0.address == address })?.presentation {
                add("Rename " + control.title + "…", authoring: true) { if let token = self.commands.adapter.token { self.commands.renameSheet = TNFEditorRename(title: control.title, action: .control(token, address.path, control.id)) } }
                add("Remove " + control.title, editing: true, authoring: true) { try await self.commands.mapping(.removeControl(control.id), path: address.path) }
            }
        case "Map":
            if let address = commands.focusedControl,
               let source = commands.projection?.mappings.descriptors.first(where: { $0.address == address }) {
                for part in commands.edit?.parts ?? [] where address.path.isEmpty {
                    for setting in part.settings {
                        add("Map " + (source.presentation?.title ?? "Control") + " to " + TNFEditorNames.part(part.type) + " · " + TNFEditorNames.parameter(setting.parameter), editing: true, authoring: true) {
                            try await self.commands.connect(source: source, target: .setting(part: part.id, parameter: setting.parameter))
                        }
                    }
                }
                for selector in commands.controls where selector.id != address.control {
                    if case .choice = selector.face {
                        add("Different for Each " + selector.title + " Option", editing: true, authoring: true) { try await self.commands.mapping(.differentForOptions(source: address.control, selector: selector.id), path: address.path) }
                    }
                }
                if commands.projection?.mappings.bindings.contains(where: { $0.path == address.path && $0.source.control == address.control && $0.selector != nil }) == true {
                    add("Use This Option for All…", editing: true, authoring: true) { try await self.commands.previewSameForAll(path: address.path, source: address.control) }
                }
            }
        default: break
        }
    }

}

@MainActor private final class TNFEditorWindowChrome: NSObject, NSToolbarDelegate {
    var toggle: (() -> Void)?
    var visible: (() -> Bool)?
    private weak var button: NSButton?
    private let sidebar = NSToolbarItem.Identifier("TNF.Editor.Sidebar")
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [sidebar] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [sidebar, .flexibleSpace] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == sidebar else { return nil }
        let button = NSButton(title: "", target: self, action: #selector(pressed))
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.isBordered = false; button.contentTintColor = .secondaryLabelColor
        button.identifier = NSUserInterfaceItemIdentifier("tnf-sidebar")
        let item = NSToolbarItem(itemIdentifier: sidebar)
        self.button = button
        item.view = button; item.label = "Sidebar"; item.isNavigational = true
        refresh()
        return item
    }
    func refresh() {
        let label = visible?() == true ? "Hide Sidebar" : "Show Sidebar"
        button?.toolTip = label; button?.setAccessibilityLabel(label)
    }
    @objc private func pressed() { toggle?(); refresh() }
}

struct TNFEditorEar: NSViewRepresentable {
    let commands: TNFEditorCommands
    func makeNSView(context: Context) -> TNFEditorEarButton {
        let button = TNFEditorEarButton()
        button.image = NSImage(systemSymbolName: "ear", accessibilityDescription: "Hold to Hear the Original")
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.toolTip = "Hold to Hear the Original"
        button.setAccessibilityLabel("Hold to Hear the Original")
        button.held = { [weak commands] in commands?.compare($0) }
        return button
    }
    func updateNSView(_ button: TNFEditorEarButton, context: Context) { button.isEnabled = commands.app.isReady && commands.compareAvailable }
    static func dismantleNSView(_ button: TNFEditorEarButton, coordinator: ()) { button.held?(false) }
}
@MainActor final class TNFEditorEarButton: NSButton {
    var held: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        held?(true)
        defer { held?(false) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49, isEnabled else { super.keyDown(with: event); return }
        held?(true)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { held?(false) } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { held?(false); return super.resignFirstResponder() }
}

@MainActor private final class TNFEditorMenuBox: NSObject {
    let token: LibraryEditorToken?
    let target: LibraryEditTarget?
    let editing: Bool
    let authoring: Bool
    let perform: @MainActor () async throws -> Void
    init(token: LibraryEditorToken?, target: LibraryEditTarget?, editing: Bool, authoring: Bool, perform: @escaping @MainActor () async throws -> Void) {
        self.token = token; self.target = target; self.editing = editing; self.authoring = authoring; self.perform = perform
    }
}

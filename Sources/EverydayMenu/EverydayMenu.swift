import AppKit
import SoundModel
import SwiftUI

@MainActor
private final class MenuActionBox: NSObject {
    let action: EverydayMenuAction
    init(_ action: EverydayMenuAction) { self.action = action }
}

/// A native status menu with stable card slices and an inline block chooser.
@MainActor
public final class EverydayMenu: NSObject, NSMenuDelegate {
    public let menu = NSMenu(title: "TNF")
    public let appMenu = NSMenu(title: "TNF")
    public let dockMenu = NSMenu(title: "TNF")
    /// The existing owned button, exposed read-only for native fixture entry; no alternate menu is created.
    public var statusButton: NSStatusBarButton? { status.button }
    private let status: NSStatusItem
    private var librarySnapshot: LibrarySnapshot?
    private let state: MenuPresentation
    private let visibilityChanged: (Bool) -> Void
    private let openEditor: ((String?) -> Void)?
    private var tracking = false
    private var comparingHeld = false
    private var headers: [NSMenuItem: UUID] = [:]
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var problemItem: NSMenuItem?
    private var cards: [UUID: [NSMenuItem]] = [:]
    private var otherItem: NSMenuItem?
    private var otherMenu: NSMenu?
    private var sourceRows: [String: OtherAppMenuRow] = [:]
    private var dispatchingAppRequest: (bundle: String, change: MenuAppChange, request: UUID)?
    private var deactivation: NSObjectProtocol?

    public convenience init(snapshot: ListeningSnapshot, glyph: NSImage,
                visibilityChanged: @escaping (Bool) -> Void = { _ in },
                visualizationDemandChanged: @escaping (MenuVisualizationMode?) -> Void = { _ in },
                openEditor: ((String?) -> Void)? = nil,
                perform: @escaping (EverydayMenuAction) -> Void) {
        self.init(state: MenuPresentation(snapshot: snapshot, glyph: glyph, perform: perform),
            glyph: glyph, visibilityChanged: visibilityChanged, visualizationDemandChanged: visualizationDemandChanged, openEditor: openEditor)
    }

    public convenience init(snapshot: LibrarySnapshot, glyph: NSImage,
                visibilityChanged: @escaping (Bool) -> Void = { _ in },
                visualizationDemandChanged: @escaping (MenuVisualizationMode?) -> Void = { _ in },
                openEditor: ((String?) -> Void)? = nil,
                perform: @escaping (EverydayMenuAction) -> Void) {
        self.init(state: MenuPresentation(snapshot: snapshot, glyph: glyph, perform: perform),
            glyph: glyph, visibilityChanged: visibilityChanged, visualizationDemandChanged: visualizationDemandChanged, openEditor: openEditor)
    }

    public convenience init(presentation: LibraryMenuState, glyph: NSImage,
                visibilityChanged: @escaping (Bool) -> Void = { _ in },
                visualizationDemandChanged: @escaping (MenuVisualizationMode?) -> Void = { _ in },
                openEditor: ((String?) -> Void)? = nil,
                perform: @escaping (EverydayMenuAction) -> Void) {
        self.init(state: MenuPresentation(presentation: presentation, glyph: glyph, perform: perform),
            glyph: glyph, visibilityChanged: visibilityChanged,
            visualizationDemandChanged: visualizationDemandChanged, openEditor: openEditor)
    }

    private init(state: MenuPresentation, glyph: NSImage, visibilityChanged: @escaping (Bool) -> Void,
                 visualizationDemandChanged: @escaping (MenuVisualizationMode?) -> Void, openEditor: ((String?) -> Void)?) {
        self.state = state
        self.visibilityChanged = visibilityChanged
        self.openEditor = openEditor
        state.visualization.demand = visualizationDemandChanged
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        for target in [menu, appMenu, dockMenu] {
            target.autoenablesItems = false
            target.delegate = self
        }
        status.menu = menu
        status.button?.image = glyph
        status.button?.setAccessibilityLabel("TNF")
        state.resize = { [weak self] in self?.resize() }
        deactivation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelInteraction() } }
        rebuild()
    }

    /// Optional level input is dormant without an owner; no timer or audio producer exists here.
    public func update(snapshot: ListeningSnapshot, apps: [SourceAppInfo], comparing: Bool,
                       compareAvailable: Bool, problem: String?, levels: [UUID: MenuLevelFrame] = [:],
                       snapshotOrigin: MenuSnapshotOrigin = .cached) {
        librarySnapshot = nil
        let projected = MenuSoundData(legacy: snapshot)
        if state.snapshot != projected { state.snapshot = projected }
        if case .authoritative = snapshotOrigin {
            state.interaction.acknowledgeAuthoritative(Set(snapshot.assignments.map(\.bundleIdentifier)))
        }
        updateCommon(apps: apps, comparing: comparing, compareAvailable: compareAvailable, problem: problem, levels: levels)
    }

    public func update(snapshot: LibrarySnapshot, pendingApps: Set<String>, apps: [SourceAppInfo], comparing: Bool,
                       compareAvailable: Bool, problem: String?, levels: [UUID: MenuLevelFrame] = [:]) {
        if librarySnapshot != snapshot {
            librarySnapshot = snapshot
            let projected = MenuSoundData(library: snapshot)
            if state.snapshot != projected { state.snapshot = projected }
        }
        state.libraryPending = pendingApps
        updateCommon(apps: apps, comparing: comparing, compareAvailable: compareAvailable, problem: problem, levels: levels)
    }

    private func updateCommon(apps: [SourceAppInfo], comparing: Bool, compareAvailable: Bool,
                              problem: String?, levels: [UUID: MenuLevelFrame]) {
        if !state.apps.elementsEqual(apps, by: {
            $0.bundleIdentifier == $1.bundleIdentifier && $0.name == $1.name && $0.isSelectable == $1.isSelectable && $0.icon === $1.icon
        }) { state.apps = apps }
        if state.comparing != comparing { state.comparing = comparing }
        if state.compareAvailable != compareAvailable { state.compareAvailable = compareAvailable }
        if state.problem != problem { state.problem = problem }
        problemItem?.title = problem ?? "Audio Needs Attention…"
        problemItem?.isHidden = problem == nil
        if state.levels != levels { state.levels = levels }
        let current = Set(state.snapshot.assignments.map(\.id))
        let retainedMore = state.more.intersection(current)
        if retainedMore != state.more { state.more = retainedMore }
        if state.interaction.choosing.map({ !current.contains($0) }) == true
            || state.interaction.hoveredPill.map({ !current.contains($0) }) == true {
            state.interaction.retainCards(current)
        }
        if tracking { reconcileCards() } else { rebuild() }
        updateSourceRows()
    }

    public func update(data: MenuSoundData, positionContext: MenuPositionContext? = nil,
                       pendingApps: Set<String>, apps: [SourceAppInfo], comparing: Bool,
                       compareAvailable: Bool, problem: String?, levels: [UUID: MenuLevelFrame] = [:]) {
        librarySnapshot = nil
        state.positionContext = positionContext
        let current = positionContext.map { data.contextualized($0) } ?? data
        if state.snapshot != current { state.snapshot = current }
        state.libraryPending = pendingApps
        updateCommon(apps: apps, comparing: comparing, compareAvailable: compareAvailable, problem: problem, levels: levels)
    }

    @discardableResult
    public func updatePositionContext(_ context: MenuPositionContext) { state.installPositionContext(context) }

    public func applyPositions(_ delta: LibraryMenuDelta, context: MenuPositionContext) -> Bool {
        state.applyPositions(delta, context: context)
    }

    public func updateVisualization(_ visualization: MenuVisualizationState) {
        if state.visualization.frame != visualization { state.visualization.frame = visualization }
    }

    public func pendingAppRequest(for action: EverydayMenuAction) -> (bundle: String, request: UUID)? {
        guard let dispatchingAppRequest else { return nil }
        let bundle: String
        let change: MenuAppChange
        switch action {
        case .putOn(let target): bundle = target; change = .add
        case .selectBlock(nil, let target): bundle = target; change = .remove
        default: return nil
        }
        guard dispatchingAppRequest.bundle == bundle, dispatchingAppRequest.change == change,
              state.interaction.pendingChanges[bundle]?.request.id == dispatchingAppRequest.request else { return nil }
        return (bundle, dispatchingAppRequest.request)
    }

    public func acknowledgeAppChangeFailure(_ bundle: String, request: UUID, outcome: MenuAppChangeFailure) {
        state.interaction.acknowledgeFailure(bundle, request: request, outcome: outcome)
        updateSourceRows()
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu {
            rebuild()
            state.perform(.refreshSources)
        } else if menu === appMenu || menu === dockMenu { rebuildFallbacks() }
    }

    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu || menu === appMenu || menu === dockMenu else { return }
        tracking = true
        state.keyboardInput = NSApp.currentEvent?.type == .keyDown
        if menu === self.menu {
            state.visualization.visible = true
            state.visualization.demand?(state.visualization.mode)
        }
        visibilityChanged(true)
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu || menu === appMenu || menu === dockMenu else { return }
        tracking = false
        state.endGesture()
        state.highlighted = nil
        state.levels = [:]
        state.interaction.reset()
        cancelInteraction()
        if menu === self.menu {
            state.visualization.visible = false
            state.visualization.frame = .unavailable
            state.visualization.hovered = false
            state.visualization.demand?(nil)
        }
        visibilityChanged(false)
    }

    public func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        if menu === otherMenu { sourceRows.values.forEach { $0.needsDisplay = true } }
        if menu === self.menu {
            state.highlighted = item.flatMap { headers[$0] }
            if NSApp.currentEvent?.type == .keyDown { state.keyboardInput = true }
            else if NSApp.currentEvent?.type == .mouseMoved || NSApp.currentEvent?.type == .leftMouseDown {
                state.keyboardInput = false
            }
        }
    }

    private func cancelInteraction() {
        state.interactionEpoch &+= 1
        holdOriginal(false)
    }

    private func holdOriginal(_ held: Bool) {
        let next = held && state.compareAvailable
        guard comparingHeld != next else { return }
        comparingHeld = next
        state.perform(.compare(next))
    }

    private func item(_ title: String, _ action: EverydayMenuAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuActionBox(action)
        return item
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MenuActionBox else { return }
        state.perform(box.action)
    }

    private func viewItem(_ key: String, height: CGFloat, _ view: AnyView, in target: NSMenu? = nil, at index: Int? = nil) -> NSMenuItem {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 300, height: height)
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier(key)
        item.view = host
        item.isEnabled = true
        hosts[key] = host
        if let index { (target ?? menu).insertItem(item, at: index) }
        else { (target ?? menu).addItem(item) }
        return item
    }

    private func rebuild() {
        guard !tracking else { return }
        menu.removeAllItems()
        headers.removeAll()
        hosts.removeAll()
        cards.removeAll()
        sourceRows.removeAll()
        otherItem = nil
        otherMenu = nil
        state.highlighted = nil
        _ = viewItem("head", height: MenuHeadMetrics.totalHeight, AnyView(MenuHead(state: state, compare: { [weak self] in
            self?.holdOriginal($0)
        })))
        for assignment in state.snapshot.assignments {
            guard state.definition(assignment) != nil else { continue }
            insertCard(assignment, at: menu.numberOfItems)
        }
        let other = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        other.identifier = NSUserInterfaceItemIdentifier("other")
        let sources = NSMenu(title: "Apps")
        sources.autoenablesItems = false
        sources.delegate = self
        let roster = MenuAppRoster.bundles(state.apps.map { ($0.bundleIdentifier, $0.isSelectable) })
        for bundle in roster {
            guard let source = state.apps.first(where: { $0.bundleIdentifier == bundle && $0.isSelectable }) else { continue }
            let choice = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            choice.identifier = NSUserInterfaceItemIdentifier("source-\(source.bundleIdentifier)")
            let row = OtherAppMenuRow(source: source) { [weak self] in
                self?.toggle(source.bundleIdentifier)
            }
            choice.view = row
            sources.addItem(choice)
            sourceRows[source.bundleIdentifier] = row
        }
        other.isEnabled = !roster.isEmpty
        other.submenu = sources
        otherItem = other
        otherMenu = sources
        menu.addItem(other)
        updateSourceRows()
        // Existing runtime failures remain actionable, rather than a fabricated success state.
        let problem = item(state.problem ?? "Audio Needs Attention…", .showProblem)
        problem.isHidden = state.problem == nil
        problemItem = problem
        menu.addItem(problem)
        menu.addItem(.separator())
        if openEditor != nil { menu.addItem(editorItem()) }
        let settings = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        settings.isEnabled = false
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = item("Quit TNF", .quit)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        rebuildFallbacks()
    }

    private func headerHeight(_ assignment: MenuSoundCard) -> CGFloat {
        MenuCardMetrics.headerHeight(enabled: assignment.isEnabled,
            choosing: state.interaction.choosing == assignment.id, blockCount: assignment.choices.count)
    }

    private func insertCard(_ assignment: MenuSoundCard, at index: Int) {
        let header = viewItem("header-\(assignment.id)", height: headerHeight(assignment),
            AnyView(MenuCardHeader(state: state, id: assignment.id)), at: index)
        headers[header] = assignment.id
        let controls = viewItem("controls-\(assignment.id)", height: controlsHeight(assignment),
            AnyView(MenuCardControls(state: state, id: assignment.id)), at: index + 1)
        let gap = viewItem("gap-\(assignment.id)", height: 10, AnyView(Color.clear.frame(height: 10)), at: index + 2)
        cards[assignment.id] = [header, controls, gap]
    }

    private func reconcileCards() {
        guard let otherItem else { return }
        let current = state.snapshot.assignments.filter { state.definition($0) != nil }
        let additions = MenuCardMetrics.additions(existing: Set(cards.keys), incoming: current.map(\.id))
        for id in additions {
            guard let assignment = current.first(where: { $0.id == id }) else { continue }
            insertCard(assignment, at: menu.index(of: otherItem))
        }
        let visible = Set(current.map(\.id))
        for (id, items) in cards {
            for item in items { item.isHidden = !visible.contains(id) }
        }
        resize()
    }

    private func toggle(_ bundle: String) {
        let assigned = Set(state.snapshot.assignments.map(\.bundleIdentifier))
        let change: MenuAppChange = assigned.contains(bundle) ? .remove : .add
        if state.snapshot.isLibrary {
            guard !state.libraryPending.contains(bundle) else { return }
            switch change {
            case .add: state.perform(.putOn(bundle))
            case .remove: state.perform(.selectBlock(nil, on: bundle))
            }
            return
        }
        guard state.interaction.begin(change, bundle: bundle, assigned: assigned),
              let pending = state.interaction.pendingChanges[bundle] else { return }
        updateSourceRows()
        dispatchingAppRequest = (bundle, change, pending.request.id)
        defer { dispatchingAppRequest = nil }
        switch change {
        case .add: state.perform(.putOn(bundle))
        case .remove: state.perform(.selectBlock(nil, on: bundle))
        }
    }

    private func updateSourceRows() {
        let assigned = Set(state.snapshot.assignments.map(\.bundleIdentifier))
        for (bundle, row) in sourceRows {
            let committed = assigned.contains(bundle)
            let pending = state.snapshot.isLibrary ? state.libraryPending.contains(bundle) : state.interaction.pendingApps.contains(bundle)
            row.enclosingMenuItem?.isEnabled = !pending
            row.update(committed: committed, pending: pending)
        }
    }

    private func controlsHeight(_ assignment: MenuSoundCard) -> CGFloat {
        guard assignment.isEnabled, let block = state.definition(assignment) else { return 0 }
        return MenuCardMetrics.controlsHeight(enabled: assignment.isEnabled,
            primary: block.controls.filter { $0.placement == .primary }.count,
            extra: block.controls.filter { $0.placement == .more }.count,
            expanded: state.more.contains(assignment.id)) + (assignment.heldHelp.isEmpty ? 0 : 22)
            + state.folds.visibleTabHeight(on: assignment, expanded: state.more.contains(assignment.id))
    }

    private func resize() {
        for assignment in state.snapshot.assignments {
            for (name, height) in [("header", headerHeight(assignment)), ("controls", controlsHeight(assignment))] {
                if let host = hosts["\(name)-\(assignment.id)"] {
                    let size = NSSize(width: 300, height: height)
                    if host.frame.size != size { host.setFrameSize(size) }
                }
            }
        }
    }

    private func editorItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open Editor", action: #selector(openEditorChosen), keyEquivalent: "")
        item.target = self; return item
    }

    public func perfBeginDrag() { state.beginGesture() }
    public func perfEndDrag() { state.endGesture() }
    public func perfMove(target: String, title: String, value: Double) -> Bool {
        guard let card = state.snapshot.assignments.first(where: { $0.bundleIdentifier == target }),
              let control = card.controls.first(where: { $0.title == title }), case .slider = control.face else { return false }
        state.move(control, on: card, to: value)
        return true
    }
    public func perfSelect(target: String, title: String, index: Int) -> Double? {
        guard let card = state.snapshot.assignments.first(where: { $0.bundleIdentifier == target }),
              let control = card.controls.first(where: { $0.title == title }), case .choice(let options) = control.face,
              options.indices.contains(index) else { return nil }
        state.activate(options[index], control: control, on: card)
        return options[index].position
    }
    @objc private func openEditorChosen() { openEditor?(nil) }

    private func rebuildFallbacks() {
        for (index, target) in [appMenu, dockMenu].enumerated() {
            target.removeAllItems()
            target.addItem(item(state.snapshot.isEnabled ? "Turn TNF Off" : "Turn TNF On",
                                .setEnabled(!state.snapshot.isEnabled)))
            _ = viewItem("fallback-compare-\(index)", height: 38,
                AnyView(HStack {
                    Text("Hold to hear original").font(.system(size: 13))
                    Spacer()
                    CompareButton(available: state.compareAvailable, comparing: state.comparing,
                                  cancelEpoch: state.interactionEpoch, change: { [weak self] in self?.holdOriginal($0) }).frame(width: 26, height: 26)
                }.padding(.horizontal, 14)), in: target)
            if let problem = state.problem { target.addItem(item(problem, .showProblem)) }
            target.addItem(.separator())
            if openEditor != nil { target.addItem(editorItem()) }
            let quit = item("Quit TNF", .quit)
            quit.keyEquivalent = "q"
            target.addItem(quit)
        }
    }
}

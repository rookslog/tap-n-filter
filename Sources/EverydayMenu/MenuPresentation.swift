import AppKit
import Combine
import SoundModel
import SwiftUI

public enum EverydayMenuAction: Sendable {
    case beginGesture
    case endGesture
    case setEnabled(Bool)
    case putOn(String)
    case selectBlock(UUID?, on: String)
    case setAppEnabled(UUID, Bool)
    case move(assignment: UUID, control: UUID, position: Double)
    case libraryPower(LibraryBinding, Bool)
    case libraryMove(LibraryBinding, LibraryControlAddress, LibraryPosition)
    case libraryOptionMove(LibraryBinding, LibraryControlAddress, LibraryOptionGesture, LibraryPosition)
    case menuMove(LibraryMenuIdentity, UInt64, LibraryControlAddress, LibraryOptionGesture?, LibraryPosition)
    case compare(Bool)
    case showProblem
    case refreshSources
    case quit
}

/// Available source metadata, independent of assignment order and sound activity.
@MainActor
public struct SourceAppInfo {
    public let bundleIdentifier: String
    public let name: String
    public let icon: NSImage?
    public let isSelectable: Bool

    public init(bundleIdentifier: String, name: String, icon: NSImage?, isSelectable: Bool = true) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.isSelectable = isSelectable
    }
}

/// Optional, caller-supplied before/after samples. The menu never produces audio or a clock.
public struct MenuLevelFrame: Equatable, Sendable {
    public let before: [Double]
    public let after: [Double]

    public init(before: [Double], after: [Double]) {
        self.before = before.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.after = after.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    }
}

enum MenuChoiceHighlight: Equatable {
    case block(UUID)
    case none
}

enum MenuAppChange: Equatable { case add, remove }

public enum MenuAppChangeFailure: Sendable {
    case reconciled
    case unresolved
}

public enum MenuSnapshotOrigin: Sendable {
    case cached
    case authoritative
}

enum MenuAppRequest {
    case inFlight(UUID)
    case completedUnknown(UUID)

    var id: UUID {
        switch self {
        case .inFlight(let id), .completedUnknown(let id): id
        }
    }
}

enum MenuAppRoster {
    static func bundles(_ sources: [(bundle: String, selectable: Bool)]) -> [String] {
        var seen: Set<String> = []
        return sources.compactMap { source in
            guard source.selectable, seen.insert(source.bundle).inserted else { return nil }
            return source.bundle
        }
    }
}

struct MenuInteractionState {
    var choosing: UUID?
    var hoveredPill: UUID?
    var hoveredChoice: MenuChoiceHighlight?
    private(set) var pendingChanges: [String: (change: MenuAppChange, request: MenuAppRequest)] = [:]
    var pendingApps: Set<String> { Set(pendingChanges.keys) }

    mutating func toggleChooser(_ id: UUID) { choosing = choosing == id ? nil : id; hoveredChoice = nil }

    mutating func retainCards(_ ids: Set<UUID>) {
        if let choosing, !ids.contains(choosing) { self.choosing = nil; hoveredChoice = nil }
        if let hoveredPill, !ids.contains(hoveredPill) { self.hoveredPill = nil }
    }

    mutating func begin(_ change: MenuAppChange, bundle: String, assigned: Set<String>) -> Bool {
        guard pendingChanges[bundle] == nil, assigned.contains(bundle) == (change == .remove) else { return false }
        pendingChanges[bundle] = (change, .inFlight(UUID()))
        return true
    }

    mutating func acknowledgeAuthoritative(_ assigned: Set<String>) {
        for (bundle, pending) in pendingChanges {
            if case .completedUnknown = pending.request { pendingChanges[bundle] = nil }
            else if assigned.contains(bundle) == (pending.change == .add) { pendingChanges[bundle] = nil }
        }
    }

    mutating func acknowledgeFailure(_ bundle: String, request: UUID, outcome: MenuAppChangeFailure) {
        guard var pending = pendingChanges[bundle], pending.request.id == request else { return }
        switch outcome {
        case .reconciled: pendingChanges[bundle] = nil
        case .unresolved:
            pending.request = .completedUnknown(request)
            pendingChanges[bundle] = pending
        }
    }

    mutating func reset() { choosing = nil; hoveredPill = nil; hoveredChoice = nil }
}

enum MenuCardMetrics {
    static let chooserRow: CGFloat = 24
    static let chooserDivider: CGFloat = 1
    static let chooserPadding: CGFloat = 4

    static func chooserHeight(blockCount: Int) -> CGFloat {
        CGFloat(blockCount + 1) * chooserRow + chooserDivider + chooserPadding * 2
    }

    static func headerHeight(enabled: Bool, choosing: Bool, blockCount: Int) -> CGFloat {
        (enabled ? 49 : 51) + (choosing ? chooserHeight(blockCount: blockCount) : 0)
    }

    static func controlsHeight(enabled: Bool, primary: Int, extra: Int, expanded: Bool) -> CGFloat {
        guard enabled else { return 0 }
        var heights: [CGFloat] = [28] + Array(repeating: 26, count: primary)
        if extra > 0 {
            heights.append(14)
            if expanded { heights += Array(repeating: 26, count: extra) }
        }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * 8 + 10
    }

    static func additions(existing: Set<UUID>, incoming: [UUID]) -> [UUID] {
        var seen = existing
        return incoming.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class MenuPresentation: ObservableObject {
    private var snapshotValue: MenuSoundData
    var snapshot: MenuSoundData {
        get { snapshotValue }
        set {
            objectWillChange.send()
            snapshotValue = newValue
            refreshPositions()
            var next = folds
            next.observe(snapshot)
            if next.entries != folds.entries { folds = next }
        }
    }
    var positionContext: MenuPositionContext? {
        didSet {
            if oldValue != positionContext {
                positionGeneration = positionContext?.generation ?? 0
                positionStateRevision = positionContext?.stateRevision ?? 0
            }
        }
    }
    private var rowPositions: [MenuRowPositionKey: MenuRowPosition] = [:]
    private var positionGeneration: UInt64 = 0
    private var positionStateRevision: UInt64 = 0
    func rowPosition(_ control: MenuSoundControl, on card: MenuSoundCard) -> MenuRowPosition {
        let key = MenuRowPositionKey(card: card, control: control)
        if let current = rowPositions[key] { return current }
        let current = MenuRowPosition(control.position); rowPositions[key] = current; return current
    }
    private func refreshPositions() {
        var keys: Set<MenuRowPositionKey> = []
        for card in snapshotValue.assignments {
            for control in card.controls + card.optionTabs.flatMap(\.controls) {
                let key = MenuRowPositionKey(card: card, control: control)
                keys.insert(key); rowPositions[key]?.update(control.position)
            }
        }
        rowPositions = rowPositions.filter { keys.contains($0.key) }
    }
    func applyPositions(_ delta: LibraryMenuDelta, context: MenuPositionContext) -> Bool {
        guard positionContext == context, context.ownerID == delta.identity.ownerID,
              context.identities.contains(delta.identity), delta.liveGeneration >= positionGeneration,
              delta.baseGeneration == positionGeneration, delta.baseStateRevision == positionStateRevision,
              let next = snapshotValue.applying(delta) else { return false }
        snapshotValue = next
        positionGeneration = delta.liveGeneration
        positionStateRevision = delta.stateRevision
        refreshPositions()
        return true
    }
    @Published var folds = MenuFoldState()
    @Published var apps: [SourceAppInfo] = []
    let visualization = MenuVisualizationPresentation()

    @Published var headHovered = false
    @Published var comparing = false
    @Published var compareAvailable = false
    @Published var problem: String?
    @Published var levels: [UUID: MenuLevelFrame] = [:]
    @Published var more: Set<UUID> = []
    @Published var interaction = MenuInteractionState()
    @Published var highlighted: UUID?
    @Published var keyboardInput = false
    @Published var interactionEpoch: UInt64 = 0
    let glyph: NSImage
    let perform: (EverydayMenuAction) -> Void
    var resize: (() -> Void)?
    private var gesturing = false

    func beginGesture() {
        guard !gesturing else { return }
        gesturing = true
        perform(.beginGesture)
    }

    func endGesture() {
        guard gesturing else { return }
        gesturing = false
        perform(.endGesture)
    }

    init(snapshot: ListeningSnapshot, glyph: NSImage, perform: @escaping (EverydayMenuAction) -> Void) {
        self.snapshotValue = MenuSoundData(legacy: snapshot)
        self.glyph = glyph
        self.perform = perform
        folds.observe(self.snapshot)
    }

    func source(_ bundle: String) -> SourceAppInfo {
        apps.first { $0.bundleIdentifier == bundle }
            ?? SourceAppInfo(bundleIdentifier: bundle, name: bundle, icon: nil)
    }

    init(snapshot: LibrarySnapshot, glyph: NSImage, perform: @escaping (EverydayMenuAction) -> Void) {
        self.snapshotValue = MenuSoundData(library: snapshot); self.glyph = glyph; self.perform = perform
        folds.observe(self.snapshot)
    }
    init(presentation: LibraryMenuState, glyph: NSImage, perform: @escaping (EverydayMenuAction) -> Void) {
        let context = MenuPositionContext(presentation: presentation, epoch: 0)
        snapshotValue = MenuSoundData(menu: presentation).contextualized(context); self.glyph = glyph; self.perform = perform
        positionContext = context
        positionGeneration = presentation.liveGeneration; positionStateRevision = presentation.stateRevision
        folds.observe(snapshotValue)
    }

    func definition(_ assignment: MenuSoundCard) -> MenuSoundCard? { assignment }
    var menuBlocks: [MenuSoundChoice] { snapshot.choices }
    var libraryPending: Set<String> = []

    func toggleChooser(_ id: UUID) {
        interaction.toggleChooser(id)
        resize?()
    }

    func chooseBlock(_ block: UUID?, on id: UUID) {
        interaction.choosing = nil
        interaction.hoveredChoice = nil
        resize?()
        guard let assignment = snapshot.assignments.first(where: { $0.id == id }),
              block != assignment.definitionID else { return }
        perform(.selectBlock(block, on: assignment.bundleIdentifier))
    }

    func move(_ control: MenuSoundControl, on assignment: MenuSoundCard, to value: Double) {
        if let action = assignment.movement(for: control, to: value) { perform(action) }
    }

    func tabIsOpen(_ tab: MenuSoundOptionTab, on card: MenuSoundCard) -> Bool {
        guard let key = card.foldKey(tab.parent) else { return false }
        return folds.isOpen(key, option: tab.option.id)
    }

    func activate(_ option: MenuSoundOption, control: MenuSoundControl, on card: MenuSoundCard) {
        switch folds.activate(option, control: control, on: card, current: snapshot) {
        case .none: break
        case .toggle: resize?()
        case .select(let value): move(control, on: card, to: value)
        }
    }

    func toggleMore(_ id: UUID) {
        if more.contains(id) { more.remove(id) } else { more.insert(id) }
        resize?()
    }
}

extension BuiltinBlock {
    var tint: Color {
        switch self {
        case .everyday: Color(red: 0x30 / 255.0, green: 0xB0 / 255.0, blue: 0xC7 / 255.0)
        case .filters: Color(red: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0)
        }
    }

    var symbol: String {
        switch self {
        case .everyday: "cup.and.saucer.fill"
        case .filters: "slider.horizontal.3"
        }
    }
}

/// Stable shipped control/option identity supplies decoration; display names remain model metadata.
func controlSymbol(_ control: UUID) -> String? {
    let id = control.uuid
    guard id.0 == 0x54, id.1 == 0x4E, id.2 == 0x46 else { return nil }
    switch (id.3, id.15) {
    case (1, 16): return "location"
    case (1, 17): return "hifispeaker"
    case (1, 18): return "speaker.wave.1"
    case (2, 16): return "chevron.left.to.line"
    case (2, 17): return "chevron.right.to.line"
    case (2, 18): return "water.waves"
    case (1, 19), (2, 19): return "speaker.wave.2"
    case (2, 20): return "square.resize"
    case (2, 21): return "rectangle.compress.vertical"
    default: return nil
    }
}

func optionSymbol(_ option: UUID) -> String? {
    let id = option.uuid
    guard id.0 == 0x54, id.1 == 0x4E, id.2 == 0x46, id.3 == 1 else { return nil }
    switch id.15 {
    case 64: return "figure.stand"
    case 65: return "door.left.hand.closed"
    case 66: return "square.split.bottomrightquarter"
    case 67: return "mountain.2"
    case 68: return "hifispeaker.2"
    case 69: return "tv"
    case 70: return "iphone"
    case 71: return "radio"
    default: return nil
    }
}

extension MenuDecoration {
    var tint: Color {
        switch self { case .builtin(let block): return block.tint; case .custom: return Color(nsColor: .systemPurple) }
    }
}

import AppKit
import Foundation
import SoundModel

/// Presentation-only values. Library cards never masquerade as a legacy builtin use.
public enum MenuDecoration: Equatable, Sendable {
    case builtin(BuiltinBlock)
    case custom(String)
}

public struct MenuSoundChoice: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let decoration: MenuDecoration
}

public struct MenuSoundOption: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let position: Double
}
public enum MenuSoundFace: Equatable, Sendable {
    case slider(String, String)
    case choice([MenuSoundOption])
    init(_ face: LibraryFace) {
        switch face {
        case .slider(let a, let b): self = .slider(a, b)
        case .choice(let options): self = .choice(options.map { MenuSoundOption(id: $0.id, title: $0.title, position: $0.position) })
        case .xy: preconditionFailure("XY is held, never a menu row")
        }
    }
}
public struct MenuSoundControl: Equatable, Sendable {
    public let address: LibraryControlAddress
    public var id: UUID { address.control }
    public let title: String
    public let face: MenuSoundFace
    public let placement: ListeningControlPlacement
    public let readout: ListeningReadout?
    public let position: Double
    public var optionGesture: LibraryOptionGesture? = nil
    public var optionChildren: [UUID: [String]] = [:]
}

public struct MenuSoundOptionTab: Equatable, Sendable {
    public let parent: LibraryControlAddress
    public let option: MenuSoundOption
    public let optionIndex: Int
    public let optionCount: Int
    public let controls: [MenuSoundControl]
    public var netHeight: Double { 30 + 26 * Double(max(0, controls.count - 1)) }
    /// Extra height a stacked row needs for its label line. Kept apart from `netHeight`, which stays
    /// 30 + 26 per extra row whatever the labels are.
    static let stackedExtra = 18.0
    var stackedHeight: Double { Self.stackedExtra * Double(controls.filter(stacksLabel).count) }

    /// Width the slider track would get if the row stayed on one line, from the card's fixed 300 pt layout:
    /// 216 pt of row (the tray's 236 less its 10 pt padding each side), less the readout (34), the option icon
    /// and the label at the row's own fonts, and three 10 pt gaps (icon to label, label to track, track to readout).
    /// It depends on the option and the row's title, not on the row's value, so it is measured once per
    /// option and title (see `MenuRowLabelCache`) and reused on every drag update.
    func oneLineTrackWidth(_ control: MenuSoundControl) -> Double {
        labelEntry(control).oneLineTrack
    }
    /// The option icon name and the one-line track width for this row, from the cache.
    func labelEntry(_ control: MenuSoundControl) -> MenuRowLabel {
        MenuRowLabelCache.shared.label(option: option.id, title: control.title)
    }
    /// The rule is: a tray row puts its label above the slider when its one-line track would lay out under
    /// 80 pt, the shortest tray track Everyday has. This estimate comes from measuring text and runs up to
    /// about 1 pt under the laid-out track (Room size: 79 estimated, 80 laid out), so the cut is 78: that
    /// keeps Everyday's 80 pt rows on one line. The render-index check holds the real 80 pt rule.
    static let stackingEstimateCut = 78.0
    func stacksLabel(_ control: MenuSoundControl) -> Bool { labelEntry(control).stacks }
}

/// What a tray row's label shows and takes up, which depends only on the option it sits under and its title.
struct MenuRowLabel: Sendable, Equatable {
    let symbol: String?
    let oneLineTrack: Double
    var stacks: Bool { oneLineTrack < MenuSoundOptionTab.stackingEstimateCut }
}

/// Seam for tests: how many tray-row label measurements and symbol lookups have really been done since the
/// process started. Never reset (the cache's `reset()` does not touch them); a test compares before and after.
enum MenuRowLayoutCounters {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var measurements = 0
        var lookups = 0
    }
    private static let storage = Storage()
    static var labelMeasurements: Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.measurements
    }
    static var symbolLookups: Int {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.lookups
    }
    fileprivate static func recordLabelMeasurement() {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.measurements += 1
    }
    fileprivate static func recordSymbolLookup() {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.lookups += 1
    }
}

/// Memo of `MenuRowLabel`, so dragging a tray slider never measures the label or looks up and configures
/// its symbol again. Only a miss measures; the counters (read and reset by tests) count misses.
final class MenuRowLabelCache: @unchecked Sendable {
    static let shared = MenuRowLabelCache()
    private struct Key: Hashable { let option: UUID; let title: String }
    private static let capacity = 512
    private let lock = NSLock()
    private var entries: [Key: MenuRowLabel] = [:]
    private var measured = 0
    private var looked = 0

    func label(option: UUID, title: String) -> MenuRowLabel {
        let key = Key(option: option, title: title)
        lock.lock(); defer { lock.unlock() }
        if let hit = entries[key] { return hit }
        let symbol = optionSymbol(option)
        looked += 1
        MenuRowLayoutCounters.recordSymbolLookup()
        let text = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width.rounded(.up)
        let icon = symbol.map { name -> Double in
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            return 10 + Double(image?.size.width ?? 14)
        } ?? 0
        measured += 1
        MenuRowLayoutCounters.recordLabelMeasurement()
        let made = MenuRowLabel(symbol: symbol, oneLineTrack: 216 - 34 - 10 - 10 - Double(text) - icon)
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = made
        return made
    }

    /// Seam for tests: label measurements and symbol lookups done since the last `reset()`.
    var counts: (measurements: Int, symbolLookups: Int) {
        lock.lock(); defer { lock.unlock() }
        return (measured, looked)
    }

    /// Seam for tests: forget every entry and zero the counters.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); measured = 0; looked = 0
    }
}

public struct MenuSoundCard: Equatable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    public let isEnabled: Bool
    public let definitionID: UUID?
    public let title: String
    public let nameHelp: String?
    public let block: MenuDecoration
    public let controls: [MenuSoundControl]
    public let heldNames: [String]
    public let heldHelp: [String]
    public let binding: LibraryBinding?
    public let choices: [MenuSoundChoice]
    public var optionTabs: [MenuSoundOptionTab] = []
    public var menuIdentity: LibraryMenuIdentity? = nil
    public var menuEpoch: UInt64? = nil

    public func movement(for control: MenuSoundControl, to value: Double) -> EverydayMenuAction? {
        guard (controls + optionTabs.flatMap(\.controls)).contains(where: { $0.address == control.address }) else { return nil }
        if let menuIdentity {
            guard let menuEpoch else { return nil }
            return .menuMove(menuIdentity, menuEpoch, control.address, control.optionGesture, .scalar(value))
        }
        if let binding {
            if let gesture = control.optionGesture { return .libraryOptionMove(binding, control.address, gesture, .scalar(value)) }
            return .libraryMove(binding, control.address, .scalar(value))
        }
        return .move(assignment: id, control: control.id, position: value)
    }
}

public struct MenuSoundData: Equatable, Sendable {
    public let isEnabled: Bool
    public let assignments: [MenuSoundCard]
    public let choices: [MenuSoundChoice]
    public let isLibrary: Bool
    init(isEnabled: Bool, assignments: [MenuSoundCard], choices: [MenuSoundChoice], isLibrary: Bool) {
        self.isEnabled = isEnabled; self.assignments = assignments; self.choices = choices; self.isLibrary = isLibrary
    }

    public init(legacy snapshot: ListeningSnapshot) {
        isEnabled = snapshot.isEnabled; isLibrary = false
        choices = snapshot.builtins.filter(\.inTheMenu).map {
            MenuSoundChoice(id: $0.id, title: $0.title, decoration: .builtin($0.kind))
        }
        let choices = choices
        assignments = snapshot.assignments.compactMap { assignment in
            guard let head = snapshot.builtins.first(where: { $0.id == assignment.definitionID }) else { return nil }
            let controls = head.controls.compactMap { metadata -> MenuSoundControl? in
                guard let position = assignment.controls.first(where: { $0.id == metadata.id })?.position else { return nil }
                let face: MenuSoundFace
                switch metadata.face {
                case .slider(let a, let b): face = .slider(a, b)
                case .choice(let options):
                    face = .choice(options.map { MenuSoundOption(id: $0.id, title: $0.title, position: $0.position) })
                }
                return MenuSoundControl(address: LibraryControlAddress(path: [], control: metadata.id), title: metadata.title,
                    face: face, placement: metadata.placement, readout: metadata.readout, position: position)
            }
            return MenuSoundCard(id: assignment.id, bundleIdentifier: assignment.bundleIdentifier,
                isEnabled: assignment.isEnabled, definitionID: assignment.definitionID, title: head.title,
                nameHelp: nil, block: .builtin(assignment.block), controls: controls, heldNames: [], heldHelp: [],
                binding: nil, choices: choices)
        }
    }

    public init(menu presentation: LibraryMenuState) {
        self.init(projection: MenuLibraryProjection(presentation))
    }
    public init(library snapshot: LibrarySnapshot) {
        self.init(projection: MenuLibraryProjection(snapshot))
    }

    public init(projection: MenuLibraryProjection) {
        isEnabled = projection.isEnabled; isLibrary = true
        func choice(_ head: LibraryDefinitionSummary) -> MenuSoundChoice {
            MenuSoundChoice(id: head.id, title: head.name,
                decoration: head.builtin.map(MenuDecoration.builtin) ?? .custom(String(head.name.prefix(1)).uppercased()))
        }
        choices = projection.choices.filter { $0.origin == "builtin" }.map(choice)
        let visible = choices
        assignments = projection.cards.map { card in
            let head = card.head
            let decoration = card.use?.builtin.map(MenuDecoration.builtin)
                ?? (card.use == nil ? head?.builtin.map(MenuDecoration.builtin) : nil)
                ?? .custom(String((head?.name ?? "").prefix(1)).uppercased())
            let choices = visible
            let relations = card.use?.optionControls ?? []
            let children = Set(relations.map(\.child))
            func row(_ control: MenuLibraryProjection.Control) -> MenuSoundControl? {
                guard control.isPositionedRow, case .scalar(let value) = control.position else { return nil }
                var result = MenuSoundControl(address: control.address, title: control.metadata.title, face: MenuSoundFace(control.metadata.face),
                    placement: control.metadata.placement, readout: control.metadata.readout, position: value)
                for relation in relations where relation.parent == control.address {
                    if let child = card.controls.first(where: { $0.address == relation.child }) {
                        result.optionChildren[relation.option, default: []].append(child.metadata.title)
                    }
                }
                return result
            }
            let controls = card.controls.compactMap(row)
            let tabs = controls.compactMap { parent -> MenuSoundOptionTab? in
                guard case .choice(let options) = parent.face,
                    let relation = relations.first(where: { $0.parent == parent.address && $0.isActive }),
                    let index = options.firstIndex(where: { $0.id == relation.option }) else { return nil }
                let owned = Set(relations.filter { $0.parent == parent.address && $0.option == relation.option }.map(\.child))
                let rows = controls.filter { owned.contains($0.address) }.map { control in
                    var control = control
                    control.optionGesture = LibraryOptionGesture(parent: parent.address, option: relation.option)
                    return control
                }
                return MenuSoundOptionTab(parent: parent.address, option: options[index], optionIndex: index,
                    optionCount: options.count, controls: rows)
            }

            return MenuSoundCard(id: card.binding.assignment, bundleIdentifier: card.binding.target,
                isEnabled: card.isEnabled, definitionID: card.definitionID,
                title: card.use?.name ?? head?.name ?? card.definitionID.uuidString,
                nameHelp: card.use?.hasOwnName == true ? head?.name : nil, block: decoration,
                controls: controls.filter { !children.contains($0.address) }, heldNames: card.heldNames,
                heldHelp: card.heldHelp, binding: card.binding, choices: choices, optionTabs: tabs,
                menuIdentity: projection.ownerID.flatMap { owner in card.use.map {
                    LibraryMenuIdentity(ownerID: owner, binding: card.binding,
                        reference: LibraryReference(definition: $0.definition, revision: $0.baseRevision))
                } })
        }
    }
}

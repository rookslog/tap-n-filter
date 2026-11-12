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

    public func movement(for control: MenuSoundControl, to value: Double) -> EverydayMenuAction? {
        guard (controls + optionTabs.flatMap(\.controls)).contains(where: { $0.address == control.address }) else { return nil }
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
                heldHelp: card.heldHelp, binding: card.binding, choices: choices, optionTabs: tabs)
        }
    }
}

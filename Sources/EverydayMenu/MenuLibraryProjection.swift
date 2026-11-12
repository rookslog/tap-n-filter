import Foundation
import SoundModel

/// Qualified library values and truthful presentation limitations for the quick menu.
public struct MenuLibraryProjection: Equatable, Sendable {
    public enum Limitation: Equatable, Sendable {
        case missingUse(UUID)
        case missingPosition(LibraryControlAddress)
        case missingDefault(LibraryControlAddress)
        case xy(LibraryControlAddress)
        case descendant(LibraryControlAddress)
    }
    public struct Control: Equatable, Sendable {
        public let address: LibraryControlAddress
        public let metadata: LibraryControl
        public let position: LibraryPosition?
        public let defaultPosition: LibraryPosition?
    }
    public struct Card: Equatable, Sendable {
        public let definitionID: UUID
        public let head: LibraryDefinitionSummary?
        public let heldNames: [String]
        public let heldHelp: [String]
        public let binding: LibraryBinding
        public let isEnabled: Bool
        public let use: LibraryUseSummary?
        public let controls: [Control]
        public let limitations: [Limitation]
    }
    public let choices: [LibraryDefinitionSummary]
    public let cards: [Card]
    public let isEnabled: Bool
    public init(_ snapshot: LibrarySnapshot) {
        isEnabled = snapshot.isEnabled
        choices = snapshot.definitions.filter(\.inTheMenu)
        cards = snapshot.assignments.map { assignment in
            let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
            guard let use = snapshot.uses.first(where: { $0.id == assignment.use && $0.target == assignment.target }) else {
                return Card(definitionID: assignment.definition, head: snapshot.definitions.first { $0.id == assignment.definition },
                            heldNames: [], heldHelp: ["Controls unavailable"], binding: binding, isEnabled: assignment.isEnabled, use: nil,
                            controls: [], limitations: [.missingUse(assignment.use)])
            }
            var limitations: [Limitation] = []
            func project(_ metadata: LibraryControl, path: [UUID], positions: [UUID: LibraryPosition]) -> Control {
                let address = LibraryControlAddress(path: path, control: metadata.id)
                let position = positions[metadata.id]
                let initial = use.defaults.first(where: { $0.path == path })?.positions[metadata.id]
                if position == nil { limitations.append(.missingPosition(address)) }
                if initial == nil { limitations.append(.missingDefault(address)) }
                if case .xy = metadata.face { limitations.append(.xy(address)) }
                if !path.isEmpty { limitations.append(.descendant(address)) }
                return Control(address: address, metadata: metadata, position: position, defaultPosition: initial)
            }
            var controls = use.controls.map { project($0, path: [], positions: use.positions) }
            for occurrence in use.occurrences where !occurrence.path.isEmpty {
                controls += occurrence.controls.map { project($0, path: occurrence.path, positions: occurrence.positions) }
            }
            var heldNames: [String] = [], heldHelp: [String] = []
            var seen: [LibraryControlAddress] = []
            controls = controls.filter { control in
                guard !seen.contains(control.address) else { return false }; seen.append(control.address); return true
            }
            for control in controls where !control.isPositionedRow {
                let occurrence = use.occurrences.first { $0.path == control.address.path }
                let child = occurrence.flatMap { occurrence in
                    snapshot.definitions.first { $0.id == occurrence.reference?.definition }?.name
                }
                let name = control.address.path.isEmpty ? control.metadata.title : child ?? control.metadata.title
                if !heldNames.contains(name) { heldNames.append(name) }
                let qualifier = child.map { "\($0) › \(control.metadata.title)" } ?? control.metadata.title
                let detail = control.metadata.face == .xy ? "\(qualifier) (pad)" : qualifier
                if !heldHelp.contains(detail) { heldHelp.append(detail) }
            }
            return Card(definitionID: assignment.definition, head: snapshot.definitions.first { $0.id == assignment.definition },
                        heldNames: heldNames, heldHelp: heldHelp, binding: binding, isEnabled: assignment.isEnabled, use: use,
                        controls: controls, limitations: limitations)
        }
    }
}

extension MenuLibraryProjection.Control {
    public var isPositionedRow: Bool {
        guard address.path.isEmpty, case .scalar(let value) = position,
              value.isFinite, (0...1).contains(value) else { return false }
        switch metadata.face { case .slider, .choice: return true; case .xy: return false }
    }
}

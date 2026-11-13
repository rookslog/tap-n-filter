import Foundation
import Combine
import SoundModel

public struct MenuPositionContext: Equatable, Sendable {
    public let ownerID: UUID
    public let epoch: UInt64
    public let generation: UInt64
    public let stateRevision: UInt64
    public let identities: [LibraryMenuIdentity]
    public init(presentation: LibraryMenuState, epoch: UInt64) {
        ownerID = presentation.ownerID; self.epoch = epoch
        generation = presentation.liveGeneration; stateRevision = presentation.stateRevision
        identities = presentation.assignments.compactMap {
            presentation.identity(for: LibraryBinding(assignment: $0.id, use: $0.use, target: $0.target))
        }
    }
}

@MainActor
final class MenuRowPosition: ObservableObject {
    @Published private(set) var value: Double
    init(_ value: Double) { self.value = value }
    func update(_ value: Double) { if self.value != value { self.value = value } }
}

struct MenuRowPositionKey: Hashable {
    let assignment: UUID
    let use: UUID?
    let address: LibraryControlAddress
    let option: UUID?
    let revision: UUID?
    init(card: MenuSoundCard, control: MenuSoundControl) {
        assignment = card.id; use = card.binding?.use; address = control.address; option = control.optionGesture?.option
        revision = card.menuIdentity?.reference.revision
    }
}

extension MenuSoundData {
    public func contextualized(_ context: MenuPositionContext) -> Self {
        Self(isEnabled: isEnabled, assignments: assignments.map { old in
            var card = old
            if let identity = card.menuIdentity, context.identities.contains(identity) { card.menuEpoch = context.epoch }
            else { card.menuEpoch = nil }
            return card
        }, choices: choices, isLibrary: isLibrary)
    }
    /// A position patch preserves metadata, layout, tabs and card identity; it does not reproject a library.
    public func applying(_ delta: LibraryMenuDelta) -> Self? {
        guard let index = assignments.firstIndex(where: { $0.binding == delta.identity.binding }),
              assignments[index].definitionID == delta.identity.reference.definition else { return nil }
        let values = delta.positions
        func patch(_ control: MenuSoundControl) -> MenuSoundControl {
            guard case .scalar(let value) = values[control.address] else { return control }
            return MenuSoundControl(address: control.address, title: control.title, face: control.face,
                placement: control.placement, readout: control.readout, position: value,
                optionGesture: control.optionGesture, optionChildren: control.optionChildren)
        }
        let old = assignments[index]
        var cards = assignments
        cards[index] = MenuSoundCard(id: old.id, bundleIdentifier: old.bundleIdentifier,
            isEnabled: old.isEnabled, definitionID: old.definitionID, title: old.title, nameHelp: old.nameHelp,
            block: old.block, controls: old.controls.map(patch), heldNames: old.heldNames, heldHelp: old.heldHelp,
            binding: old.binding, choices: old.choices, optionTabs: old.optionTabs.map {
                MenuSoundOptionTab(parent: $0.parent, option: $0.option, optionIndex: $0.optionIndex,
                    optionCount: $0.optionCount, controls: $0.controls.map(patch))
            }, menuIdentity: old.menuIdentity, menuEpoch: old.menuEpoch)
        return Self(isEnabled: isEnabled, assignments: cards, choices: choices, isLibrary: isLibrary)
    }
}

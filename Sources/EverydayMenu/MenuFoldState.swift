import Foundation
import SoundModel

struct MenuFoldKey: Hashable {
    let bundle: String
    let sound: UUID
    let parent: LibraryControlAddress
}

struct MenuFoldState {
    struct Entry: Equatable {
        let option: UUID
        var open: Bool
    }
    enum Activation: Equatable { case none, toggle, select(Double) }
    private(set) var entries: [MenuFoldKey: Entry] = [:]

    mutating func observe(_ key: MenuFoldKey, option: UUID) {
        if entries[key]?.option != option { entries[key] = Entry(option: option, open: false) }
    }

    func isOpen(_ key: MenuFoldKey, option: UUID) -> Bool {
        entries[key] == Entry(option: option, open: true)
    }

    mutating func activate(_ key: MenuFoldKey, effective: UUID, option: MenuSoundOption,
                           carriesChildren: Bool) -> Activation {
        observe(key, option: effective)
        guard option.id == effective else { return .select(option.position) }
        guard carriesChildren else { return .none }
        entries[key]?.open.toggle()
        return .toggle
    }

    mutating func observe(_ snapshot: MenuSoundData) {
        for card in snapshot.assignments {
            for control in card.controls {
                if let key = card.foldKey(control.address), let option = card.effectiveOption(control) {
                    observe(key, option: option.id)
                }
            }
        }
    }

    mutating func activate(_ option: MenuSoundOption, control: MenuSoundControl,
                           on card: MenuSoundCard, current snapshot: MenuSoundData) -> Activation {
        guard card.choiceIsCurrent(control, in: snapshot),
              case .choice(let options) = control.face, options.contains(option),
              let effective = card.effectiveOption(control), let key = card.foldKey(control.address) else { return .none }
        return activate(key, effective: effective.id, option: option,
                        carriesChildren: control.optionChildren[option.id]?.isEmpty == false)
    }

    func visibleTabHeight(on card: MenuSoundCard, expanded: Bool) -> Double {
        card.optionTabs.filter { tab in
            guard let key = card.foldKey(tab.parent), isOpen(key, option: tab.option.id) else { return false }
            return card.controls.contains { $0.address == tab.parent && ($0.placement == .primary || expanded) }
        }.reduce(0) { $0 + $1.netHeight + 8 }
    }
}

extension MenuSoundCard {
    func foldKey(_ parent: LibraryControlAddress) -> MenuFoldKey? {
        definitionID.map { MenuFoldKey(bundle: bundleIdentifier, sound: $0, parent: parent) }
    }

    func effectiveOption(_ control: MenuSoundControl) -> MenuSoundOption? {
        if let tab = optionTabs.first(where: { $0.parent == control.address }) { return tab.option }
        guard case .choice(let options) = control.face else { return nil }
        return options.min { abs($0.position - control.position) < abs($1.position - control.position) }
    }

    func choiceIsCurrent(_ control: MenuSoundControl, in snapshot: MenuSoundData) -> Bool {
        snapshot.assignments.contains { current in
            current.id == id && current.bundleIdentifier == bundleIdentifier
                && current.definitionID == definitionID && current.binding == binding
                && current.controls.contains(control) && current.optionTabs == optionTabs
        }
    }
}

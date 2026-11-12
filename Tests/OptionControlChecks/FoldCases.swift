import Foundation
@testable import EverydayMenu
@testable import SoundModel
import SessionStore

extension OptionControlChecks {
    static func folding(_ directory: URL) async throws {
        let f = OptionFixture()
        let file = directory.appendingPathComponent("fold-state.json")
        let store = LibrarySessionFile(url: file, maximumBytes: f.limits.maximumBytes)
        guard case .fresh(let session) = await SoundLibrarySession.open(persistence: store, limits: f.limits, builtins: .quickMenu) else {
            throw OptionCheckFailure.failed("fresh folding owner")
        }
        let quick = try QuickMenuEveryday()
        let everyday = quick.definition.id.rawValue
        for app in ["fold.a", "fold.b"] { _ = try await session.select(everyday, on: app) }
        let placeID = quick.definition.content.controls[0].id.rawValue
        let deviceID = quick.definition.content.controls[1].id.rawValue
        func card(_ data: MenuSoundData, _ app: String = "fold.a") -> MenuSoundCard {
            data.assignments.first { $0.bundleIdentifier == app }!
        }
        func parent(_ card: MenuSoundCard, _ id: UUID) -> MenuSoundControl { card.controls.first { $0.id == id }! }
        func options(_ control: MenuSoundControl) -> [MenuSoundOption] {
            guard case .choice(let options) = control.face else { return [] }
            return options
        }
        var data = MenuSoundData(library: try await session.snapshot())
        var folds = MenuFoldState()
        folds.observe(data)
        let initial = card(data), place = parent(initial, placeID), choices = options(place)
        try check(place.optionChildren.count == 3 && choices.filter { place.optionChildren[$0.id] == nil }.count == 1,
                  "every child-bearing option has relation-derived names; no mark for Here")
        try check(folds.visibleTabHeight(on: initial, expanded: false) == 0, "first effective option is collapsed")
        let selection = folds.activate(choices[2], control: place, on: initial, current: data)
        try check(selection == .select(choices[2].position), "different option produces one selection decision")
        var audioActions = 0
        if case .select(let position) = selection {
            guard case .libraryMove(let binding, let address, let value) = initial.movement(for: place, to: position) else {
                throw OptionCheckFailure.failed("parent action owner")
            }
            audioActions += 1
            _ = try await session.move(address, expected: binding, to: value)
        }
        data = MenuSoundData(library: try await session.snapshot())
        folds.observe(data)
        let selected = card(data), selectedPlace = parent(selected, placeID), tab = selected.optionTabs.first { $0.parent.control == placeID }!
        let key = selected.foldKey(selectedPlace.address)!
        try check(audioActions == 1 && !folds.isOpen(key, option: choices[2].id), "confirmed new option remains folded")
        _ = try await session.checkpoint()
        let beforeBytes = try Data(contentsOf: file)
        let before = try await session.snapshot()
        for expected in [true, false, true] {
            try check(folds.activate(choices[2], control: selectedPlace, on: selected, current: data) == .toggle,
                      "selected activation emits presentation toggle, not model action")
            try check(folds.isOpen(key, option: choices[2].id) == expected, "repeated selected activation toggles")
        }
        try check(try Data(contentsOf: file) == beforeBytes, "presentation-only actions never save")
        try check(folds.visibleTabHeight(on: selected, expanded: false) == 38 && tab.netHeight == 30,
                  "one open child adds exact 30 net plus existing8 gap")
        let multi = MenuSoundOptionTab(parent: tab.parent, option: tab.option, optionIndex: tab.optionIndex,
                                      optionCount: tab.optionCount, controls: tab.controls + tab.controls)
        try check(multi.netHeight == 56, "extra children add26 net")
        folds.observe(MenuSoundData(library: try await session.snapshot()))
        folds.observe(data)
        try check(folds.isOpen(key, option: choices[2].id), "unrelated snapshot and close/reopen retain open state")
        let other = card(data, "fold.b"), otherKey = other.foldKey(selectedPlace.address)!
        try check(!folds.isOpen(otherKey, option: choices[2].id), "apps have independent presentation entries")
        let device = parent(selected, deviceID), deviceOptions = options(device)
        let deviceKey = selected.foldKey(device.address)!
        _ = folds.activate(deviceKey, effective: deviceOptions[2].id, option: deviceOptions[2], carriesChildren: true)
        try check(folds.isOpen(key, option: choices[2].id) && folds.isOpen(deviceKey, option: deviceOptions[2].id),
                  "parents retain independent open state")
        let filters = data.choices.first { $0.id != everyday }!
        _ = try await session.select(filters.id, on: "fold.a")
        folds.observe(MenuSoundData(library: try await session.snapshot()))
        _ = try await session.select(everyday, on: "fold.a")
        let returned = MenuSoundData(library: try await session.snapshot())
        folds.observe(returned)
        try check(folds.isOpen(key, option: choices[2].id), "switching sounds and returning restores same effective option")
        let filterKey = MenuFoldKey(bundle: key.bundle, sound: filters.id, parent: key.parent)
        try check(!folds.isOpen(filterKey, option: choices[2].id), "sounds are independent")
        try check(folds.activate(choices[1], control: selectedPlace, on: selected, current: data) == .select(choices[1].position),
                  "refused owner selection does not eagerly replace effective choice")
        folds.observe(data)
        try check(folds.isOpen(key, option: choices[2].id), "owner refusal preserves confirmed selection and open state")
        try await session.move(placeID, on: "fold.a", to: .scalar(choices[1].position))
        let changed = MenuSoundData(library: try await session.snapshot())
        try check(folds.activate(choices[2], control: selectedPlace, on: selected, current: changed) == .none,
                  "stale rendered parent activation is refused before selection or toggle")
        folds.observe(changed)
        try check(!folds.isOpen(key, option: choices[1].id), "changed effective option folds")
        let changedCard = card(changed), changedParent = parent(changedCard, placeID)
        _ = folds.activate(choices[1], control: changedParent, on: changedCard, current: changed)
        _ = folds.activate(choices[1], control: changedParent, on: changedCard, current: changed)
        try check(folds.visibleTabHeight(on: changedCard, expanded: false) == 0,
                  "folded child contributes no tab row or gap")
        let childIDs = Set(quick.definition.content.optionControls.map { $0.child.rawValue })
        let after = try await session.snapshot()
        try check(before.uses.first { $0.target == "fold.a" }!.positions.filter { childIDs.contains($0.key) }
                  == after.uses.first { $0.target == "fold.a" }!.positions.filter { childIDs.contains($0.key) },
                  "folding and parent navigation leave exact hidden audio values unchanged")
        print("PASS production fold reducer, action decisions, coherent projection, exact heights and owned-store invariants")
    }
}

import AppKit
import Combine
@testable import EverydayMenu
import Foundation
import SessionStore
import SoundModel

extension OptionControlChecks {
    @MainActor static func menuPerformance(_ directory: URL) async throws {
        let f = OptionFixture()
        let store = LibrarySessionFile(url: directory.appendingPathComponent("menu-observation.json"), maximumBytes: f.limits.maximumBytes)
        guard case .fresh(let owner) = await SoundLibrarySession.open(persistence: store, limits: f.limits, builtins: .quickMenu) else {
            throw OptionCheckFailure.failed("fresh menu observation fixture")
        }
        let initial = try await owner.snapshot()
        _ = try await owner.select(initial.definitions.first { $0.builtin == .everyday }!.id, on: "fixture.menu")
        let snapshot = try await owner.snapshot()
        let state = MenuPresentation(snapshot: snapshot, glyph: NSImage(size: NSSize(width: 16, height: 16))) { _ in }
        guard case .choice(let options) = state.snapshot.assignments[0].controls[0].face else {
            throw OptionCheckFailure.failed("real option metadata")
        }
        var configuration = MenuChoiceConfiguration()
        let first = configuration.update(options, hints: [:])
        try check(first.count && first.order && first.content.count == options.count, "first native configuration plans all content")
        var unchangedWork = false
        for _ in 0..<100 {
            let unchanged = configuration.update(options, hints: [:])
            unchangedWork = unchangedWork || unchanged.count || unchanged.order || !unchanged.content.isEmpty || !unchanged.hints.isEmpty
        }
        try check(!unchangedWork, "unchanged native configuration plans no setters or resource replacement")
        let hint = configuration.update(options, hints: [options[2].id: "Show Room size"])
        try check(hint.content.isEmpty && hint.hints == [options[2].id], "hint-only change preserves segment content")
        var action = MenuChoiceAction()
        var oldCalls = 0, freshCalls = 0
        action.update(options) { _ in oldCalls += 1 }
        action.update(options) { option in if option.id == options[2].id { freshCalls += 1 } }
        action.activate(2)
        try check(oldCalls == 0 && freshCalls == 1, "unchanged configuration refreshes the actual production action closure")
        var broad = 0, visual = 0
        let broadObservation = state.objectWillChange.sink { broad += 1 }
        let visualObservation = state.visualization.objectWillChange.sink { visual += 1 }
        var demand: [MenuVisualizationMode?] = []
        state.visualization.demand = { demand.append($0) }
        state.visualization.frame = .live(MenuVisualizationFrame(sequence: 1, beforeWave: [], afterWave: [],
            beforeSpectrum: [], afterSpectrum: [], beforeRMSDBFS: -40, afterRMSDBFS: -40, held: false, silent: false))
        state.visualization.cycle()
        try check(demand.isEmpty, "hidden visualization mode does not request frames")
        state.visualization.visible = true
        state.visualization.cycle()
        try check(demand == [.levels] && broad == 0 && visual > 0, "visualization notifications stay isolated and mode demand is preserved")
        withExtendedLifetime((broadObservation, visualObservation)) {}
    }
}

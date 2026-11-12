import Foundation
@testable import SoundModel
import SessionStore
import EverydayMenu
import PlaybackRenderBridge

extension OptionControlChecks {
    static func quickMenu(_ directory: URL) async throws {
        let f = OptionFixture(), profiles = f.profiles
        let quick = try QuickMenuEveryday(), legacy = try Everyday()
        let payload = LibraryPayload(profile: LibraryProfiles.quickMenu, block: quick.definition.content,
            presentation: try profiles.presentation(for: quick.definition), canonicalVersion: 5)
        let old = LibraryPayload(profile: LibraryProfiles.everyday, block: legacy.definition.content,
            presentation: try profiles.presentation(for: legacy.definition), canonicalVersion: 1)
        let context = LibraryCompileContext(profiles: profiles, revisions: [:], limits: f.limits.expansion)
        try payload.validateCanonical()
        let children = quick.definition.content.optionControls
        try check(children.count == 5 && Set(children.map(\.child)).count == 5, "five stable distinct Everyday option children")
        let defaults = try children.map { relation in
            try quick.definition.content.controls.first { $0.id == relation.child }!.position(on: .value)
        }
        try check(defaults.allSatisfy { $0.value == 0.5 }, "all child default points are authored exactly at reference0.5")
        let place = quick.definition.content.controls[0], device = quick.definition.content.controls[1]
        var sweeps = 0
        for p in try place.waypoints.positions(on: .value) {
            for d in try device.waypoints.positions(on: .value) {
                let base: [OccurrenceControlKey: ControlValue] = [
                    OccurrenceControlKey(path: [], control: place.id): .scalar(p),
                    OccurrenceControlKey(path: [], control: device.id): .scalar(d)]
                let listening = UseListeningState(values: base)
                let q = try CompiledSound(payload: payload, root: quick.root, reference: nil, context: context, listening: listening)
                let l = try CompiledSound(payload: old, root: legacy.root, reference: nil, context: context, listening: listening)
                let native = try profiles.native(q), previous = try profiles.native(l)
                for (new, old) in zip(native, previous) {
                    let values = new.parameters.filter { $0.key != "roomSize" }
                    try check(values == old.parameters && (new.type == old.type || (new.type == "sizedReverb" && old.type == "reverb")),
                        "selected options preserve every legacy native value at neutral child defaults")
                }
                try RenderAssignmentMapper.admitParts(native)
                for child in children {
                    for endpoint in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        var values = base
                        values[OccurrenceControlKey(path: [], control: child.child)] = .scalar(try Position(endpoint))
                        let sound = try CompiledSound(payload: payload, root: quick.root, reference: nil, context: context,
                            listening: UseListeningState(values: values))
                        let parts = try profiles.native(sound)
                        try check(parts.flatMap(\.parameters).allSatisfy { $0.value.isFinite }, "authored control sweep remains finite")
                        try RenderAssignmentMapper.admitParts(parts)
                        sweeps += 1
                    }
                }
            }
        }
        print("PASS \(sweeps) authored child/choice sweeps admitted by real mapper/Core validator")
        let file = directory.appendingPathComponent("quick-menu.json")
        let store = LibrarySessionFile(url: file, maximumBytes: f.limits.maximumBytes)
        guard case .fresh(let session) = await SoundLibrarySession.open(persistence: store, limits: f.limits, builtins: .quickMenu) else {
            throw OptionCheckFailure.failed("fresh Quick Menu admission")
        }
        let initial = try await session.snapshot()
        try check(initial.definitions.map(\.name) == ["Everyday", "Filters"] && !initial.isEnabled, "QM-01a fresh roster and master OFF")
        let standard = try LibraryArchive.initial(profiles: profiles)
        let quickArchive = try LibraryArchive.initial(profiles: profiles, builtins: .quickMenu)
        try check(standard.revisions[1] == quickArchive.revisions[1], "Filters immutable revision and native profile unchanged")
        for app in ["quick.safari", "quick.iina"] { _ = try await session.select(quick.definition.id.rawValue, on: app) }
        let bindingSnapshot = try await session.snapshot()
        let assignment = bindingSnapshot.assignments.first { $0.target == "quick.safari" }!
        let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
        for (index, child) in children.enumerated() {
            let control = quick.definition.content.controls.first { $0.id == child.parentChoice }!
            guard case .choice(let choice) = control.face else { throw OptionCheckFailure.failed("parent choice") }
            try await session.move(child.parentChoice.rawValue, on: "quick.safari", to: .scalar(try choice.position(of: child.option).value))
            let snapshot = try await session.snapshot()
            let card = MenuSoundData(library: snapshot).assignments.first { $0.bundleIdentifier == "quick.safari" }!
            let row = card.optionTabs.first { $0.option.id == child.option.rawValue }!.controls[0]
            try check(card.controls.count == 4 && row.id == child.child.rawValue && row.optionGesture?.parent.control == child.parentChoice.rawValue,
                "real owner projection hides inactive children and binds child to owning option")
            guard case .libraryOptionMove(let captured, let address, let gesture, let value) = card.movement(for: row, to: 0.1 * Double(index + 1)) else {
                throw OptionCheckFailure.failed("visible child emits a real menu owner action")
            }
            try check(captured == binding && address == row.address && gesture == row.optionGesture!, "menu action carries the snapshot binding and exact option gesture")
            _ = try await session.move(address, expected: captured, optionGesture: gesture, to: value)
        }
        _ = try await session.checkpoint()
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: f.limits.maximumBytes), limits: f.limits)
        let snapshot = try await reopened.snapshot()
        let safari = snapshot.uses.first { $0.target == "quick.safari" }!, iina = snapshot.uses.first { $0.target == "quick.iina" }!
        for (index, child) in children.enumerated() {
            try check(safari.positions[child.child.rawValue] == .scalar(0.1 * Double(index + 1)) && iina.positions[child.child.rawValue] == .scalar(0.5),
                "Everyday per-app per-option values survive actual owned-file reopening")
        }
        let bytes = try Data(contentsOf: file)
        guard case .existing = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: file, maximumBytes: f.limits.maximumBytes), limits: f.limits, builtins: .quickMenu) else {
            throw OptionCheckFailure.failed("existing candidate reopening")
        }
        try check(try Data(contentsOf: file) == bytes, "fresh builtin selector never rewrites an existing destination")
    }
}

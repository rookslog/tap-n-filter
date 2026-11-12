import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct EverydayCases: Sendable {
    func test_frozen_older_builtin_retunes_keep_app_positions_power_and_identity() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/everyday-01.session.json")
        let old = try Data(contentsOf: fixture)
        let archive = try JSONDecoder().decode(SoundSessionArchive.self, from: old)
        let session = try await ListeningSession(savedData: old)
        let state = try await session.snapshot()
        let assignment = try requireValue(state.assignments.first)
        try requireEqual(state.isEnabled, true)
        try requireEqual(assignment.id, archive.assignments[0].assignment.id.rawValue)
        try requireEqual(assignment.isEnabled, false)
        try requireEqual(assignment.controls.map(\.position), [2.0 / 3.0, 1, 0.37, 0.8])
        let current = try Everyday()
        let saved = try JSONDecoder().decode(SoundSessionArchive.self, from: await session.savedData())
        try requireEqual(saved.definitions, [current.definition, try Filters().definition])
        let reopened = try await ListeningSession(savedData: session.savedData())
        try requireEqual(try await reopened.snapshot().assignments, state.assignments)
        try requireEqual(try await reopened.snapshot().isEnabled, state.isEnabled)
        try requireDifferent(saved.definitions[0].version, archive.definitions[0].version)
        try requireEqual(saved.assignments[0].positions.map(\.control), archive.assignments[0].positions.map(\.control))
        try requireEqual(saved.assignments[0].positions.map(\.value), archive.assignments[0].positions.map(\.value))
        try requireEqual(assignment.parts[1].parameters.first(where: { $0.key == "factoryPreset" })?.value,
                         BuiltinDistortionPreset.speechRadioTower.rawValue)
    }

    func test_choices_and_softer_compile_brief_endpoints_and_monotone_sweeps() async throws {
        let session = try await ListeningSession()
        try await session.putEveryday(on: "test.player")
        let seed = try await session.snapshot()
        let assignment = try requireValue(seed.assignments.first)
        let place = session.controls[0]
        let device = session.controls[1]
        let softer = session.controls[2]
        guard case .choice(let places) = place.face, case .choice(let devices) = device.face else {
            throw ContractFailure(description: "choice presentation missing")
        }
        let cutoffs = [20_000.0, 1200, 10_000, 6000]
        let levels = [0.0, -8, -6, -9]
        let wets = [0.0, 12, 8, 25]
        let rooms = [1.0, 1, 2, 3]
        let highPass = [20.0, 120, 180, 300]
        let lowPass = [20_000.0, 9500, 7500, 3400]
        func value(_ app: ListeningAssignment, _ type: String, _ key: String) throws -> Double {
            try requireValue(
                app.parts.first(where: { $0.type == type })?.parameters.first(where: { $0.key == key })?.value
            )
        }
        for p in places.indices {
            try await session.move(place.id, on: assignment.id, to: places[p].position)
            for d in devices.indices {
                try await session.move(device.id, on: assignment.id, to: devices[d].position)
                var priorCutoff = Double.infinity
                var priorGain = Double.infinity
                var priorThreshold = Double.infinity
                var priorHeadroom = Double.infinity
                for step in 0...100 {
                    let position = Double(step) / 100
                    try await session.move(softer.id, on: assignment.id, to: position)
                    let state = try await session.snapshot()
                    let app = try requireValue(state.assignments.first)
                    try requireEqual(app.parts.map(\.id), assignment.parts.map(\.id))
                    try requireEqual(
                        app.parts.map(\.type),
                        ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"])
                    try requireTrue(app.parts.allSatisfy { $0.parameters.allSatisfy { $0.value.isFinite } })
                    try requireEqual(try value(app, "deviceEQ", "highPassHz"), highPass[d], accuracy: 1e-8)
                    try requireEqual(try value(app, "deviceEQ", "lowPassHz"), lowPass[d], accuracy: 1e-8)
                    try requireEqual(
                        try value(app, "deviceColour", "wetPercent"), d == 3 ? 25 : 0, accuracy: 1e-8)
                    let cutoff = try value(app, "placeEQ", "lowPassHz")
                    let gain = try value(app, "gain", "gainDb")
                    let threshold = try value(app, "dynamics", "thresholdDb")
                    let headroom = try value(app, "dynamics", "headroomDb")
                    try requireEqual(cutoff, cutoffs[p] * pow(0.7, position), accuracy: 1e-8)
                    try requireEqual(gain, levels[p] - (d == 3 ? 2 : 0) - 2 * position, accuracy: 1e-8)
                    let expectedThreshold: Double
                    if position <= 0.25 { expectedThreshold = 20 - 30 * position / 0.25 }
                    else if position <= 0.5 { expectedThreshold = -10 - 10 * (position - 0.25) / 0.25 }
                    else { expectedThreshold = -20 - 10 * (position - 0.5) / 0.5 }
                    try requireEqual(threshold, expectedThreshold, accuracy: 1e-8)
                    try requireAtMost(cutoff, priorCutoff + 1e-8)
                    try requireAtMost(gain, priorGain + 1e-8)
                    try requireAtMost(threshold, priorThreshold + 1e-8)
                    try requireAtMost(headroom, priorHeadroom + 1e-8)
                    try requireAtMost(gain, 0)
                    try requireEqual(try value(app, "reverb", "wetPercent"), wets[p], accuracy: 1e-8)
                    try requireEqual(try value(app, "reverb", "roomPreset"), rooms[p], accuracy: 1e-8)
                    priorCutoff = cutoff
                    priorGain = gain
                    priorThreshold = threshold
                    priorHeadroom = headroom
                }
            }
        }
    }

    func test_facade_assignments_and_real_session_roundtrip_preserve_state() async throws {
        let session = try await ListeningSession()
        try requireEqual(try await session.snapshot().isEnabled, false)
        try requireEqual(session.controls.map(\.title), ["Place", "Device", "Softer", "Volume"])
        try await session.putEveryday(on: "test.first")
        try await session.putEveryday(on: "test.second")
        let assignment = try requireValue(try await session.snapshot().assignments.first)
        try await session.move(session.controls[2].id, on: assignment.id, to: 0.67)
        try await session.setEnabled(false, for: assignment.id)
        try await session.setEnabled(true)
        let before = try await session.snapshot()
        try await session.putEveryday(on: "test.first")
        try requireEqual(try await session.snapshot(), before)
        let data = try await session.savedData()
        let reopened = try await ListeningSession(savedData: data)
        let restored = try await reopened.snapshot()
        try requireEqual(reopened.controls, session.controls)
        try requireEqual(restored.isEnabled, true)
        try requireEqual(restored.assignments, before.assignments)
        try await requireAsyncThrows {
            try await session.move(session.controls[2].id, on: assignment.id, to: .nan)
        }
        try requireEqual(try await session.snapshot(), before)
        try await session.takeOff(assignment.id)
        try requireEqual(try await session.snapshot().assignments.count, 1)
        try requireEqual(try await reopened.snapshot().assignments.count, 2)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { try? await session.putEveryday(on: "test.third") } }
        }
        try requireEqual(
            try await session.snapshot().assignments.filter { $0.bundleIdentifier == "test.third" }.count, 1)
    }

    func test_power_is_not_history_or_gesture_state_and_legacy_archive_defaults_off() async throws {
        let everyday = try Everyday()
        let doc = try SoundDocument(catalog: everyday.catalog, historyLimit: UndoHistoryLimit(groups: 4))
        _ = try await doc.perform(.addDefinition(everyday.definition))
        _ = try await doc.perform(.instantiate(definition: everyday.definition.id, root: everyday.root))
        _ = try await doc.perform(.renameUse(root: everyday.root, name: "Desk"))
        _ = try await doc.perform(.undo)
        _ = try await doc.perform(.setEnabled(true))
        try requireEqual(await doc.snapshot().canRedo, true)
        _ = try await doc.perform(.redo)
        try requireEqual(await doc.snapshot().isEnabled, true)
        let gesture = GestureID()
        try await doc.beginGesture(gesture, context: .editing)
        _ = try await doc.perform(
            .moveControl(
                root: everyday.root,
                control: everyday.definition.content.controls[2].id, value: .scalar(.end), context: .editing),
            gesture: gesture)
        _ = try await doc.perform(.setEnabled(false))
        _ = try await doc.cancelGesture(gesture)
        try requireEqual(await doc.snapshot().isEnabled, false)
        _ = try await doc.perform(.setEnabled(true))
        let data = try await doc.sessionData()
        let fresh = try SoundDocument(catalog: everyday.catalog, historyLimit: UndoHistoryLimit(groups: 4))
        _ = try await fresh.restoreSession(data)
        try requireEqual(await fresh.snapshot().isEnabled, true)
        var legacy = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["isEnabled"] = nil
        _ = try await fresh.restoreSession(JSONSerialization.data(withJSONObject: legacy))
        try requireEqual(await fresh.snapshot().isEnabled, false)
    }
    func test_volume_combines_with_compensation_without_saturation() async throws {
        let session = try await ListeningSession()
        try await session.putEveryday(on: "test.volume")
        let initial = try await session.snapshot().assignments[0]
        let controls = session.controls
        try requireEqual(controls.map(\.title), ["Place", "Device", "Softer", "Volume"])
        try requireEqual(controls.map(\.placement), [.primary,.primary,.primary,.primary])
        try requireEqual(initial.controls[3].position, 0.8)
        try requireEqual(try controls[3].readout?.text(at: 0.8), "0 dB")
        guard case .choice(let places) = controls[0].face,
              case .choice(let devices) = controls[1].face else {
            throw ContractFailure(description: "Everyday choices")
        }
        let levels = [0.0,-8,-6,-9]
        var minimum = Double.infinity, maximum = -Double.infinity
        for p in places.indices {
            try await session.move(controls[0].id, on: initial.id, to: places[p].position)
            for d in devices.indices {
                try await session.move(controls[1].id, on: initial.id, to: devices[d].position)
                for step in 0...20 {
                    let softer = Double(step)/20
                    try await session.move(controls[2].id, on: initial.id, to: softer)
                    try await session.move(controls[3].id, on: initial.id, to: 0.8)
                    let neutral = try await session.snapshot().assignments[0]
                    let fixed = neutral.parts.filter { $0.type != "gain" }
                    for volume in [0.0,0.1,0.4,0.8,0.9,1] {
                        try await session.move(controls[3].id, on: initial.id, to: volume)
                        let app = try await session.snapshot().assignments[0]
                        let gain = try requireValue(app.parts.first { $0.type == "gain" }?.parameters.first { $0.key == "gainDb" }?.value)
                        try requireEqual(gain, levels[p] - (d == 3 ? 2 : 0) - 2*softer - 24 + 30*volume, accuracy: 1e-8)
                        try requireEqual(app.parts.filter { $0.type != "gain" }, fixed)
                        try requireEqual(app.parts.map(\.id), initial.parts.map(\.id))
                        try requireEqual(app.parts.count, 6)
                        minimum = min(minimum,gain);maximum = max(maximum,gain)
                    }
                }
            }
        }
        try requireEqual(minimum,-37,accuracy: 1e-8)
        try requireEqual(maximum,6,accuracy: 1e-8)
        let reopened = try await ListeningSession(savedData: session.savedData())
        try requireEqual(try await reopened.snapshot().assignments, try await session.snapshot().assignments)
    }

}

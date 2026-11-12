import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct BuiltinCases: Sendable {
    private func value(_ app: ListeningAssignment, _ type: String, _ key: String) throws -> Double {
        try requireValue(
            app.parts.first(where: { $0.type == type })?.parameters.first(where: { $0.key == key })?
                .value)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_real_blocks_metadata_labels_and_stable_identity() async throws {
        let a = try await ListeningSession()
        let b = try await ListeningSession()
        try requireEqual(a.builtins, b.builtins)
        try requireEqual(a.builtins.map(\.kind), [.everyday, .filters])
        try requireEqual(a.builtins.map(\.title), ["Everyday", "Filters"])
        try requireEqual(a.builtins.map(\.inTheMenu), [true, true])
        let archive = try JSONDecoder().decode(SoundSessionArchive.self, from: await a.savedData())
        try requireEqual(archive.definitions.count, 2)
        try requireEqual(Set(archive.uses.map(\.id)).count, 2)
        let allIDs =
            archive.definitions.flatMap { d in
                [d.id.rawValue, d.version.rawValue] + d.content.controls.map { $0.id.rawValue }
            } + archive.uses.map { $0.id.rawValue }
        try requireEqual(Set(allIDs).count, allIDs.count)
        guard case .choice(let devices) = a.controls[1].face else {
            throw ContractFailure(description: "Device choice")
        }
        try requireEqual(devices.map(\.title), ["Speakers", "TV", "Phone", "Radio"])
        let oldURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/everyday-01.session.json")
        let old = try JSONDecoder().decode(SoundSessionArchive.self, from: Data(contentsOf: oldURL))
        guard case .choice(let oldChoice) = old.definitions[0].content.controls[1].face else {
            throw ContractFailure(description: "frozen Device choice")
        }
        try requireEqual(devices.map(\.id), oldChoice.options.map(\.rawValue))
        try await a.putDefault(on: "test.default")
        try requireEqual(try await a.snapshot().assignments[0].block, .everyday)
        try requireEqual(
            a.builtins[1].controls.map(\.title),
            ["Low cut", "High cut", "Reverb", "Volume", "Room size", "Evener"])
        try requireEqual(
            a.builtins[1].controls.map(\.placement),
            [.primary, .primary, .primary, .primary, .more, .more])
    }

    func test_filters_defaults_endpoints_sweeps_and_readouts_match_native_targets() async throws {
        let session = try await ListeningSession()
        let filters = session.builtins[1]
        try await session.select(filters.id, on: "test.filters")
        var app = try await session.snapshot().assignments[0]
        try requireEqual(app.controls.map(\.position), [0, 0, 0, 0.8, 0.4, 0])
        try requireEqual(app.parts.map(\.type), ["deviceEQ", "reverb", "dynamics", "gain"])
        try requireEqual(try value(app, "gain", "gainDb"), 0, accuracy: 1e-10)
        try requireEqual(try value(app, "reverb", "roomPreset"), 2, accuracy: 1e-10)
        try requireEqual(try value(app, "dynamics", "thresholdDb"), 20, accuracy: 1e-10)
        try requireEqual(try value(app, "dynamics", "headroomDb"), 40, accuracy: 1e-10)
        let targets = [
            ("deviceEQ", "highPassHz"), ("deviceEQ", "lowPassHz"), ("reverb", "wetPercent"),
            ("gain", "gainDb"),
        ]
        for i in 0..<4 {
            let readout = try requireValue(filters.controls[i].readout)
            for step in 0...100 {
                let p = Double(step) / 100
                try await session.move(filters.controls[i].id, on: app.id, to: p)
                app = try await session.snapshot().assignments[0]
                try requireEqual(
                    try value(app, targets[i].0, targets[i].1), try readout.value(at: p),
                    accuracy: 1e-7)
            }
        }
        try requireEqual(try filters.controls[0].readout?.text(at: 0), "Off")
        try requireEqual(try filters.controls[1].readout?.value(at: 1), 100)
        try requireEqual(try filters.controls[2].readout?.text(at: 1), "50%")
        try requireEqual(try filters.controls[3].readout?.text(at: 1), "+6 dB")
        try requireEqual(try filters.controls[3].readout?.text(at: 0.8), "0 dB")
        for (p, expected) in [
            (0.0, 1.0), (0.249, 1), (0.25, 2), (0.4, 2), (0.749, 2), (0.75, 3), (1, 3),
        ] {
            try await session.move(filters.controls[4].id, on: app.id, to: p)
            try requireEqual(
                try value(try await session.snapshot().assignments[0], "reverb", "roomPreset"),
                expected, accuracy: 1e-9)
        }
        for (p, threshold, headroom) in [(0.0, 20.0, 40.0), (0.25, -18, 20), (0.5, -26, 12), (1, -32, 5)] {
            try await session.move(filters.controls[5].id, on: app.id, to: p)
            app = try await session.snapshot().assignments[0]
            try requireEqual(try value(app, "dynamics", "thresholdDb"), threshold, accuracy: 1e-9)
            try requireEqual(try value(app, "dynamics", "headroomDb"), headroom, accuracy: 1e-9)
        }
        try requireEqual(try filters.controls[4].readout?.text(at: 0.4), "40%")
        try requireEqual(try filters.controls[5].readout?.text(at: 1), "100%")
    }

    func test_selection_replacement_off_none_and_refusals_are_per_app_atomic() async throws {
        let s = try await ListeningSession()
        let everyday = s.builtins[0], filters = s.builtins[1]
        try await s.select(filters.id, on: "test.first")
        try await s.select(filters.id, on: "test.second")
        let initial = try await s.snapshot()
        let first = initial.assignments[0], second = initial.assignments[1]
        try requireEqual(first.parts, second.parts)
        try await s.move(filters.controls[3].id, on: first.id, to: 1)
        try await s.setEnabled(false, for: first.id)
        var state = try await s.snapshot()
        try requireEqual(state.assignments[1], second)
        try requireEqual(try value(state.assignments[0], "gain", "gainDb"), 6, accuracy: 1e-9)
        try requireEqual(state.assignments[0].controls[3].position, 1)
        try await s.select(filters.id, on: "test.first")
        try requireEqual(try await s.snapshot(), state)
        for bad in [Double.nan, .infinity, -0.01, 1.01] {
            try await requireAsyncThrows {
                try await s.move(filters.controls[3].id, on: first.id, to: bad)
            }
        }
        try await requireAsyncThrows { try await s.select(UUID(), on: "test.first") }
        try await requireAsyncThrows { try await s.select(everyday.id, on: "bad app") }
        try await requireAsyncThrows { try await s.move(UUID(), on: first.id, to: 0.5) }
        try requireEqual(try await s.snapshot(), state)
        try await s.select(everyday.id, on: "test.first")
        state = try await s.snapshot()
        try requireEqual(state.assignments[0].id, first.id)
        try requireEqual(state.assignments[0].isEnabled, false)
        try requireEqual(state.assignments[0].block, .everyday)
        try requireEqual(state.assignments[0].definitionID, everyday.id)
        try requireEqual(state.assignments[0].controls.map(\.position), [0, 0, 0, 0.8])
        try requireEqual(try value(state.assignments[0], "gain", "gainDb"), 0, accuracy: 1e-9)
        try requireEqual(state.assignments[1], second)
        try await s.select(filters.id, on: "test.first")
        try requireEqual(
            try await s.snapshot().assignments[0].controls.map(\.position), [0, 0, 0, 0.8, 0.4, 0])
        try await s.select(nil, on: "test.first")
        state = try await s.snapshot()
        try requireEqual(state.assignments, [second])
        try await s.select(nil, on: "test.first")
        try requireEqual(try await s.snapshot(), state)
        let reopened = try await ListeningSession(savedData: s.savedData())
        try requireEqual(try await reopened.snapshot().assignments, [second])
    }

    func test_real_legacy_option_reordering_uses_option_identity_not_label_or_position()
        async throws
    {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/everyday-01.session.json")
        var obj = try object(Data(contentsOf: fixture))
        var definitions = obj["definitions"] as! [[String: Any]]
        var content = definitions[0]["content"] as! [String: Any]
        var controls = content["controls"] as! [[String: Any]]
        let face = controls[1]["face"] as! [String: Any]
        let choice = face["choice"] as! [String: Any]
        let options = choice["_0"] as! [Any]
        controls[1]["face"] = ["choice": ["_0": Array(options.reversed())]]
        content["controls"] = controls
        definitions[0]["content"] = content
        obj["definitions"] = definitions
        let session = try await ListeningSession(
            savedData: JSONSerialization.data(withJSONObject: obj))
        let app = try await session.snapshot().assignments[0]
        // Frozen override1 now means the old first option, stable Speakers, not Radio.
        try requireEqual(app.controls[1].position, 0)
        try requireEqual(try value(app, "deviceColour", "wetPercent"), 0, accuracy: 1e-9)
        let reopened = try await ListeningSession(savedData: session.savedData())
        try requireEqual(try await reopened.snapshot().assignments, [app])
    }

    func test_two_builtin_restart_and_menu_defaults_are_definition_metadata() async throws {
        let s = try await ListeningSession()
        try await s.select(s.builtins[1].id, on: "test.filters")
        try await s.putEveryday(on: "test.everyday")
        let before = try await s.snapshot()
        try await s.move(s.builtins[1].controls[3].id, on: before.assignments[0].id, to: 1)
        try await s.move(s.controls[1].id, on: before.assignments[1].id, to: 1)
        try await s.setEnabled(true)
        let expected = try await s.snapshot()
        let reopened = try await ListeningSession(savedData: s.savedData())
        try requireEqual(try await reopened.snapshot().assignments, expected.assignments)
        try requireEqual(try await reopened.snapshot().builtins, expected.builtins)
        try requireEqual(try await reopened.snapshot().isEnabled, true)
        var obj = try object(await s.savedData())
        var definitions = try requireValue(obj["definitions"] as? [[String: Any]])
        definitions[0]["inTheMenu"] = false
        obj["definitions"] = definitions
        let filtersDefault = try await ListeningSession(
            savedData: JSONSerialization.data(withJSONObject: obj))
        try requireEqual(filtersDefault.builtins.map(\.inTheMenu), [false, true])
        try await filtersDefault.putDefault(on: "test.new")
        try requireEqual(try await filtersDefault.snapshot().assignments.last?.block, .filters)
        definitions[1]["inTheMenu"] = false
        obj["definitions"] = definitions
        let neither = try await ListeningSession(
            savedData: JSONSerialization.data(withJSONObject: obj))
        let snapshot = try await neither.snapshot()
        try await requireAsyncThrows { try await neither.putDefault(on: "test.new") }
        try requireEqual(try await neither.snapshot(), snapshot)
        let neitherReopened = try await ListeningSession(savedData: neither.savedData())
        try requireEqual(neitherReopened.builtins.map(\.inTheMenu), [false, false])
        definitions[0]["inTheMenu"] = nil
        definitions[1]["inTheMenu"] = nil
        obj["definitions"] = definitions
        let missing = try await ListeningSession(
            savedData: JSONSerialization.data(withJSONObject: obj))
        try requireEqual(missing.builtins.map(\.inTheMenu), [true, true])
    }

    func test_card_order_is_added_order_across_restart_replacement_off_and_none() async throws {
        let seed = try await ListeningSession()
        for app in ["test.zeta", "test.alpha", "test.mu"] { try await seed.putDefault(on: app) }
        var obj = try object(await seed.savedData())
        var assignments = try requireValue(obj["assignments"] as? [[String: Any]])
        let ids = [
            "FFFFFFFF-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000001",
            "88888888-0000-0000-0000-000000000002",
        ]
        for i in assignments.indices {
            var assignment = assignments[i]["assignment"] as! [String: Any]
            assignment["id"] = ["rawValue": ids[i]]
            assignments[i]["assignment"] = assignment
        }
        obj["assignments"] = assignments
        let session = try await ListeningSession(
            savedData: JSONSerialization.data(withJSONObject: obj))
        let first = try await session.snapshot().assignments[0]
        try requireEqual(try await session.snapshot().assignments.map { $0.id.uuidString }, ids)
        try await session.select(session.builtins[1].id, on: "test.zeta")
        try await session.setEnabled(false, for: first.id)
        try requireEqual(
            try await session.snapshot().assignments.map(\.bundleIdentifier),
            ["test.zeta", "test.alpha", "test.mu"])
        let reopened = try await ListeningSession(savedData: session.savedData())
        try requireEqual(try await reopened.snapshot().assignments.map { $0.id.uuidString }, ids)
        try await reopened.select(nil, on: "test.alpha")
        try await reopened.putDefault(on: "test.alpha")
        try await reopened.putDefault(on: "test.beta")
        let again = try await ListeningSession(savedData: reopened.savedData())
        try requireEqual(
            try await again.snapshot().assignments.map(\.bundleIdentifier),
            ["test.zeta", "test.mu", "test.alpha", "test.beta"])
    }

    func test_corrupt_foreign_duplicate_and_future_sessions_never_reset() async throws {
        let s = try await ListeningSession()
        try await s.putEveryday(on: "test.a")
        let original = try object(await s.savedData())
        func refused(_ edit: (inout [String: Any]) -> Void) async throws {
            var changed = original
            edit(&changed)
            let data = try JSONSerialization.data(withJSONObject: changed)
            try await requireAsyncThrows { try await ListeningSession(savedData: data) }
        }
        try await refused { $0["version"] = 2 }
        try await refused { $0["definitions"] = [] }
        for invalid: Any in [NSNull(), "yes", 1] {
            try await refused {
                var d = $0["definitions"] as! [[String: Any]]
                d[0]["inTheMenu"] = invalid
                $0["definitions"] = d
            }
        }
        try await refused {
            var d = $0["definitions"] as! [[String: Any]]
            d[1] = d[0]; $0["definitions"] = d
        }
        try await refused {
            var d = $0["definitions"] as! [[String: Any]]
            d[1]["id"] = UUID().uuidString; $0["definitions"] = d
        }
        try await refused {
            var u = $0["uses"] as! [[String: Any]]
            u[1] = u[0]; $0["uses"] = u
        }
        try await refused {
            var a = $0["assignments"] as! [Any]; a += a; $0["assignments"] = a
        }
        try await refused { $0["listening"] = [] }
        try await refused {
            var d = $0["definitions"] as! [[String: Any]]
            var content = d[0]["content"] as! [String: Any]
            content["pieces"] = []; d[0]["content"] = content; $0["definitions"] = d
        }
        // A healthy existing session is untouched by all separately refused imports.
        try requireEqual(try await s.snapshot().assignments.count, 1)
    }
    func test_v4_controls_migrate_hz_and_neutral_volume_idempotently() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controls-v4.session.json")
        let bytes = try Data(contentsOf: path)
        let old = try JSONDecoder().decode(SoundSessionArchive.self, from: bytes)
        let session = try await ListeningSession(savedData: bytes)
        let state = try await session.snapshot()
        try requireEqual(state.isEnabled, false)
        try requireEqual(state.assignments.map(\.id),old.assignments.map { $0.assignment.id.rawValue })
        try requireEqual(state.assignments.map(\.isEnabled),old.assignments.map { $0.assignment.isEnabled })
        let factor = log(1000.0/20000)/log(100.0/20000)
        for (i,p) in [1.0,0.5].enumerated() {
            try requireEqual(state.assignments[i].controls[1].position,p*factor,accuracy: 1e-12)
            try requireEqual(try value(state.assignments[i],"deviceEQ","lowPassHz"),20000*pow(0.05,p),accuracy: 1e-8)
        }
        let everyday = state.assignments[2]
        try requireEqual(everyday.controls.map(\.position),[1,1,0.67,0.8])
        try requireEqual(try value(everyday,"gain","gainDb"),-12.34,accuracy: 1e-8)
        let saved = try JSONDecoder().decode(SoundSessionArchive.self, from: await session.savedData())
        let filtersRoot = try Filters().root
        let rootPosition = saved.listening.first { $0.root == filtersRoot }?.positions.first?.value
        guard case .scalar(let rootPosition) = rootPosition else { throw ContractFailure(description: "root cutoff") }
        try requireEqual(rootPosition.value,0.5*factor,accuracy: 1e-12)
        var next = session
        for _ in 0..<2 {
            next = try await ListeningSession(savedData: next.savedData())
            try requireEqual(try await next.snapshot().assignments,state.assignments)
        }
        try requireEqual(try Data(contentsOf: path),bytes)
        for endpoint in [500.0,100.0] {
            var obj = try object(bytes)
            var definitions = obj["definitions"] as! [[String: Any]]
            var content = definitions[1]["content"] as! [String: Any]
            var mappings = content["mappings"] as! [[String: Any]]
            let domain = ParameterDomain.logarithmic(20,20000)
            let curve = try MappingCurve(waypoints: [Waypoint(position: .start,value: .end),
                Waypoint(position: .end,value: domain.position(endpoint))],shapes: [.straight])
            mappings[1]["curve"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(curve))
            content["mappings"] = mappings;definitions[1]["content"] = content;obj["definitions"] = definitions
            do {
                _ = try await ListeningSession(savedData: JSONSerialization.data(withJSONObject: obj))
                throw ContractFailure(description: "unknown v4 cutoff range accepted")
            } catch BuiltinMigrationError.unsupportedHighCutRange {}
        }
        var unknown = try object(bytes)
        var definitions = unknown["definitions"] as! [[String: Any]]
        let version = DefinitionVersionID(UUID(uuidString: "544E4602-0000-0000-0000-000000000007")!)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(version))
        definitions[1]["version"] = encoded;unknown["definitions"] = definitions
        var uses = unknown["uses"] as! [[String: Any]]
        var reference = uses[1]["definition"] as! [String: Any]
        reference["version"] = encoded;uses[1]["definition"] = reference;unknown["uses"] = uses
        do {
            _ = try await ListeningSession(savedData: JSONSerialization.data(withJSONObject: unknown))
            throw ContractFailure(description: "unknown Filters version accepted")
        } catch BuiltinMigrationError.unsupportedHighCutRange {}
    }

}

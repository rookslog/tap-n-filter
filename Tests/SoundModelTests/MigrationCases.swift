import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct MigrationCases: Sendable {
    private struct Fixture: Sendable {
        let root = RootUseID()
        let definition = DefinitionID()
        let choiceID = ControlID()
        let sliderID = ControlID()
        let xyID = ControlID()
        let options = (0..<4).map { _ in OptionID() }
        let part = PartID()
        let parameter: ParameterKey

        init() throws { parameter = try ParameterKey("gain") }

        var catalog: [PartDescriptor] {
            [PartDescriptor(type: "gain", parameters: [parameter])]
        }

        func block(
            options selected: [OptionID], defaultOption: OptionID? = nil,
            withoutSlider: Bool = false, withoutChoice: Bool = false,
            replacementFace: ControlFace? = nil
        ) throws -> BlockDefinition {
            let choice = try Choice(options: selected)
            var controls = [
                SoundControl(
                    id: choiceID, face: .choice(choice),
                    position: .scalar(try choice.position(of: defaultOption ?? selected[0])),
                    waypoints: .scalar(choice.positions)),
                SoundControl(
                    id: sliderID, face: .slider, position: .scalar(try Position(0.2)),
                    waypoints: .scalar([.start, .end])),
                SoundControl(
                    id: xyID, face: .xy, position: .xy(x: .start, y: .end),
                    waypoints: .xy(x: [.start, .end], y: [.start, .end])),
            ]
            if let replacementFace {
                controls[0] = SoundControl(
                    id: choiceID, face: replacementFace,
                    position: replacementFace == .xy ? .xy(x: .start, y: .end) : .scalar(.start),
                    waypoints: replacementFace == .xy
                        ? .xy(x: [.start, .end], y: [.start, .end]) : .scalar([.start, .end]))
            }
            if withoutSlider { controls.removeAll { $0.id == sliderID } }
            if withoutChoice { controls.removeAll { $0.id == choiceID } }
            let curve = try MappingCurve(
                waypoints: zip(choice.positions, selected).map { position, option in
                    Waypoint(position: position, value: try level(for: option))
                }, shapes: Array(repeating: .straight, count: selected.count - 1))
            let mappings: [ParameterMapping] =
                withoutChoice || replacementFace != nil
                ? []
                : [
                    ParameterMapping(
                        control: choiceID, axis: .value, part: part, parameter: parameter, curve: curve)
                ]
            return BlockDefinition(
                id: definition, version: DefinitionVersionID(), name: "Migration fixture",
                content: SoundBlock(
                    pieces: [
                        .part(
                            SoundPart(
                                id: part, type: "gain",
                                settings: [ParameterSetting(key: parameter, position: try Position(0.25))]))
                    ],
                    controls: controls, mappings: mappings))
        }

        func level(for option: OptionID) throws -> Position {
            let values = [0.0, 0.5, 1, 0.25]
            let index = try requireValue(options.firstIndex(of: option))
            return try Position(values[index])
        }

        func document() throws -> SoundDocument {
            try SoundDocument(catalog: catalog, historyLimit: UndoHistoryLimit(groups: 4))
        }

        func saved() async throws -> SoundSessionArchive {
            let doc = try document()
            let old = try block(options: Array(options.prefix(3)))
            _ = try await doc.perform(.addDefinition(old))
            _ = try await doc.perform(.instantiate(definition: old.id, root: root))
            _ = try await doc.perform(.renameUse(root: root, name: "Desk"))
            _ = try await doc.perform(.setEnabled(true))
            for (index, bundle) in ["test.first", "test.second"].enumerated() {
                _ = try await doc.perform(
                    .assign(
                        PlaybackAssignment(
                            id: AssignmentID(), root: root, app: ApplicationKey(bundle), isEnabled: index == 1
                        ),
                        initial: UseListeningState(positions: [
                            choiceID: .scalar(try Position(Double(index + 1) / 2)),
                            sliderID: .scalar(try Position(0.6 + Double(index) / 10)),
                            xyID: .xy(x: try Position(0.3), y: try Position(0.7)),
                        ])))
            }
            _ = try await doc.perform(
                .moveControl(
                    root: root, control: choiceID, value: .scalar(.start), context: .listening))
            _ = try await doc.perform(
                .moveControl(
                    root: root, control: sliderID, value: .scalar(try Position(0.8)), context: .listening))
            return try JSONDecoder().decode(SoundSessionArchive.self, from: await doc.sessionData())
        }

        func adopted(_ saved: SoundSessionArchive, to current: BlockDefinition) throws -> Data {
            try JSONEncoder().encode(SoundSessionArchive(adopting: current, root: root, from: saved))
        }

        func target() -> TargetAddress {
            TargetAddress(
                part: PartAddress(occurrence: Occurrence(root: root, path: []), part: part),
                parameter: parameter)
        }
    }

    func test_reorder_and_extension_preserve_independent_choices_and_restart() async throws {
        let f = try Fixture()
        let saved = try await f.saved()
        for options in [
            [f.options[2], f.options[0], f.options[1]],
            [f.options[3], f.options[2], f.options[1], f.options[0]],
        ] {
            let current = try f.block(options: options)
            let doc = try f.document()
            _ = try await doc.restoreSession(f.adopted(saved, to: current))
            let state = await doc.snapshot()
            try requireEqual(state.definitions, [current])
            try requireEqual(state.uses[0].name, .own("Desk"))
            try requireEqual(state.assignments, saved.assignments.map(\.assignment))
            try requireEqual(state.isEnabled, true)
            try requireEqual(try await doc.evaluate(root: f.root).sound.targets[f.target()], .start)
            let choice = try Choice(options: options)
            for index in saved.assignments.indices {
                let id = saved.assignments[index].assignment.id
                let listening = try requireValue(state.assignmentListening[id]?.positions)
                try requireEqual(
                    listening[f.choiceID], .scalar(try choice.position(of: f.options[index + 1])))
                try requireEqual(listening[f.sliderID], .scalar(try Position(0.6 + Double(index) / 10)))
                try requireEqual(listening[f.xyID], .xy(x: try Position(0.3), y: try Position(0.7)))
                try requireEqual(
                    try await doc.evaluate(assignment: id).sound.targets[f.target()],
                    try f.level(for: f.options[index + 1]))
            }
            try requireEqual(
                state.listening[f.root]?.positions[f.choiceID],
                .scalar(try choice.position(of: f.options[0])))
            try requireEqual(state.listening[f.root]?.positions[f.sliderID], .scalar(try Position(0.8)))
            let reopened = try JSONDecoder().decode(SoundSessionArchive.self, from: await doc.sessionData())
            let repeated = try await doc.restoreSession(f.adopted(reopened, to: current))
            try requireEqual(repeated.didChange, false)
            try requireEqual(await doc.snapshot(), state)
        }
    }

    func test_removed_selection_and_control_use_current_defaults() async throws {
        let f = try Fixture()
        let saved = try await f.saved()
        for withoutChoice in [false, true] {
            let current = try f.block(
                options: [f.options[0], f.options[2], f.options[3]], defaultOption: f.options[2],
                withoutSlider: true, withoutChoice: withoutChoice)
            let doc = try f.document()
            _ = try await doc.restoreSession(f.adopted(saved, to: current))
            let state = await doc.snapshot()
            try requireEqual(state.listening[f.root]?.positions[f.sliderID], nil)
            for assignment in state.assignments {
                try requireEqual(state.assignmentListening[assignment.id]?.positions[f.sliderID], nil)
            }
            let first = state.assignments[0].id
            try requireEqual(state.assignmentListening[first]?.positions[f.choiceID], nil)
            try requireEqual(
                try await doc.evaluate(assignment: first).sound.targets[f.target()],
                withoutChoice ? try Position(0.25) : .end)
            if withoutChoice {
                try requireEqual(state.listening[f.root]?.positions[f.choiceID], nil)
                try requireEqual(
                    state.assignmentListening[state.assignments[1].id]?.positions[f.choiceID], nil)
            }
            let reopened = try JSONDecoder().decode(SoundSessionArchive.self, from: await doc.sessionData())
            try requireEqual(try await doc.restoreSession(f.adopted(reopened, to: current)).didChange, false)
        }
    }

    func test_invalid_overrides_are_not_hidden_by_removal_or_remapping() async throws {
        let f = try Fixture()
        let saved = try await f.saved()
        let doc = try f.document()
        let baseline = await doc.snapshot()
        let invalid: [[SavedControlPosition]] = [
            [SavedControlPosition(control: f.choiceID, value: .scalar(try Position(0.37)))],
            [SavedControlPosition(control: f.choiceID, value: .xy(x: .start, y: .end))],
            [SavedControlPosition(control: ControlID(), value: .scalar(.start))],
            [SavedControlPosition(control: f.sliderID, value: .xy(x: .start, y: .end))],
            [
                SavedControlPosition(control: f.sliderID, value: .scalar(.start)),
                SavedControlPosition(control: f.sliderID, value: .scalar(.end)),
            ],
            [
                SavedControlPosition(control: f.choiceID, value: .scalar(.end)),
                SavedControlPosition(control: f.choiceID, value: .scalar(.end)),
            ],
        ]
        for options in [Array(f.options.prefix(3)), [f.options[0], f.options[2], f.options[3]]] {
            let current = try f.block(options: options, withoutSlider: true)
            for assignment in [false, true] {
                for values in invalid {
                    var object = try requireValue(
                        JSONSerialization.jsonObject(
                            with: JSONEncoder().encode(saved)) as? [String: Any])
                    let key = assignment ? "assignments" : "listening"
                    var records = try requireValue(object[key] as? [[String: Any]])
                    records[0]["positions"] = try JSONSerialization.jsonObject(
                        with: JSONEncoder().encode(values))
                    object[key] = records
                    let corrupt = try JSONDecoder().decode(
                        SoundSessionArchive.self, from: JSONSerialization.data(withJSONObject: object))
                    try await requireAsyncThrows {
                        try await doc.restoreSession(f.adopted(corrupt, to: current))
                    }
                    try requireEqual(await doc.snapshot(), baseline)
                }
            }
        }
    }

    func test_true_face_changes_and_wrong_builtin_identity_still_refuse() async throws {
        let f = try Fixture()
        let saved = try await f.saved()
        for face in [ControlFace.slider, .xy] {
            let current = try f.block(options: Array(f.options.prefix(3)), replacementFace: face)
            try requireThrows(SoundSessionArchive(adopting: current, root: f.root, from: saved)) { error in
                guard case ListeningSessionError.incompatibleBuiltin = error else { throw error }
            }
        }
        let current = try f.block(options: Array(f.options.prefix(3)))
        try requireThrows(SoundSessionArchive(adopting: current, root: RootUseID(), from: saved))
        let wrongBlock = BlockDefinition(
            id: DefinitionID(), version: current.version, name: current.name, content: current.content)
        try requireThrows(SoundSessionArchive(adopting: wrongBlock, root: f.root, from: saved))
    }
}

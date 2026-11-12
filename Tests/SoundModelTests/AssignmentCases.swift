import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct AssignmentCases: Sendable {
    private struct Fixture: Sendable {
        let root = RootUseID()
        let control = ControlID()
        let part = PartID()
        let parameter: ParameterKey
        let definition: BlockDefinition
        let catalog: [PartDescriptor]
        let first: PlaybackAssignment
        let second: PlaybackAssignment

        init() throws {
            parameter = try ParameterKey("gain")
            catalog = [PartDescriptor(type: "gain", parameters: [parameter])]
            let curve = try MappingCurve(
                waypoints: [
                    Waypoint(position: .start, value: .start),
                    Waypoint(position: .end, value: .end),
                ], shapes: [.straight])
            definition = BlockDefinition(
                id: DefinitionID(), version: DefinitionVersionID(), name: "Everyday",
                content: SoundBlock(
                    pieces: [
                        .part(
                            SoundPart(
                                id: part, type: "gain",
                                settings: [ParameterSetting(key: parameter, position: .start)]))
                    ],
                    controls: [
                        SoundControl(
                            id: control, face: .slider, position: .scalar(.start),
                            waypoints: .scalar([.start, .end]))
                    ],
                    mappings: [
                        ParameterMapping(
                            control: control, axis: .value, part: part, parameter: parameter, curve: curve)
                    ]))
            first = PlaybackAssignment(
                id: AssignmentID(), root: root, app: try ApplicationKey("test.first"), isEnabled: true)
            second = PlaybackAssignment(
                id: AssignmentID(), root: root, app: try ApplicationKey("test.second"), isEnabled: true)
        }

        func document() async throws -> SoundDocument {
            let result = try SoundDocument(catalog: catalog, historyLimit: UndoHistoryLimit(groups: 4))
            _ = try await result.perform(.addDefinition(definition))
            _ = try await result.perform(.instantiate(definition: definition.id, root: root))
            return result
        }

        func positions(_ number: Double) throws -> UseListeningState {
            UseListeningState(positions: [control: .scalar(try Position(number))])
        }
    }

    func test_two_apps_evaluate_independent_positions_without_touching_authored_state_or_history()
        async throws
    {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(.assign(f.first, initial: UseListeningState(positions: [:])))
        _ = try await document.perform(.assign(f.second, initial: UseListeningState(positions: [:])))
        _ = try await document.perform(.renameUse(root: f.root, name: "Work"))
        _ = try await document.perform(.undo)
        let before = await document.snapshot()
        for index in 1...20 {
            _ = try await document.perform(
                .moveAssignmentControl(
                    assignment: f.first.id, control: f.control, value: .scalar(Position(Double(index) / 20))))
        }
        _ = try await document.perform(
            .moveAssignmentControl(assignment: f.second.id, control: f.control, value: .scalar(Position(0.3)))
        )
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.control, value: .scalar(Position(0.8)), context: .listening)
        )
        let after = await document.snapshot()
        try requireEqual(after.definitions, before.definitions)
        try requireEqual(after.uses, before.uses)
        try requireEqual(after.canRedo, true)
        let first = try await document.evaluate(assignment: f.first.id)
        let second = try await document.evaluate(assignment: f.second.id)
        let address = TargetAddress(
            part: PartAddress(occurrence: Occurrence(root: f.root, path: []), part: f.part),
            parameter: f.parameter)
        try requireEqual(first.sound.targets[address], .end)
        try requireEqual(second.sound.targets[address], try Position(0.3))
        try requireEqual(first.revision, after.revision)
        _ = try await document.perform(.redo)
        try requireEqual(try await document.snapshot().name(of: f.root), "Work")
        try requireEqual(await document.snapshot().assignmentListening, after.assignmentListening)
    }

    func test_assignment_refusals_are_atomic_and_take_off_removes_only_its_listening() async throws {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(.assign(f.first, initial: f.positions(0.4)))
        let before = await document.snapshot()
        let collision = PlaybackAssignment(
            id: AssignmentID(), root: f.root, app: f.first.app, isEnabled: true)
        try await requireAsyncThrows {
            try await document.perform(.assign(collision, initial: UseListeningState(positions: [:])))
        }
        try await requireAsyncThrows {
            try await document.perform(
                .moveAssignmentControl(assignment: f.first.id, control: ControlID(), value: .scalar(.end)))
        }
        try await requireAsyncThrows {
            try await document.perform(
                .moveAssignmentControl(
                    assignment: f.first.id, control: f.control, value: .xy(x: .end, y: .end)))
        }
        try requireEqual(await document.snapshot(), before)
        _ = try await document.perform(.setAssignmentEnabled(f.first.id, false))
        try requireEqual(await document.snapshot().assignments.first?.isEnabled, false)
        try requireEqual(await document.snapshot().assignmentListening, before.assignmentListening)
        _ = try await document.perform(.unassign(f.first.id))
        try requireEqual(await document.snapshot().assignments, [])
        try requireEqual(await document.snapshot().assignmentListening, [:])
        try requireEqual(await document.snapshot().uses, before.uses)
        try requireThrows(ApplicationKey(" "))
        try requireThrows(ApplicationKey("test.\napp"))
    }

    func test_undo_creation_archives_assignments_but_redo_does_not_steal_a_rebound_app() async throws {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(.assign(f.first, initial: f.positions(0.6)))
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().assignments, [])
        try requireEqual(await document.snapshot().assignmentListening, [:])
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().assignments, [f.first])
        try requireEqual(await document.snapshot().assignmentListening[f.first.id], try f.positions(0.6))
        let otherRoot = RootUseID()
        _ = try await document.perform(.instantiate(definition: f.definition.id, root: otherRoot))
        let other = PlaybackAssignment(
            id: AssignmentID(), root: otherRoot, app: f.second.app, isEnabled: true)
        _ = try await document.perform(.assign(other, initial: f.positions(0.2)))
        _ = try await document.perform(.undo)
        let rebound = PlaybackAssignment(id: AssignmentID(), root: f.root, app: f.second.app, isEnabled: true)
        _ = try await document.perform(.assign(rebound, initial: f.positions(0.9)))
        _ = try await document.perform(.redo)
        let restored = await document.snapshot()
        try requireTrue(restored.uses.contains(where: { $0.id == otherRoot }))
        try requireTrue(restored.assignments.contains(rebound))
        try requireTrue(!restored.assignments.contains(other))
        try requireEqual(restored.assignmentListening[other.id], nil)
        _ = try await document.perform(.unassign(rebound.id))
        _ = try await document.perform(.undo)
        _ = try await document.perform(.redo)
        try requireTrue(
            !(await document.snapshot().assignments).contains(where: { $0.app == f.second.app }),
            "spent archived binding must not revive")
    }

    func test_session_roundtrip_is_real_document_data_and_invalid_restore_is_atomic() async throws {
        let f = try Fixture()
        let original = try await f.document()
        _ = try await original.perform(.assign(f.first, initial: f.positions(0.35)))
        _ = try await original.perform(.setAssignmentEnabled(f.first.id, false))
        _ = try await original.perform(.renameUse(root: f.root, name: "Desk"))
        let data = try await original.sessionData()
        let restored = try SoundDocument(catalog: f.catalog, historyLimit: UndoHistoryLimit(groups: 4))
        _ = try await restored.restoreSession(data)
        let snapshot = await restored.snapshot()
        let old = await original.snapshot()
        try requireEqual(snapshot.definitions, old.definitions)
        try requireEqual(snapshot.uses, old.uses)
        try requireEqual(snapshot.assignments, old.assignments)
        try requireEqual(snapshot.assignmentListening, old.assignmentListening)
        try requireEqual(snapshot.canUndo, false)
        try requireEqual(
            try await restored.evaluate(assignment: f.first.id).sound,
            try await original.evaluate(assignment: f.first.id).sound)
        let noChange = try await restored.restoreSession(data)
        try requireEqual(noChange.didChange, false)
        try requireEqual(await restored.snapshot(), snapshot)
        var object = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        try await requireAsyncThrows { try await restored.restoreSession(unsupported) }
        object["version"] = 1
        object["uses"] = []
        let orphaned = try JSONSerialization.data(withJSONObject: object)
        try await requireAsyncThrows { try await restored.restoreSession(orphaned) }
        try await requireAsyncThrows { try await restored.restoreSession(Data("{".utf8)) }
        var duplicated = try requireValue(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let assignments = try requireValue(duplicated["assignments"] as? [[String: Any]])
        duplicated["assignments"] = assignments + assignments
        let duplicateData = try JSONSerialization.data(withJSONObject: duplicated)
        try await requireAsyncThrows { try await restored.restoreSession(duplicateData) }
        try requireEqual(await restored.snapshot(), snapshot)
        for excluded in ["power", "pid", "audioProcessID", "canUndo", "sourceEpoch", "gesture"] {
            try requireTrue(!object.keys.contains(excluded))
        }
    }
}

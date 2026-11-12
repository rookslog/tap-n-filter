import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct SoundDocumentCases: Sendable {
    private struct Fixture: Sendable {
        let scalar = ControlID()
        let xy = ControlID()
        let first = RootUseID()
        let second = RootUseID()
        let x = try! ParameterKey("x")
        let y = try! ParameterKey("y")
        let definition: BlockDefinition
        var catalog: [PartDescriptor] { [PartDescriptor(type: "test", parameters: [x, y])] }

        init() throws {
            let part = SoundPart(
                id: PartID(), type: "test",
                settings: [
                    ParameterSetting(key: x, position: .start), ParameterSetting(key: y, position: .start),
                ])
            let curve = try MappingCurve(
                waypoints: [
                    Waypoint(position: .start, value: .start), Waypoint(position: .end, value: .end),
                ], shapes: [.straight])
            definition = BlockDefinition(
                id: DefinitionID(), version: DefinitionVersionID(), name: "Room",
                content: SoundBlock(
                    pieces: [.part(part)],
                    controls: [
                        SoundControl(
                            id: scalar, face: .slider, position: .scalar(.start),
                            waypoints: .scalar([.start, .end])),
                        SoundControl(
                            id: xy, face: .xy, position: .xy(x: .start, y: .start),
                            waypoints: .xy(x: [.start, .end], y: [.start, .end])),
                    ],
                    mappings: [
                        ParameterMapping(
                            control: scalar, axis: .value, part: part.id, parameter: x, curve: curve),
                        ParameterMapping(control: xy, axis: .x, part: part.id, parameter: x, curve: curve),
                        ParameterMapping(control: xy, axis: .y, part: part.id, parameter: y, curve: curve),
                    ]))
        }

        func document() async throws -> SoundDocument {
            let document = try SoundDocument(catalog: catalog, historyLimit: UndoHistoryLimit(groups: 64))
            _ = try await document.perform(.addDefinition(definition))
            _ = try await document.perform(.instantiate(definition: definition.id, root: first))
            _ = try await document.perform(.instantiate(definition: definition.id, root: second))
            return document
        }

        func target(_ evaluation: DocumentEvaluation, _ key: ParameterKey) throws -> Position {
            try requireValue(evaluation.sound.targets.first { $0.key.parameter == key }?.value)
        }
    }

    func test_uses_reference_one_definition_and_xy_commits_atomically() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let before = await document.snapshot()
        let moved = try await document.perform(
            .moveControl(
                root: f.first, control: f.xy,
                value: .xy(x: Position(0.2), y: Position(0.7)), context: .editing))
        try requireEqual(moved.revision, before.revision + 1)
        let evaluated = try await document.evaluate(root: f.first)
        try requireEqual(evaluated.revision, moved.revision)
        try requireEqual(try f.target(evaluated, f.x).value, 0.2, accuracy: 1e-12)
        try requireEqual(try f.target(evaluated, f.y).value, 0.7, accuracy: 1e-12)
        let other = try await document.evaluate(root: f.second)
        try requireEqual(try f.target(other, f.x), .start)
        try requireEqual(try f.target(other, f.y), .start)
        let after = await document.snapshot()
        try requireEqual(after.listening[f.first]?.positions[f.xy], .xy(x: Position(0.2), y: Position(0.7)))
        try requireEqual(after.definitions, [f.definition])
        try requireEqual(after.uses.map(\.definition), [f.definition.reference, f.definition.reference])
        try requireEqual(after.uses, before.uses)
        try requireEqual(after.listening[f.second]?.positions.count, 0)
    }

    func test_gesture_samples_undo_once_and_revisions_never_rewind() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let before = await document.snapshot()
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        for index in 1...20 {
            _ = try await document.perform(
                .moveControl(
                    root: f.first, control: f.scalar,
                    value: .scalar(Position(Double(index) / 20)), context: .editing), gesture: drag)
        }
        let ended = try await document.endGesture(drag)
        try requireEqual(ended.revision, before.revision + 20)
        let undone = try await document.perform(.undo)
        try requireEqual(undone.revision, ended.revision + 1)
        let restored = await document.snapshot()
        try requireEqual(restored.definitions, before.definitions)
        try requireEqual(restored.uses, before.uses)
        try requireEqual(restored.listening, before.listening)
        let redone = try await document.perform(.redo)
        try requireEqual(redone.revision, undone.revision + 1)
        try requireEqual(try f.target(await document.evaluate(root: f.first), f.x), .end)
    }

    func test_cancel_preserves_prior_redo_and_empty_gestures_do_not_commit() async throws {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(
            .moveControl(root: f.first, control: f.scalar, value: .scalar(Position(0.4)), context: .editing))
        _ = try await document.perform(.undo)
        let before = await document.snapshot()
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        let moved = try await document.perform(
            .moveControl(
                root: f.first, control: f.scalar,
                value: .scalar(Position(0.7)), context: .editing), gesture: drag)
        let cancelled = try await document.cancelGesture(drag)
        try requireEqual(cancelled.revision, moved.revision + 1)
        let after = await document.snapshot()
        try requireEqual(after.uses, before.uses)
        try requireEqual(after.listening, before.listening)
        try requireEqual(after.canRedo, true)
        let empty = GestureID()
        try await document.beginGesture(empty, context: .editing)
        _ = try await document.endGesture(empty)
        try requireEqual(await document.snapshot(), after)
        _ = try await document.perform(.redo)
        try requireEqual(
            try f.target(await document.evaluate(root: f.first), f.x).value, 0.4, accuracy: 1e-12)
    }

    func test_rename_collision_and_library_name_ownership_undo_together() async throws {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(.renameUse(root: f.first, name: "Closet"))
        _ = try await document.perform(.renameDefinition(f.definition.id, name: "Closet"))
        let closet = await document.snapshot()
        _ = try await document.perform(.renameDefinition(f.definition.id, name: "Hall"))
        let hall = await document.snapshot()
        try requireEqual(try hall.name(of: f.first), "Closet")
        try requireEqual(try hall.name(of: f.second), "Hall")
        _ = try await document.perform(.undo)
        let undone = await document.snapshot()
        try requireEqual(undone.definitions, closet.definitions)
        try requireEqual(undone.uses, closet.uses)
        _ = try await document.perform(.redo)
        _ = try await document.perform(.useLibraryName(f.first))
        let inherited = await document.snapshot()
        try requireEqual(try inherited.name(of: f.first), "Hall")
        try requireEqual(inherited.uses[0].name, .library)
        _ = try await document.perform(.undo)
        let owned = await document.snapshot()
        try requireEqual(owned.uses[0].name, .own("Closet"))
        try requireEqual(try owned.name(of: f.first), "Closet")
        _ = try await document.perform(.redo)
        try requireEqual(try await document.snapshot().name(of: f.first), "Hall")
    }

    func test_equal_values_still_own_state_and_noop_preserves_redo() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let first = try await document.perform(
            .moveControl(root: f.first, control: f.scalar, value: .scalar(.start), context: .editing))
        try requireEqual(first.didChange, true)
        let repeated = try await document.perform(
            .moveControl(root: f.first, control: f.scalar, value: .scalar(.start), context: .editing))
        try requireEqual(repeated.didChange, false)
        try requireEqual(repeated.revision, first.revision)
        _ = try await document.perform(.renameUse(root: f.first, name: "Room"))
        _ = try await document.perform(.renameDefinition(f.definition.id, name: "Hall"))
        let snapshot = await document.snapshot()
        try requireEqual(try snapshot.name(of: f.first), "Room")
        try requireEqual(snapshot.listening[f.first]?.positions[f.scalar], .scalar(.start))
        _ = try await document.perform(.undo)
        let beforeNoop = await document.snapshot()
        _ = try await document.perform(.renameUse(root: f.first, name: "Room"))
        try requireEqual(await document.snapshot(), beforeNoop)
        _ = try await document.perform(.redo)
        try requireEqual(try await document.snapshot().name(of: f.second), "Hall")
    }

    func test_refusals_are_atomic_and_gesture_boundaries_are_explicit() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let before = await document.snapshot()
        for command in [
            DocumentCommand.instantiate(definition: DefinitionID(), root: RootUseID()),
            .instantiate(definition: f.definition.id, root: f.first),
            .addDefinition(f.definition),
            .addDefinition(
                BlockDefinition(
                    id: DefinitionID(), version: f.definition.version,
                    name: "Duplicate version", content: f.definition.content)),
            .addDefinition(
                BlockDefinition(
                    id: DefinitionID(), version: DefinitionVersionID(),
                    name: "Invalid content",
                    content: SoundBlock(
                        pieces: [.part(SoundPart(id: PartID(), type: "test", settings: []))], controls: [],
                        mappings: []))),
            .renameDefinition(f.definition.id, name: "  \n"),
            .renameUse(root: RootUseID(), name: "Missing"),
            .moveControl(root: f.first, control: ControlID(), value: .scalar(.end), context: .editing),
            .moveControl(root: f.first, control: f.scalar, value: .xy(x: .start, y: .end), context: .editing),
            .moveControl(root: f.first, control: f.xy, value: .scalar(.end), context: .editing),
        ] {
            try await requireAsyncThrows { try await document.perform(command) }
            try requireEqual(await document.snapshot(), before)
        }
        try requireThrows(
            try SoundDocument(catalog: f.catalog + f.catalog, historyLimit: UndoHistoryLimit(groups: 64)))
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        let during = await document.snapshot()
        try await requireAsyncThrows { try await document.beginGesture(GestureID(), context: .editing) }
        try await requireAsyncThrows { try await document.perform(.undo) }
        try await requireAsyncThrows {
            try await document.perform(.renameUse(root: f.first, name: "No"), gesture: drag)
        }
        try await requireAsyncThrows {
            try await document.perform(
                .moveControl(root: f.first, control: f.scalar, value: .scalar(.end), context: .editing))
        }
        try await requireAsyncThrows { try await document.endGesture(GestureID()) }
        try requireEqual(await document.snapshot(), during)
        _ = try await document.cancelGesture(drag)
        try await requireAsyncThrows { try await document.beginGesture(drag, context: .editing) }
        try requireEqual(await document.snapshot(), before)
    }

    func test_undo_creation_never_leaves_orphan_references() async throws {
        let f = try Fixture()
        let document = try SoundDocument(catalog: f.catalog, historyLimit: UndoHistoryLimit(groups: 64))
        let empty = await document.snapshot()
        let noop = try await document.perform(.undo)
        try requireEqual(noop.didChange, false)
        try requireEqual(await document.snapshot(), empty)
        _ = try await document.perform(.addDefinition(f.definition))
        _ = try await document.perform(.instantiate(definition: f.definition.id, root: f.first))
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().uses.count, 0)
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().definitions.count, 0)
        _ = try await document.perform(.redo)
        _ = try await document.perform(.redo)
        let restored = await document.snapshot()
        try requireEqual(try restored.name(of: f.first), "Room")
        try requireEqual(restored.uses[0].definition, f.definition.reference)
        _ = try await document.evaluate(root: f.first)
    }

    func test_concurrent_commands_receive_unique_consecutive_revisions() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let before = await document.snapshot()
        let revisions = try await withThrowingTaskGroup(of: DocumentReceipt.self) { group in
            for index in 0..<32 {
                group.addTask {
                    try await document.perform(.renameDefinition(f.definition.id, name: "Room \(index)"))
                }
            }
            var revisions: [UInt64] = []
            for try await result in group { revisions.append(result.revision) }
            return revisions.sorted()
        }
        try requireEqual(revisions, (1...32).map { before.revision + UInt64($0) })
        let after = await document.snapshot()
        try requireEqual(after.revision, before.revision + 32)
        try requireEqual(try after.name(of: f.first), after.name(of: f.second))
        try requireTrue((0..<32).map { "Room \($0)" }.contains(try after.name(of: f.first)))
    }
}

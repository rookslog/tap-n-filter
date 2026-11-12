import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct ListeningStateCases: Sendable {
    private struct Fixture: Sendable {
        let control = ControlID()
        let first = RootUseID()
        let second = RootUseID()
        let parameter = try! ParameterKey("gain")
        let definition: BlockDefinition
        var catalog: [PartDescriptor] { [PartDescriptor(type: "test", parameters: [parameter])] }

        init() throws {
            let part = SoundPart(
                id: PartID(), type: "test", settings: [ParameterSetting(key: parameter, position: .start)])
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
                            id: control, face: .slider, position: .scalar(.start),
                            waypoints: .scalar([.start, .end]))
                    ],
                    mappings: [
                        ParameterMapping(
                            control: control, axis: .value, part: part.id, parameter: parameter, curve: curve)
                    ]))
        }

        func document() async throws -> SoundDocument {
            let document = try SoundDocument(catalog: catalog, historyLimit: UndoHistoryLimit(groups: 64))
            _ = try await document.perform(.addDefinition(definition))
            _ = try await document.perform(.instantiate(definition: definition.id, root: first))
            return document
        }

        func target(_ document: SoundDocument, root: RootUseID) async throws -> Position {
            let evaluation = try await document.evaluate(root: root)
            return try requireValue(evaluation.sound.targets.first { $0.key.parameter == parameter }?.value)
        }
    }

    func test_listening_moves_leave_authored_blocks_and_uses_unchanged() async throws {
        let f = try Fixture()
        let document = try await f.document()
        _ = try await document.perform(.instantiate(definition: f.definition.id, root: f.second))
        let before = await document.snapshot()
        _ = try await document.perform(
            .moveControl(root: f.first, control: f.control, value: .scalar(.end), context: .editing))
        let after = await document.snapshot()
        try requireEqual(after.definitions, before.definitions)
        try requireEqual(after.uses, before.uses)
        try requireEqual(after.listening[f.first]?.positions[f.control], .scalar(.end))
        try requireEqual(after.listening[f.second], before.listening[f.second])
        try requireEqual(try await f.target(document, root: f.first), .end)
        try requireEqual(try await f.target(document, root: f.second), .start)
        _ = try await document.perform(.renameUse(root: f.first, name: "Closet"))
        _ = try await document.perform(.renameDefinition(f.definition.id, name: "Hall"))
        let renamed = await document.snapshot()
        try requireEqual(renamed.listening, after.listening)
        try requireEqual(try renamed.name(of: f.first), "Closet")
        try requireEqual(try renamed.name(of: f.second), "Hall")
    }

    func test_new_uses_undo_redo_and_cancel_keep_listening_state_local() async throws {
        let f = try Fixture()
        let document = try await f.document()
        let initial = await document.snapshot()
        _ = try await document.perform(
            .moveControl(root: f.first, control: f.control, value: .scalar(.end), context: .editing))
        let moved = await document.snapshot()
        _ = try await document.perform(.instantiate(definition: f.definition.id, root: f.second))
        try requireEqual(try await f.target(document, root: f.second), .start)
        try requireEqual(try await f.target(document, root: f.first), .end)
        _ = try await document.perform(.undo)
        let removed = await document.snapshot()
        try requireEqual(removed.uses, moved.uses)
        try requireEqual(removed.listening, moved.listening)
        try requireEqual(removed.listening[f.second], nil)
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().listening, initial.listening)
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening, moved.listening)
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        _ = try await document.perform(
            .moveControl(root: f.first, control: f.control, value: .scalar(.start), context: .editing),
            gesture: drag)
        _ = try await document.cancelGesture(drag)
        let cancelled = await document.snapshot()
        try requireEqual(cancelled.definitions, moved.definitions)
        try requireEqual(cancelled.uses, moved.uses)
        try requireEqual(cancelled.listening, moved.listening)
        try requireEqual(cancelled.canRedo, true)
        _ = try await document.perform(.redo)
        try requireEqual(try await f.target(document, root: f.second), .start)
        try requireEqual(try await f.target(document, root: f.first), .end)
    }
}

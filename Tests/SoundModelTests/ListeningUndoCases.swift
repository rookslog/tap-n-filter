import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct ListeningUndoCases: Sendable {
    private struct Fixture: Sendable {
        let first = ControlID()
        let second = ControlID()
        let root = RootUseID()
        let definition: BlockDefinition

        init() {
            definition = BlockDefinition(
                id: DefinitionID(), version: DefinitionVersionID(), name: "Room",
                content: SoundBlock(
                    pieces: [],
                    controls: [first, second].map {
                        SoundControl(
                            id: $0, face: .slider, position: .scalar(.start),
                            waypoints: .scalar([.start, .end]))
                    }, mappings: []))
        }

        func document() async throws -> SoundDocument {
            let document = try SoundDocument(catalog: [], historyLimit: UndoHistoryLimit(groups: 2))
            _ = try await document.perform(.addDefinition(definition))
            _ = try await document.perform(.instantiate(definition: definition.id, root: root))
            return document
        }
    }

    func test_playing_does_not_evict_edits_and_undo_keeps_current_positions() async throws {
        let f = Fixture()
        let document = try await f.document()
        _ = try await document.perform(.renameUse(root: f.root, name: "Closet"))
        for index in 1...50 {
            _ = try await document.perform(
                .moveControl(
                    root: f.root, control: f.first, value: .scalar(Position(Double(index) / 50)),
                    context: .listening))
        }
        _ = try await document.perform(.undo)
        let undone = await document.snapshot()
        try requireEqual(try undone.name(of: f.root), "Room")
        try requireEqual(undone.listening[f.root]?.positions[f.first], .scalar(.end))
    }

    func test_playing_preserves_redo_and_root_lifecycle_restores_latest_listening() async throws {
        let f = Fixture()
        let document = try await f.document()
        _ = try await document.perform(.renameDefinition(f.definition.id, name: "Closet"))
        _ = try await document.perform(.undo)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.6)), context: .listening))
        let drag = GestureID()
        try await document.beginGesture(drag, context: .listening)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.second, value: .scalar(.end), context: .listening),
            gesture: drag)
        _ = try await document.endGesture(drag)
        let played = await document.snapshot()
        try requireEqual(played.canRedo, true)
        _ = try await document.perform(.redo)
        try requireEqual(try await document.snapshot().name(of: f.root), "Closet")
        try requireEqual(await document.snapshot().listening, played.listening)
        _ = try await document.perform(.undo)
        try requireEqual(try await document.snapshot().name(of: f.root), "Room")
        try requireEqual(await document.snapshot().listening, played.listening)
        let cancelled = GestureID()
        try await document.beginGesture(cancelled, context: .listening)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(.end), context: .listening),
            gesture: cancelled)
        _ = try await document.cancelGesture(cancelled)
        try requireEqual(await document.snapshot().listening, played.listening)
        try requireEqual(await document.snapshot().canRedo, true)
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().listening[f.root], nil)
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening, played.listening)
    }

    func test_edit_drag_undo_and_redo_touch_only_edited_controls() async throws {
        let f = Fixture()
        let document = try await f.document()
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        for index in 1...20 {
            _ = try await document.perform(
                .moveControl(
                    root: f.root, control: f.first, value: .scalar(Position(Double(index) / 25)),
                    context: .editing),
                gesture: drag)
        }
        _ = try await document.endGesture(drag)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.3)), context: .listening))
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.second, value: .scalar(Position(0.7)), context: .listening))
        _ = try await document.perform(.undo)
        let undone = await document.snapshot()
        try requireEqual(undone.listening[f.root]?.positions[f.first], .scalar(try Position(0.3)))
        try requireEqual(undone.listening[f.root]?.positions[f.second], .scalar(try Position(0.7)))
        _ = try await document.perform(.redo)
        let redone = await document.snapshot()
        try requireEqual(redone.listening[f.root]?.positions[f.first], .scalar(try Position(0.3)))
        try requireEqual(redone.listening[f.root]?.positions[f.second], .scalar(try Position(0.7)))
        _ = try await document.perform(.undo)
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().uses.count, 0)
    }

    func test_context_mismatch_is_atomic_and_history_only_undo_keeps_revision() async throws {
        let f = Fixture()
        let document = try await f.document()
        let drag = GestureID()
        try await document.beginGesture(drag, context: .listening)
        let before = await document.snapshot()
        do {
            _ = try await document.perform(
                .moveControl(root: f.root, control: f.first, value: .scalar(.end), context: .editing),
                gesture: drag)
            throw ContractFailure(description: "mixed gesture contexts accepted")
        } catch let error as DocumentError {
            try requireEqual(error, .gestureContextMismatch(expected: .listening, received: .editing))
        }
        try requireEqual(await document.snapshot(), before)
        _ = try await document.cancelGesture(drag)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(.start), context: .listening))
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(.end), context: .editing))
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(.start), context: .listening))
        let played = await document.snapshot()
        let undone = try await document.perform(.undo)
        try requireEqual(undone.didChange, false)
        try requireEqual(undone.revision, played.revision)
        try requireEqual(await document.snapshot().canRedo, true)
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening[f.root]?.positions[f.first], .scalar(.start))
    }

    func test_skipped_controls_do_not_reappear_when_redo_matches_an_old_value() async throws {
        let f = Fixture()
        let document = try await f.document()
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.2)), context: .listening))
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.8)), context: .editing),
            gesture: drag)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.second, value: .scalar(.end), context: .editing),
            gesture: drag)
        _ = try await document.endGesture(drag)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.3)), context: .listening))
        _ = try await document.perform(.undo)
        let undone = await document.snapshot()
        try requireEqual(undone.listening[f.root]?.positions[f.first], .scalar(try Position(0.3)))
        try requireEqual(undone.listening[f.root]?.positions[f.second], nil)
        _ = try await document.perform(
            .moveControl(root: f.root, control: f.first, value: .scalar(Position(0.2)), context: .listening))
        _ = try await document.perform(.redo)
        let redone = await document.snapshot()
        try requireEqual(redone.listening[f.root]?.positions[f.first], .scalar(try Position(0.2)))
        try requireEqual(redone.listening[f.root]?.positions[f.second], .scalar(.end))
    }
}

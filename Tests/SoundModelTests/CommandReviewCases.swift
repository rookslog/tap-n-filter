import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct CommandReviewCases: Sendable {
    private func historyDocument(limit: Int) async throws -> (
        document: SoundDocument, root: RootUseID, control: ControlID
    ) {
        let control = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.start),
            waypoints: .scalar([.start, .end]))
        let definition = BlockDefinition(
            id: DefinitionID(), version: DefinitionVersionID(), name: "Room",
            content: SoundBlock(pieces: [], controls: [control], mappings: []))
        let root = RootUseID()
        let document = try SoundDocument(catalog: [], historyLimit: UndoHistoryLimit(groups: limit))
        _ = try await document.perform(.addDefinition(definition))
        _ = try await document.perform(.instantiate(definition: definition.id, root: root))
        return (document, root, control.id)
    }

    func test_repeated_choice_moves_within_one_option_preserve_history_and_revision() async throws {
        let choice = try Choice(options: [OptionID(), OptionID(), OptionID()])
        let control = SoundControl(
            id: ControlID(), face: .choice(choice), position: .scalar(try Position(0.49)),
            waypoints: .scalar(choice.positions))
        let definition = BlockDefinition(
            id: DefinitionID(), version: DefinitionVersionID(), name: "Door",
            content: SoundBlock(pieces: [], controls: [control], mappings: []))
        let root = RootUseID()
        let document = try SoundDocument(catalog: [], historyLimit: UndoHistoryLimit(groups: 64))
        _ = try await document.perform(.addDefinition(definition))
        _ = try await document.perform(.instantiate(definition: definition.id, root: root))
        let first = try await document.perform(
            .moveControl(root: root, control: control.id, value: .scalar(Position(0.49)), context: .editing))
        let repeated = try await document.perform(
            .moveControl(root: root, control: control.id, value: .scalar(Position(0.51)), context: .editing))
        try requireEqual(repeated.didChange, false)
        try requireEqual(repeated.revision, first.revision)
        let stored = await document.snapshot()
        try requireEqual(stored.listening[root]?.positions[control.id], .scalar(try Position(0.5)))
        _ = try await document.perform(
            .moveControl(root: root, control: control.id, value: .scalar(.end), context: .editing))
        _ = try await document.perform(.undo)
        let beforeNoop = await document.snapshot()
        _ = try await document.perform(
            .moveControl(root: root, control: control.id, value: .scalar(Position(0.49)), context: .editing))
        try requireEqual(await document.snapshot(), beforeNoop)
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening[root]?.positions[control.id], .scalar(.end))
    }

    func test_history_limits_keep_only_the_newest_completed_groups() async throws {
        for limit in [1, 2, 4] {
            let (document, root, _) = try await historyDocument(limit: limit)
            for index in 1...(limit + 2) {
                _ = try await document.perform(.renameUse(root: root, name: "Room \(index)"))
            }
            for _ in 0..<limit { _ = try await document.perform(.undo) }
            let oldest = await document.snapshot()
            try requireEqual(try oldest.name(of: root), "Room 2")
            try requireEqual(oldest.canUndo, false)
            try requireEqual(try await document.perform(.undo).didChange, false)
            try requireEqual(await document.snapshot(), oldest)
            for _ in 0..<limit { _ = try await document.perform(.redo) }
            let newest = await document.snapshot()
            try requireEqual(try newest.name(of: root), "Room \(limit + 2)")
            try requireEqual(newest.canRedo, false)
            try requireEqual(try await document.perform(.redo).didChange, false)
            try requireEqual(await document.snapshot(), newest)
            _ = try await document.evaluate(root: root)
        }
    }

    func test_history_limit_counts_a_gesture_once_and_cancel_keeps_redo() async throws {
        let (document, root, control) = try await historyDocument(limit: 2)
        for name in ["One", "Two", "Three"] {
            _ = try await document.perform(.renameUse(root: root, name: name))
        }
        let drag = GestureID()
        try await document.beginGesture(drag, context: .editing)
        for index in 1...20 {
            _ = try await document.perform(
                .moveControl(
                    root: root, control: control,
                    value: .scalar(Position(Double(index) / 20)), context: .editing), gesture: drag)
        }
        _ = try await document.endGesture(drag)
        _ = try await document.perform(.undo)
        let beforeCancel = await document.snapshot()
        try requireEqual(beforeCancel.listening[root]?.positions.count, 0)
        try requireEqual(try beforeCancel.name(of: root), "Three")
        let cancelled = GestureID()
        try await document.beginGesture(cancelled, context: .editing)
        _ = try await document.perform(
            .moveControl(
                root: root, control: control,
                value: .scalar(Position(0.3)), context: .editing), gesture: cancelled)
        _ = try await document.cancelGesture(cancelled)
        let afterCancel = await document.snapshot()
        try requireEqual(afterCancel.uses, beforeCancel.uses)
        try requireEqual(afterCancel.listening, beforeCancel.listening)
        try requireEqual(afterCancel.canRedo, true)
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening[root]?.positions[control], .scalar(.end))
        _ = try await document.perform(.undo)
        _ = try await document.perform(.undo)
        let oldest = await document.snapshot()
        try requireEqual(try oldest.name(of: root), "Two")
        try requireEqual(oldest.canUndo, false)
    }

    func test_history_limit_rejects_zero_and_negative_counts() throws {
        for count in [0, -1, Int.min] {
            try requireThrows(try UndoHistoryLimit(groups: count)) { error in
                try requireEqual(error as? DocumentError, .invalidHistoryLimit(count))
            }
        }
    }
}

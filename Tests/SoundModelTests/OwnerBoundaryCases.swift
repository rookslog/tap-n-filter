import Foundation
@testable import SoundModel

private actor OwnerMemory: LibraryPersistence {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    func load() -> Data? { bytes }
    func commit(_ data: Data) -> LibraryWriteOutcome { .committed }
}

struct OwnerBoundaryCases {
    func test_untouched_gesture_retains_child_and_redo() async throws { try await checkGesture(returning: false) }
    func test_returned_gesture_retains_child_and_redo() async throws { try await checkGesture(returning: true) }
    private func checkGesture(returning: Bool) async throws {
        let profiles = try LibraryProfiles()
        let expansion = try LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128)
        let limits = try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128, expansion: expansion)
        var archive = try LibraryArchive.initial(profiles: profiles)
        let leaf = archive.revisions.first { $0.definition.name == "Filters" }!
        let childControl = leaf.payload.block.controls[3].id
        let control = ControlID(), site = UseSiteID(), root = RootUseID(), target = try ApplicationKey("test.root-history")
        let block = SoundBlock(pieces: [.reference(ReferencedBlockUse(site: site, definition: leaf.definition.reference))],
            controls: [SoundControl(id: control, face: .slider, position: .scalar(.start), waypoints: .scalar([.start, .end]))], mappings: [])
        let face = LibraryControl(id: control.rawValue, title: "Root", face: .slider("A", "B"), placement: .primary, readout: nil)
        let payload = LibraryPayload(profile: LibraryProfiles.filters, block: block, presentation: [face], canonicalVersion: 2)
        let definition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: "History", content: block)
        archive.revisions.append(try LibraryRevision(definition: definition, origin: "custom", payload: payload, contentHash: payload.contentHash))
        archive.heads.append(LibraryDefinitionRecord(archive.revisions.last!))
        let use = RootSoundUse(id: root, definition: definition.reference, name: .library)
        archive.uses = [LibraryOwnedUse(target: target, use: use, draft: nil, positions: [])]
        archive.assignments = [PlaybackAssignment(id: AssignmentID(), root: root, app: target, isEnabled: true)]
        let (content, metadata) = try archive.validated(profiles: profiles, limits: limits)
        let doc = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 8))
        await doc.openLibrary(content: content, metadata: metadata, enabled: false, profiles: profiles,
                              persistence: OwnerMemory(try archive.encoded(limits: limits)), limits: limits, committed: nil)
        try await doc.libraryMove(target: target, control: control, value: .scalar(Position(0.2)))
        _ = try await doc.perform(.moveControl(root: root, control: control, value: .scalar(Position(0.6)), context: .editing))
        _ = try await doc.perform(.undo)
        let before = await doc.snapshot()
        try requireTrue(before.canRedo && !before.canUndo)
        let gesture = GestureID(); try await doc.beginGesture(gesture, context: .editing)
        if returning {
            _ = try await doc.perform(.moveControl(root: root, control: control, value: .scalar(Position(0.9)), context: .editing), gesture: gesture)
            _ = try await doc.perform(.moveControl(root: root, control: control, value: .scalar(Position(0.2)), context: .editing), gesture: gesture)
        }
        let key = OccurrenceControlKey(path: [site], control: childControl)
        try await doc.libraryMove(target: target, key: key, value: .scalar(Position(0.8)))
        _ = try await doc.endGesture(gesture)
        let after = await doc.snapshot()
        try requireTrue(!after.canUndo && after.canRedo, "empty scoped gesture keeps exact history flags")
        try requireEqual(after.listening[root]?.values[key], .scalar(Position(0.8)))
        _ = try await doc.perform(.redo)
        try requireEqual(await doc.snapshot().listening[root]?.positions[control], .scalar(Position(0.6)))
        try requireEqual(await doc.snapshot().listening[root]?.values[key], .scalar(Position(0.8)))
        _ = try await doc.perform(.undo)
        try requireEqual(await doc.snapshot().listening[root]?.positions[control], .scalar(Position(0.2)))
        try requireEqual(await doc.snapshot().listening[root]?.values[key], .scalar(Position(0.8)))
    }
    func test_library_export_refuses_and_legacy_stays() async throws {
        let profiles = try LibraryProfiles()
        let limits = try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
        var archive = try LibraryArchive.initial(profiles: profiles)
        let record = archive.revisions.first { $0.definition.name == "Filters" }!
        let root = RootUseID(), target = try ApplicationKey("test.legacy-export"), binding = AssignmentID()
        let use = RootSoundUse(id: root, definition: record.definition.reference, name: .library)
        archive.uses = [LibraryOwnedUse(target: target, use: use, draft: nil, positions: [])]
        archive.assignments = [PlaybackAssignment(id: binding, root: root, app: target, isEnabled: true)]
        let (content, metadata) = try archive.validated(profiles: profiles, limits: limits)
        let doc = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 8))
        await doc.openLibrary(content: content, metadata: metadata, enabled: false, profiles: profiles,
                              persistence: OwnerMemory(try archive.encoded(limits: limits)), limits: limits, committed: nil)
        let control = record.payload.block.controls[3].id
        try await doc.libraryMove(target: target, control: control, value: .scalar(Position(0.2)))
        let before = await doc.snapshot()
        do { _ = try await doc.sessionData(); throw ContractFailure(description: "library owner export must refuse") }
        catch DocumentError.libraryOwnedExportUnsupported { }
        try requireEqual(await doc.snapshot(), before)
        let old = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 8))
        _ = try await old.perform(.addDefinition(record.definition))
        _ = try await old.perform(.instantiate(definition: record.definition.id, root: root))
        _ = try await old.perform(.assign(PlaybackAssignment(id: binding, root: root, app: target, isEnabled: true), initial: UseListeningState(positions: [control: .scalar(Position(0.3))])))
        let evaluation = try await old.evaluate(assignment: binding).sound
        let bytes = try await old.sessionData()
        let reopened = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 8))
        _ = try await reopened.restoreSession(bytes)
        try requireEqual(try await reopened.evaluate(assignment: binding).sound, evaluation)
    }
}

import Foundation
@testable import SoundModel

private actor LinkedMemory: LibraryPersistence {
    var data: Data?
    var writes = 0
    var holding = false
    var continuation: CheckedContinuation<Void, Never>?
    var entry: CheckedContinuation<Void, Never>?
    var entered = false
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func arm() { holding = true; entered = false }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func release() { holding = false; continuation?.resume(); continuation = nil }
    func commit(_ value: Data) async -> LibraryWriteOutcome {
        if holding { await withCheckedContinuation { continuation = $0; entered = true; entry?.resume(); entry = nil } }
        data = value; writes += 1; return .committed
    }
}

struct LinkedModelCases {
    let profiles = try! LibraryProfiles()
    let expansion = try! LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128)
    var limits: LibraryLimits { try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128, expansion: expansion) }
    func record(_ block: SoundBlock, name: String, profile: String = LibraryProfiles.filters,
                presentation: [LibraryControl] = [], defaults: [LibrarySavedPosition] = [], version: Int = 2,
                id: DefinitionID = DefinitionID(), revision: DefinitionVersionID = DefinitionVersionID(), inTheMenu: Bool = true) throws -> LibraryRevision {
        let definition = BlockDefinition(id: id, version: revision, name: name, content: block, inTheMenu: inTheMenu)
        let payload = LibraryPayload(profile: profile, block: block, presentation: presentation,
                                     canonicalVersion: version, descendantDefaults: defaults)
        return try LibraryRevision(definition: definition, origin: "custom", payload: payload, contentHash: payload.contentHash)
    }
    func archive(_ records: [LibraryRevision], uses: [LibraryOwnedUse] = [], assignments: [PlaybackAssignment] = []) throws -> LibraryArchive {
        var a = try LibraryArchive.initial(profiles: profiles)
        a.revisions += records
        a.heads += records.map { LibraryDefinitionRecord($0) }
        a.uses = uses; a.assignments = assignments
        return a
    }
    func test_canonical_defaults_and_legacy_refusal() throws {
        let filters = try Filters(), base = filters.definition.content
        let id = base.controls[3].id, a = UseSiteID(), b = UseSiteID()
        let one = LibrarySavedPosition(id: id, value: .scalar(try Position(0.3)), path: [a])
        let two = LibrarySavedPosition(id: id, value: .scalar(try Position(0.4)), path: [b, a])
        let block = SoundBlock(pieces: [], controls: [], mappings: [])
        let p = LibraryPayload(profile: LibraryProfiles.filters, block: block, presentation: [], canonicalVersion: 2, descendantDefaults: [one, two])
        let q = LibraryPayload(profile: p.profile, block: block, presentation: [], canonicalVersion: 2, descendantDefaults: [two, one])
        try requireEqual(p.canonicalData, q.canonicalData)
        try requireEqual(p.contentHash, q.contentHash)
        try requireThrows(LibraryPayload(profile: p.profile, block: block, presentation: [], descendantDefaults: [one]).contentHash)
        try requireThrows(LibraryPayload(profile: p.profile, block: block, presentation: [], canonicalVersion: 99).contentHash)
        try requireThrows(LibraryPayload(profile: p.profile, block: block, presentation: [], canonicalVersion: 2, descendantDefaults: [one, one]).contentHash)
        try requireThrows(LibraryPayload(profile: p.profile, block: block, presentation: [], canonicalVersion: 2,
            descendantDefaults: [LibrarySavedPosition(id: id, value: .scalar(.start))]).contentHash)
        let state = UseListeningState(positions: [id: .scalar(.start)])
            .setting(OccurrenceControlKey(path: [a], control: id), to: .scalar(.end))
        let snapshot = DocumentSnapshot(revision: 0, isEnabled: false, definitions: [], uses: [], listening: [RootUseID(): state], assignments: [], assignmentListening: [:], canUndo: false, canRedo: false)
        try requireThrows(SoundSessionArchive(snapshot: snapshot)) { try requireEqual($0 as? DocumentError, .legacyDescendantState) }
        var first = AuthoredStream(); first.count(one.path.count); one.path.forEach { first.id($0.rawValue) }; first.id(one.id.rawValue)
        try requireEqual(one.key.orderBytes, first.data, "byte-defined length/path/control ordering")
        let linkedDefinition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: "Linked", content:
            SoundBlock(pieces: [.reference(ReferencedBlockUse(site: a, definition: filters.definition.reference))], controls: [], mappings: []))
        let linkedSnapshot = DocumentSnapshot(revision: 0, isEnabled: false, definitions: [linkedDefinition], uses: [], listening: [:], assignments: [], assignmentListening: [:], canUndo: false, canRedo: false)
        try requireThrows(SoundSessionArchive(snapshot: linkedSnapshot)) { try requireEqual($0 as? DocumentError, .legacyDescendantState) }
        let legacySound = try CompiledSound(block: base, root: RootUseID(), catalog: profiles.catalog(LibraryProfiles.filters))
        try requireThrows(profiles.native(legacySound)) {
            try requireEqual($0 as? LibraryError, .unknownProfile("missing part provenance"))
        }
    }
    func test_nested_capture_copy_and_history() async throws {
        let filters = try Filters(), volume = filters.definition.content.controls[3].id
        let leaf = try record(filters.definition.content.withPositions([volume: .scalar(Position(0.1))]), name: "Leaf",
                              presentation: profiles.presentation(for: filters.definition), version: 1)
        let l = UseSiteID(), a = UseSiteID(), b = UseSiteID()
        let near = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: l, definition: leaf.definition.reference))], controls: [], mappings: []), name: "Near",
                              defaults: [LibrarySavedPosition(id: volume, value: .scalar(Position(0.2)), path: [l])])
        let rootControl = ControlID()
        let control = SoundControl(id: rootControl, face: .slider, position: .scalar(.start), waypoints: .scalar([.start, .end]))
        let presentation = LibraryControl(id: rootControl.rawValue, title: "Root", face: .slider("A", "B"), placement: .primary, readout: nil)
        let outer = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: a, definition: near.definition.reference)), .reference(ReferencedBlockUse(site: b, definition: near.definition.reference))], controls: [control], mappings: []), name: "Outer", presentation: [presentation],
            defaults: [LibrarySavedPosition(id: volume, value: .scalar(Position(0.3)), path: [a, l]), LibrarySavedPosition(id: volume, value: .scalar(Position(0.3)), path: [b, l])])
        let root = RootUseID(), target = try ApplicationKey("test.nested")
        let use = RootSoundUse(id: root, definition: outer.definition.reference, name: .library)
        let owned = LibraryOwnedUse(target: target, use: use, draft: nil,
            positions: [LibrarySavedPosition(id: volume, value: .scalar(try Position(0.4)), path: [a, l])])
        let binding = PlaybackAssignment(id: AssignmentID(), root: root, app: target, isEnabled: true)
        let original = try archive([leaf, near, outer], uses: [owned], assignments: [binding])
        let port = LinkedMemory(try original.encoded(limits: limits))
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        func value(_ state: LibrarySnapshot, _ path: [UseSiteID]) -> LibraryPosition? {
            let binding = state.assignments.first { $0.target == target.bundleIdentifier }!
            return state.uses.first { $0.id == binding.use }!.occurrences.first { $0.path == path.map(\.rawValue) }!.positions[volume.rawValue]
        }
        try requireEqual(value(try await session.snapshot(), [a, l]), .scalar(0.4))
        try requireEqual(value(try await session.snapshot(), [b, l]), .scalar(0.3))
        await port.arm()
        let cloning = Task { try await session.createFromUse(on: target.bundleIdentifier, name: "Captured") }
        await port.wait()
        try await session.move(LibraryControlAddress(path: [a.rawValue, l.rawValue], control: volume.rawValue), on: target.bundleIdentifier, to: .scalar(0.5))
        await session.setEnabled(false)
        await port.release(); let clone = try await cloning.value
        try requireEqual(value(try await session.snapshot(), [a, l]), .scalar(0.5))
        let saved = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
        let cloned = saved.revisions.first { $0.definition.id.rawValue == clone }!
        try requireEqual(cloned.canonicalVersion, 2)
        let persisted = try await SoundLibrarySession(persistence: LinkedMemory(await port.data), limits: limits)
        try requireEqual(value(try await persisted.snapshot(), [a, l]), .scalar(0.4))
        try requireEqual(value(try await persisted.snapshot(), [b, l]), .scalar(0.3))
        try requireEqual(saved.revisions.first { $0.definition.reference == leaf.definition.reference }!.contentHash, leaf.contentHash)
        try requireEqual(saved.revisions.first { $0.definition.reference == near.definition.reference }!.contentHash, near.contentHash)
        _ = try await session.renameControl(on: target.bundleIdentifier, control: rootControl.rawValue, title: "Renamed Root")
        let renamed = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
        let draft = renamed.uses.first { $0.use.definition.id.rawValue == clone }!.draft!
        try requireEqual(draft.canonicalVersion, 2); try requireEqual(draft.descendantDefaults, cloned.descendantDefaults)
        let reopened = try await SoundLibrarySession(persistence: LinkedMemory(await port.data), limits: limits)
        try requireEqual(value(try await reopened.snapshot(), [a, l]), .scalar(0.5))
        let (content, metadata) = try renamed.validated(profiles: profiles, limits: limits)
        let document = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 8))
        await document.openLibrary(content: content, metadata: metadata, enabled: false, profiles: profiles, persistence: port, limits: limits, committed: await port.data)
        let cloneRoot = content.assignments[0].root
        let childKey = OccurrenceControlKey(path: [a,l], control: volume)
        _ = try await document.perform(.moveControl(root: cloneRoot, control: rootControl, value: .scalar(Position(0.7)), context: .editing))
        try await document.libraryMove(target: target, key: childKey, value: .scalar(Position(0.8)))
        _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().listening[cloneRoot]?.values[childKey], .scalar(Position(0.8)))
        _ = try await document.perform(.redo)
        try requireEqual(await document.snapshot().listening[cloneRoot]?.values[childKey], .scalar(Position(0.8)))
        let gesture = GestureID(); try await document.beginGesture(gesture, context: .editing)
        _ = try await document.perform(.moveControl(root: cloneRoot, control: rootControl, value: .scalar(Position(0.6)), context: .editing), gesture: gesture)
        try await document.libraryMove(target: target, key: childKey, value: .scalar(Position(0.9)))
        _ = try await document.endGesture(gesture); _ = try await document.perform(.undo)
        try requireEqual(await document.snapshot().listening[cloneRoot]?.values[childKey], .scalar(Position(0.9)))
        let cancel = GestureID(); try await document.beginGesture(cancel, context: .editing)
        _ = try await document.perform(.moveControl(root: cloneRoot, control: rootControl, value: .scalar(Position(0.2)), context: .editing), gesture: cancel)
        try await document.libraryMove(target: target, key: childKey, value: .scalar(Position(0.95)))
        _ = try await document.cancelGesture(cancel)
        try requireEqual(await document.snapshot().listening[cloneRoot]?.values[childKey], .scalar(Position(0.95)))
        let beforeCancel = await document.snapshot().listening[cloneRoot]?.positions[rootControl]
        let lateCancel = GestureID(); try await document.beginGesture(lateCancel, context: .editing)
        _ = try await document.perform(.moveControl(root: cloneRoot, control: rootControl, value: .scalar(Position(0.25)), context: .editing), gesture: lateCancel)
        await port.arm()
        let checkpoint = Task { try await document.libraryCheckpoint() }
        await port.wait(); _ = try await document.cancelGesture(lateCancel)
        await port.release(); _ = try await checkpoint.value
        try requireEqual(await document.snapshot().listening[cloneRoot]?.positions[rootControl], beforeCancel,
                         "late save cannot restore a cancelled root gesture")
        try requireTrue(try await document.librarySnapshot().unsaved)
        do { _ = try await document.sessionData(); throw ContractFailure(description: "legacy export should refuse children") }
        catch DocumentError.libraryOwnedExportUnsupported { }
        var noExplicitMemory = content
        noExplicitMemory.listening = noExplicitMemory.listening.mapValues { UseListeningState(positions: $0.positions) }
        noExplicitMemory.assignmentListening = noExplicitMemory.assignmentListening.mapValues { UseListeningState(positions: $0.positions) }
        await document.openLibrary(content: noExplicitMemory, metadata: metadata, enabled: false, profiles: profiles,
                                   persistence: port, limits: limits, committed: await port.data)
        do { _ = try await document.sessionData(); throw ContractFailure(description: "legacy export lost authored descendant defaults") }
        catch DocumentError.libraryOwnedExportUnsupported { }
    }
    func test_exact_heads_and_revision_only_links() async throws {
        let filters = try Filters(), volume = filters.definition.content.controls[3].id
        let definitionID = DefinitionID()
        var presentation = try profiles.presentation(for: filters.definition)
        presentation[3] = presentation[3].renamed("Old volume")
        let r1 = try record(filters.definition.content.withPositions([volume: .scalar(Position(0.2))]), name: "Old name", presentation: presentation, id: definitionID)
        let site = UseSiteID(), newControl = ControlID(), gain = PartID()
        let block = try SoundBlock(pieces: [.reference(ReferencedBlockUse(site: site, definition: r1.definition.reference)),
            .part(SoundPart(id: gain, type: "gain", settings: [ParameterSetting(key: ParameterKey("gainDb"), position: Position(0.9))]))],
            controls: [SoundControl(id: newControl, face: .slider, position: .scalar(Position(0.8)), waypoints: .scalar([.start,.end]))], mappings: [])
        let newPresentation = LibraryControl(id: newControl.rawValue, title: "New control", face: .slider("A","B"), placement: .primary, readout: nil)
        let r2 = try record(block, name: "New name", presentation: [newPresentation], id: definitionID, inTheMenu: false)
        var source = try LibraryArchive.initial(profiles: profiles)
        source.revisions = [r2] + source.revisions + [r1]
        source.heads.append(LibraryDefinitionRecord(r2))
        let target = try ApplicationKey("test.old"), root = RootUseID()
        let use = RootSoundUse(id: root, definition: r1.definition.reference, name: .library)
        source.uses = [LibraryOwnedUse(target: target, use: use, draft: nil, positions: [])]
        source.assignments = [PlaybackAssignment(id: AssignmentID(), root: root, app: target, isEnabled: true)]
        let port = LinkedMemory(try source.encoded(limits: limits)), model = try await SoundLibrarySession(persistence: port, limits: limits)
        let (content, metadata) = try source.validated(profiles: profiles, limits: limits)
        let document = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 4))
        await document.openLibrary(content: content, metadata: metadata, enabled: false, profiles: profiles, persistence: port, limits: limits, committed: await port.data)
        try requireEqual(try await document.snapshot().name(of: root), "New name")
        do { _ = try await document.sessionData(); throw ContractFailure(description: "legacy export accepted revision bank") }
        catch DocumentError.libraryOwnedExportUnsupported { }
        _ = try await model.select(definitionID.rawValue, on: "test.new")
        var state = try await model.snapshot()
        let head = state.definitions.first { $0.id == definitionID.rawValue }!
        try requireEqual(head.name, "New name"); try requireEqual(head.inTheMenu, false)
        try requireEqual(state.definitions.filter { $0.id == definitionID.rawValue }.count, 1)
        let oldUse = state.uses.first { $0.target == "test.old" }!, newUse = state.uses.first { $0.target == "test.new" }!
        try requireEqual(oldUse.name, "New name"); try requireEqual(oldUse.baseRevision, r1.definition.version.rawValue)
        try requireEqual(oldUse.controls[3].title, "Old volume")
        try requireEqual(newUse.baseRevision, r2.definition.version.rawValue)
        try requireEqual(newUse.controls[0].title, "New control")
        try requireEqual(state.assignments.first { $0.target == "test.old" }!.parts.count, 4)
        try requireEqual(state.assignments.first { $0.target == "test.new" }!.parts.count, 5)
        let oldParts = state.assignments.first { $0.target == "test.old" }!.parts
        let newParts = state.assignments.first { $0.target == "test.new" }!.parts
        try requireTrue(abs(oldParts.last!.parameters.first { $0.key == "gainDb" }!.value + 18) < 1e-10)
        try requireTrue(abs(newParts.last!.parameters.first { $0.key == "gainDb" }!.value - 3) < 1e-10)
        try requireEqual(newUse.positions[newControl.rawValue], .scalar(0.8))
        try requireEqual(oldUse.positions[volume.rawValue], .scalar(0.2))
        _ = try await model.nameUse(on: "test.old", name: "Mine")
        _ = try await model.select(filters.definition.id.rawValue, on: "test.old")
        _ = try await model.select(definitionID.rawValue, on: "test.old")
        state = try await model.snapshot()
        try requireEqual(state.uses.first { $0.id == oldUse.id }!.name, "Mine")
        try requireEqual(state.uses.first { $0.id == oldUse.id }!.baseRevision, r1.definition.version.rawValue)
        _ = try await model.renameControl(on: "test.old", control: volume.rawValue, title: "Local volume")
        let linked = try await model.createLinkedBlock(name: "Original link", children: [LibraryReference(definition: definitionID.rawValue, revision: r1.definition.version.rawValue)], on: "test.link")
        state = try await model.snapshot()
        let originalLink = state.uses.first { $0.definition == linked }!
        try requireEqual(originalLink.occurrences[1].controls[3].title, "Old volume")
        let captured = try await model.createFromUse(on: "test.old", name: "Local captured")
        let capturedDef = try await model.snapshot().definitions.first { $0.id == captured }!
        let capturedLink = try await model.createLinkedBlock(name: "Captured link", children: [LibraryReference(definition: captured, revision: capturedDef.revision)], on: "test.captured-link")
        state = try await model.snapshot()
        try requireEqual(state.uses.first { $0.definition == capturedLink }!.occurrences[1].controls[3].title, "Local volume")
        let reopened = try await SoundLibrarySession(persistence: LinkedMemory(await port.data), limits: limits)
        try requireEqual(try await reopened.snapshot(), try await model.snapshot())
    }
    func test_graph_and_version_refusals() async throws {
        let filters = try Filters(), original = try LibraryArchive.initial(profiles: profiles)
        func refuse(_ archive: LibraryArchive, limits: LibraryLimits, inspect: ((Error) throws -> Void)? = nil) async throws {
            let bytes = try archive.encoded(limits: self.limits), port = LinkedMemory(bytes)
            var error: Error?
            do { _ = try await SoundLibrarySession(persistence: port, limits: limits) } catch let caught { error = caught }
            try requireTrue(error != nil, "graph should refuse"); if let error { try inspect?(error) }
            try requireEqual(await port.writes, 0); try requireEqual(await port.data, bytes)
        }
        let missing = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: UseSiteID(), definition: DefinitionReference(id: DefinitionID(), version: DefinitionVersionID())))], controls: [], mappings: []), name: "Missing")
        try await refuse(archive([missing]), limits: limits) { try requireEqual($0 as? LibraryError, .missingReference) }
        let aid = DefinitionID(), avid = DefinitionVersionID(), bid = DefinitionID(), bvid = DefinitionVersionID()
        let a = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: UseSiteID(), definition: DefinitionReference(id: bid, version: bvid)))], controls: [], mappings: []), name: "A", id: aid, revision: avid)
        let b = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: UseSiteID(), definition: DefinitionReference(id: aid, version: avid)))], controls: [], mappings: []), name: "B", id: bid, revision: bvid)
        try await refuse(archive([a,b]), limits: limits) { try requireEqual($0 as? LibraryError, .cyclicReference) }
        let duplicateSite = UseSiteID()
        let duplicate = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: duplicateSite, definition: filters.definition.reference)), .reference(ReferencedBlockUse(site: duplicateSite, definition: filters.definition.reference))], controls: [], mappings: []), name: "Duplicate")
        try await refuse(archive([duplicate]), limits: limits) { try requireEqual($0 as? SoundModelError, .duplicateIdentity) }
        let repeated = try record(SoundBlock(pieces: (0..<4).map { _ in .reference(ReferencedBlockUse(site: UseSiteID(), definition: filters.definition.reference)) }, controls: [], mappings: []), name: "Expansion")
        let tiny = try LibraryLimits(maximumBytes: limits.maximumBytes, maximumRevisions: 128,
            expansion: LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 3, maximumParts: 128))
        try await refuse(archive([repeated]), limits: tiny) { try requireEqual($0 as? LibraryError, .expansionExceeded) }
        let partCap = try LibraryLimits(maximumBytes: limits.maximumBytes, maximumRevisions: 128,
            expansion: LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 3))
        try await refuse(original, limits: partCap) { try requireEqual($0 as? LibraryError, .expansionExceeded) }
        let inline = try record(SoundBlock(pieces: [.block(BlockUse(site: UseSiteID(), content: filters.definition.content))], controls: [], mappings: []), name: "Inline")
        let depth = try LibraryLimits(maximumBytes: limits.maximumBytes, maximumRevisions: 128,
            expansion: LibraryExpansionLimits(maximumDepth: 1, maximumOccurrences: 128, maximumParts: 128))
        try await refuse(archive([inline]), limits: depth) { try requireEqual($0 as? LibraryError, .expansionExceeded) }
        let linked = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: UseSiteID(), definition: filters.definition.reference))], controls: [], mappings: []), name: "Depth")
        try await refuse(archive([linked]), limits: depth) { try requireEqual($0 as? LibraryError, .expansionExceeded) }
        let noExpansion = try LibraryLimits(maximumBytes: limits.maximumBytes, maximumRevisions: 128)
        try await refuse(archive([linked]), limits: noExpansion) { try requireEqual($0 as? SoundModelError, .unsupportedReference) }
        func wireRefuse(_ object: [String: Any]) async throws {
            let bytes = try JSONSerialization.data(withJSONObject: object), port = LinkedMemory(bytes)
            do { _ = try await SoundLibrarySession(persistence: port, limits: limits); throw ContractFailure(description: "schema3 semantic admission") }
            catch is ContractFailure { throw ContractFailure(description: "schema3 mutation admitted") }
            catch { }
            try requireEqual(await port.writes, 0); try requireEqual(await port.data, bytes)
        }
        let originalObject = try JSONSerialization.jsonObject(with: original.encoded(limits: limits)) as! [String: Any]
        for field in ["canonicalVersion", "descendantDefaults"] {
            var object = originalObject, records = object["revisions"] as! [[String: Any]]
            records[0].removeValue(forKey: field); object["revisions"] = records
            try await wireRefuse(object)
        }
        for mutation in ["duplicateDefaults", "unknownProfile", "danglingDefault"] {
            var object = originalObject, records = object["revisions"] as! [[String: Any]]
            let saved = LibrarySavedPosition(id: filters.definition.content.controls[0].id, value: .scalar(.start), path: [UseSiteID()])
            let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
            records[0]["canonicalVersion"] = 2
            switch mutation {
            case "duplicateDefaults": records[0]["descendantDefaults"] = [value,value]
            case "unknownProfile": records[0]["profile"] = "future.profile"
            default: records[0]["descendantDefaults"] = [value]
            }
            object["revisions"] = records; try await wireRefuse(object)
        }
        let defaultSite = UseSiteID()
        let defaultRecord = try record(SoundBlock(pieces: [.reference(ReferencedBlockUse(site: defaultSite, definition: filters.definition.reference))], controls: [], mappings: []), name: "Valid authored default",
            defaults: [LibrarySavedPosition(id: filters.definition.content.controls[0].id, value: .scalar(.start), path: [defaultSite])])
        let validDefaultArchive = try archive([defaultRecord])
        _ = try validDefaultArchive.validated(profiles: profiles, limits: limits)
        var defaultObject = try JSONSerialization.jsonObject(with: validDefaultArchive.encoded(limits: limits)) as! [String: Any]
        var defaultRecords = defaultObject["revisions"] as! [[String: Any]]
        var defaultValues = defaultRecords[2]["descendantDefaults"] as! [[String: Any]]
        defaultValues[0]["futureSemantic"] = true; defaultRecords[2]["descendantDefaults"] = defaultValues
        defaultObject["revisions"] = defaultRecords; try await wireRefuse(defaultObject)
        var object = originalObject
        var revisions = object["revisions"] as! [[String: Any]]
        revisions[0]["canonicalVersion"] = 99; object["revisions"] = revisions
        let unknown = LinkedMemory(try JSONSerialization.data(withJSONObject: object))
        do { _ = try await SoundLibrarySession(persistence: unknown, limits: limits); throw ContractFailure(description: "unknown canonical") }
        catch LibraryError.unknownCanonicalVersion(99) { }
        let defaults = LibrarySavedPosition(id: filters.definition.content.controls[0].id, value: .scalar(.start), path: [UseSiteID()])
        var invalid = original
        let old = invalid.revisions[0]
        let p = LibraryPayload(profile: old.profile, block: old.definition.content, presentation: old.presentation, canonicalVersion: 1, descendantDefaults: [defaults])
        invalid.revisions[0] = LibraryRevision(definition: old.definition, origin: old.origin, payload: p, contentHash: old.contentHash)
        try await refuse(invalid, limits: limits) { try requireEqual($0 as? LibraryError, .invalidCanonical) }
    }
}

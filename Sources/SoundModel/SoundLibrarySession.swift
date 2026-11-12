import Foundation

/// Data-only library interface. It shares the existing command actor and ordered compiler.
/// No method starts capture/playback, resolves a process, or selects an App startup path.
public struct SoundLibrarySession: Sendable {
    let document: SoundDocument

    public init(persistence: any LibraryPersistence, limits: LibraryLimits,
                migratingV1 legacyData: Data? = nil, migratingSchema2 schema2Data: Data? = nil) async throws {
        let profiles = try LibraryProfiles()
        guard legacyData == nil || schema2Data == nil else { throw LibraryError.invalidArchive }
        let saved = try await persistence.load()
        if let legacyData, legacyData.count > limits.maximumBytes { throw LibraryError.limitExceeded }
        let archive: LibraryArchive
        if let saved {
            guard legacyData == nil && schema2Data == nil else { throw LibraryError.invalidArchive }
            archive = try Self.storedArchive(saved, limits: limits)
        } else if let schema2Data {
            guard schema2Data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
            archive = try LibraryArchive.migratingV2(schema2Data, profiles: profiles, limits: limits)
        } else if let legacyData {
            archive = try LibraryArchive.migrating(legacyData, profiles: profiles)
        } else {
            archive = try LibraryArchive.initial(profiles: profiles)
        }
        try await self.init(archive: archive, profiles: profiles, persistence: persistence,
                            limits: limits, committed: saved)
    }
    static func storedArchive(_ data: Data, limits: LibraryLimits) throws -> LibraryArchive {
        guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
        try LibraryWireAdmission.uniqueKeys(data)
        let decoder = JSONDecoder(); decoder.userInfo[.libraryExpansion] = limits.expansion
        return try decoder.decode(LibraryArchive.self, from: data)
    }
    init(archive: LibraryArchive, profiles: LibraryProfiles, persistence: any LibraryPersistence,
         limits: LibraryLimits, committed: Data?) async throws {
        let (content, metadata) = try archive.validated(profiles: profiles, limits: limits)
        _ = try archive.encoded(limits: limits)
        let document = try SoundDocument(catalog: profiles.recipes.catalog,
                                        historyLimit: UndoHistoryLimit(groups: 1))
        await document.openLibrary(content: content, metadata: metadata, enabled: archive.enabled,
            profiles: profiles, persistence: persistence, limits: limits, committed: committed)
        self.document = document
    }
    public func beginEdit(_ target: LibraryEditTarget, admission: @escaping LibraryPartsAdmission) async throws -> LibraryEditSnapshot {
        try await document.libraryBeginEdit(target, admit: admission)
    }
    public func inspectEdit(_ handle: LibraryEditHandle) async throws -> LibraryEditSnapshot { try await document.libraryInspectEdit(handle) }
    public func edit(_ handle: LibraryEditHandle, expectedGeneration: UInt64, command: LibraryEditCommand) async throws -> LibraryEditSnapshot {
        try await document.libraryEdit(handle, generation: expectedGeneration, command: command)
    }
    public func beginEditGesture(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryEditGesture(handle, generation: expectedGeneration, action: 0)
    }
    public func endEditGesture(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryEditGesture(handle, generation: expectedGeneration, action: 1)
    }
    public func cancelEditGesture(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryEditGesture(handle, generation: expectedGeneration, action: 2)
    }
    public func undoEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryEditHistory(handle, generation: expectedGeneration, undoing: true)
    }
    public func redoEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryEditHistory(handle, generation: expectedGeneration, undoing: false)
    }
    public func checkpointEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryCommit {
        try await document.libraryCheckpointEdit(handle, generation: expectedGeneration)
    }
    public func discardEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryDiscardEdit(handle, generation: expectedGeneration)
    }
    public func doneEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryEditSnapshot {
        try await document.libraryDoneEdit(handle, generation: expectedGeneration)
    }
    @discardableResult
    public func createLinkedBlock(name: String, children: [LibraryReference], on target: String) async throws -> UUID {
        try await document.libraryCreateLinked(name: name, children: children.map(\.reference), target: ApplicationKey(target)).rawValue
    }
    public func renameDefinition(_ id: UUID, name: String) async throws -> LibraryCommit {
        try await document.libraryRenameDefinition(DefinitionID(id), name: name)
    }
    public func setInMenu(_ id: UUID, _ visible: Bool) async throws -> LibraryCommit {
        try await document.librarySetInMenu(DefinitionID(id), visible: visible)
    }
    public func createEmpty(name: String) async throws -> LibraryCreationResult {
        try await document.libraryCreateEmpty(name: name)
    }
    public func duplicate(_ reference: LibraryReference, name: String) async throws -> LibraryCreationResult {
        try await document.libraryDuplicate(reference.reference, name: name)
    }
    public func createFromUse(expected: LibraryBinding, name: String) async throws -> LibraryCreationResult {
        try await document.libraryCreate(expected: expected, name: name)
    }
    public func move(_ address: LibraryControlAddress, on target: String, to value: LibraryPosition) async throws {
        try await document.libraryMove(target: ApplicationKey(target), key: address.key, value: value.validated())
    }
    public func move(_ address: LibraryControlAddress, expected: LibraryBinding, to value: LibraryPosition) async throws -> LibraryLiveMutation {
        try await document.libraryMove(expected: expected, key: address.key, value: value)
    }
    public func setEnabled(_ enabled: Bool, expected: LibraryBinding) async throws -> LibraryLiveMutation {
        try await document.libraryEnabled(enabled, expected: expected)
    }
    public func saveCoverage() async throws -> LibrarySaveCoverage { try await document.librarySaveCoverage() }
    public func liveState() async throws -> LibraryLiveState { try await document.libraryLiveState() }
    public func snapshot() async throws -> LibrarySnapshot { try await document.librarySnapshot() }
    public func select(_ definition: UUID?, on target: String) async throws -> LibraryCommit {
        try await document.librarySelect(definition.map(DefinitionID.init), target: ApplicationKey(target))
    }
    @discardableResult
    public func createFromUse(on target: String, name: String) async throws -> UUID {
        try await document.libraryCreate(target: ApplicationKey(target), name: name).rawValue
    }
    public func nameUse(on target: String, name: String?) async throws -> LibraryCommit {
        try await document.libraryNameUse(target: ApplicationKey(target), name: name)
    }
    public func renameControl(on target: String, control: UUID, title: String) async throws -> LibraryCommit {
        try await document.libraryRenameControl(target: ApplicationKey(target), control: ControlID(control), title: title)
    }
    public func move(_ control: UUID, on target: String, to value: LibraryPosition) async throws {
        try await document.libraryMove(target: ApplicationKey(target), control: ControlID(control),
                                       value: value.validated())
    }
    public func setEnabled(_ enabled: Bool) async { await document.libraryEnabled(enabled) }
    public func setEnabled(_ enabled: Bool, on target: String) async throws {
        try await document.libraryEnabled(enabled, target: ApplicationKey(target))
    }
    public func compareOriginal(_ comparing: Bool) async { await document.libraryCompare(comparing) }
    @discardableResult
    public func checkpoint() async throws -> LibraryCommit { try await document.libraryCheckpoint() }
    public func reconcile() async throws -> LibraryWriteOutcome { try await document.libraryReconcile() }
}

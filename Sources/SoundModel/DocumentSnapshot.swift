import Foundation

enum DefinitionKind {}
enum DefinitionVersionKind {}
enum GestureKind {}
typealias DefinitionID = EntityID<DefinitionKind>
typealias DefinitionVersionID = EntityID<DefinitionVersionKind>
typealias GestureID = EntityID<GestureKind>

enum ControlMoveContext: Equatable, Sendable {
    case listening
    case editing
}

enum DocumentError: Error, Equatable {
    case unknownDefinition(DefinitionID)
    case unknownUse(RootUseID)
    case unknownControl(ControlID)
    case duplicateDefinition(DefinitionID)
    case duplicateVersion(DefinitionVersionID)
    case duplicateUse(RootUseID)
    case missingVersion(DefinitionReference)
    case invalidName
    case gestureInProgress
    case wrongGesture(GestureID)
    case reusedGesture(GestureID)
    case gestureCommandNotAllowed
    case gestureContextMismatch(expected: ControlMoveContext, received: ControlMoveContext)
    case revisionExhausted
    case invalidHistoryLimit(Int)
    case unknownAssignment(AssignmentID)
    case duplicateAssignment(AssignmentID)
    case appAlreadyAssigned(ApplicationKey)
    case invalidApplicationKey
    case invalidSession
    case ambiguousDefinition(DefinitionID)
    case legacyDescendantState
    case libraryOwnedExportUnsupported
    case legacyRevisionBank
    case unsupportedSessionVersion(Int)
}

struct UndoHistoryLimit: Equatable, Sendable {
    let groups: Int

    init(groups: Int) throws {
        guard groups > 0 else { throw DocumentError.invalidHistoryLimit(groups) }
        self.groups = groups
    }
}

struct DefinitionReference: Hashable, Sendable, Codable {
    let id: DefinitionID
    let version: DefinitionVersionID
}

struct BlockDefinition: Equatable, Sendable, Codable {
    let id: DefinitionID
    let version: DefinitionVersionID
    let name: String
    let content: SoundBlock
    let inTheMenu: Bool

    init(
        id: DefinitionID, version: DefinitionVersionID, name: String, content: SoundBlock,
        inTheMenu: Bool = true
    ) {
        self.id = id; self.version = version; self.name = name; self.content = content;
        self.inTheMenu = inTheMenu
    }
    private enum CodingKeys: String, CodingKey { case id, version, name, content, inTheMenu }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(DefinitionID.self, forKey: .id)
        version = try c.decode(DefinitionVersionID.self, forKey: .version)
        name = try c.decode(String.self, forKey: .name)
        content = try c.decode(SoundBlock.self, forKey: .content)
        inTheMenu = c.contains(.inTheMenu) ? try c.decode(Bool.self, forKey: .inTheMenu) : true
    }

    var reference: DefinitionReference { DefinitionReference(id: id, version: version) }
}

enum UseName: Equatable, Sendable, Codable {
    case library
    case own(String)
}

struct RootSoundUse: Equatable, Sendable, Codable {
    let id: RootUseID
    let definition: DefinitionReference
    let name: UseName
}

struct UseListeningState: Equatable, Sendable {
    let values: [OccurrenceControlKey: ControlValue]
    var adjustments: [MappingAdjustment] = []
    var dormant: [LibrarySavedPosition] = []
    init(positions: [ControlID: ControlValue]) {
        values = Dictionary(uniqueKeysWithValues: positions.map { (OccurrenceControlKey(path: [], control: $0.key), $0.value) })
    }
    init(values: [OccurrenceControlKey: ControlValue], adjustments: [MappingAdjustment] = [], dormant: [LibrarySavedPosition] = []) {
        self.values = values; self.adjustments = adjustments; self.dormant = dormant
    }
    var positions: [ControlID: ControlValue] {
        Dictionary(uniqueKeysWithValues: values.compactMap { $0.key.path.isEmpty ? ($0.key.control, $0.value) : nil })
    }
    func setting(_ key: OccurrenceControlKey, to value: ControlValue?) -> Self {
        var next = values; next[key] = value; return Self(values: next, adjustments: adjustments, dormant: dormant)
    }
}

enum DocumentCommand: Sendable {
    case addDefinition(BlockDefinition)
    case instantiate(definition: DefinitionID, root: RootUseID)
    case moveControl(root: RootUseID, control: ControlID, value: ControlValue, context: ControlMoveContext)
    case renameDefinition(DefinitionID, name: String)
    case renameUse(root: RootUseID, name: String)
    case useLibraryName(RootUseID)
    case assign(PlaybackAssignment, initial: UseListeningState)
    case unassign(AssignmentID)
    case reassign(AssignmentID, root: RootUseID)
    case setAssignmentEnabled(AssignmentID, Bool)
    case moveAssignmentControl(assignment: AssignmentID, control: ControlID, value: ControlValue)
    case setEnabled(Bool)
    case undo
    case redo
}

// These receipts describe document state, including listening state, not playback adoption or audibility.
struct DocumentReceipt: Equatable, Sendable {
    let revision: UInt64
    let didChange: Bool
}

struct DocumentEvaluation: Equatable, Sendable {
    let revision: UInt64
    let sound: CompiledSound
}

struct DocumentSnapshot: Equatable, Sendable {
    let revision: UInt64
    let isEnabled: Bool
    let definitions: [BlockDefinition]
    let uses: [RootSoundUse]
    let listening: [RootUseID: UseListeningState]
    let assignments: [PlaybackAssignment]
    let assignmentListening: [AssignmentID: UseListeningState]
    let canUndo: Bool
    let canRedo: Bool
    var headReferences: [DefinitionID: DefinitionReference] = [:]

    func name(of root: RootUseID) throws -> String {
        guard let use = uses.first(where: { $0.id == root }) else { throw DocumentError.unknownUse(root) }
        switch use.name {
        case .own(let name): return name
        case .library:
            let reference = headReferences[use.definition.id] ?? use.definition
            guard let definition = definitions.first(where: { $0.reference == reference }) else {
                throw DocumentError.missingVersion(reference)
            }
            return definition.name
        }
    }
}

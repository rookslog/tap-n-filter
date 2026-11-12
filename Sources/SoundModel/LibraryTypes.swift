import Foundation

public enum LibraryError: Error, Equatable {
    case mappingCycle
    case invalidArchive
    case migrationRequired
    case invalidCanonical
    case unknownCanonicalVersion(Int)
    case missingReference
    case cyclicReference
    case expansionExceeded
    case unsupportedFormat
    case unknownProfile(String)
    case unsupportedLegacy
    case unsupportedHistory
    case invalidLimits
    case limitExceeded
    case durableStateUnresolved
    case persistenceRefused(LibraryWriteRefusal)
    case protectedBuiltin
    case staleBinding
    case unknownDefinition
    case unknownTarget
    case staleEdit
    case unsupportedEdit
    case noEditHistory
    case invalidPresentation
}

public struct LibraryLimits: Sendable {
    public let maximumBytes: Int
    public let maximumRevisions: Int
    public let expansion: LibraryExpansionLimits?
    public init(maximumBytes: Int, maximumRevisions: Int, expansion: LibraryExpansionLimits? = nil) throws {
        guard maximumBytes > 0, maximumRevisions > 0 else { throw LibraryError.invalidLimits }
        self.maximumBytes = maximumBytes; self.maximumRevisions = maximumRevisions; self.expansion = expansion
    }
}

public enum LibraryWriteRefusal: Equatable, Sendable {
    case notLoaded
    case byteLimit
    case destinationChanged
    case previousRetained
    case io(String)
}

public enum LibraryWriteOutcome: Equatable, Sendable {
    case committed
    case identical
    case refused(LibraryWriteRefusal)
    case unresolved(String)

    public var isAccepted: Bool {
        switch self {
        case .committed, .identical: return true
        case .refused, .unresolved: return false
        }
    }
}

/// Single-writer data boundary; a nonthrowing outcome must describe actual replacement certainty.
public protocol LibraryPersistence: Sendable {
    func load() async throws -> Data?
    func commit(_ data: Data) async -> LibraryWriteOutcome
}

public struct LibraryCommit: Equatable, Sendable {
    public let token: UUID
    public let digest: String
    public let outcome: LibraryWriteOutcome
}

/// Candidate identity is not publication: acceptedReference exists only for a definitive accepted commit.
public struct LibraryCreationResult: Equatable, Sendable {
    public let candidate: LibraryReference
    public let commit: LibraryCommit
    public var acceptedReference: LibraryReference? { commit.outcome.isAccepted ? candidate : nil }
}

public enum LibraryFace: Equatable, Sendable, Codable {
    case slider(String, String)
    case choice([LibraryOption])
    case xy
}
public struct LibraryOption: Equatable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let position: Double
    public init(id: UUID, title: String, position: Double) { self.id = id; self.title = title; self.position = position }
}
public struct LibraryControl: Equatable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let face: LibraryFace
    public let placement: ListeningControlPlacement
    public let readout: ListeningReadout?

    func renamed(_ title: String) -> Self {
        Self(id: id, title: title, face: face, placement: placement, readout: readout)
    }
}

public enum LibraryPosition: Equatable, Sendable, Codable {
    case scalar(Double)
    case xy(Double, Double)

    init(_ value: ControlValue) {
        switch value {
        case .scalar(let p): self = .scalar(p.value)
        case .xy(let x, let y): self = .xy(x.value, y.value)
        }
    }
    func validated() throws -> ControlValue {
        switch self {
        case .scalar(let p): return .scalar(try Position(p))
        case .xy(let x, let y): return .xy(x: try Position(x), y: try Position(y))
        }
    }
}

/// Byte-equality coverage of the current owner, independent of menu/render projections.
public struct LibrarySaveCoverage: Equatable, Sendable {
    public let isSaved: Bool
    public let liveGeneration: UInt64
}

public struct LibraryBinding: Equatable, Sendable {
    public let assignment: UUID
    public let use: UUID
    public let target: String
    public init(assignment: UUID, use: UUID, target: String) {
        self.assignment = assignment; self.use = use; self.target = target
    }
}
public enum LibraryLiveMutation: Equatable, Sendable { case changed, noChange, superseded }
public struct LibraryLiveAssignment: Equatable, Sendable {
    public let binding: LibraryBinding
    public let isEnabled: Bool
}
/// Does not compile audio/presentation; remains available when those projections refuse.
public struct LibraryLiveState: Equatable, Sendable {
    public let isEnabled: Bool
    public let compareOriginal: Bool
    public let assignments: [LibraryLiveAssignment]
    public let pendingCommit: UUID?
    public let unresolved: Bool
    public let writing: Bool
}

public struct LibraryDefinitionSummary: Equatable, Sendable {
    public let id: UUID
    public let revision: UUID
    public let name: String
    public let origin: String
    public let profile: String
    public let contentHash: String
    public let inTheMenu: Bool
    public let controls: [LibraryControl]
    public var builtin: BuiltinBlock? = nil
}
public struct LibraryUseSummary: Equatable, Sendable {
    public let id: UUID
    public let target: String
    public let definition: UUID
    public let baseRevision: UUID
    public let name: String
    public let hasOwnName: Bool
    public let hasLocalDraft: Bool
    public let controls: [LibraryControl]
    public let positions: [UUID: LibraryPosition]
    public var occurrences: [LibraryOccurrenceSummary] = []
    public var defaults: [LibraryOccurrenceSummary] = []
    public var builtin: BuiltinBlock? = nil
    public var optionControls: [LibraryOptionControl] = []
    /// Ephemeral compiled eligibility; nil means unknown, never an archive field.
    public var directSliderControls: [LibraryControlAddress]? = nil
}
public struct LibraryAssignmentSummary: Equatable, Sendable {
    public let isEnabled: Bool
    public let id: UUID
    public let target: String
    public let use: UUID
    public let definition: UUID
    public let parts: [ListeningRenderPart]
}
public struct LibrarySnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let compareOriginal: Bool
    public let unsaved: Bool
    public let unresolved: Bool
    public let writing: Bool
    public let definitions: [LibraryDefinitionSummary]
    public let uses: [LibraryUseSummary]
    public let assignments: [LibraryAssignmentSummary]
    public var pendingCommit: UUID? = nil
}

struct LibraryPayload: Equatable, Sendable, Codable {
    let profile: String
    let block: SoundBlock
    let presentation: [LibraryControl]
    let canonicalVersion: Int
    let descendantDefaults: [LibrarySavedPosition]
    let authored: LibraryAuthoredFields

    init(profile: String, block: SoundBlock, presentation: [LibraryControl], canonicalVersion: Int = 1,
         descendantDefaults: [LibrarySavedPosition] = [], authored: LibraryAuthoredFields = .empty) {
        self.profile = profile; self.block = block; self.presentation = presentation
        self.canonicalVersion = canonicalVersion; self.descendantDefaults = descendantDefaults; self.authored = authored
    }
    private enum CodingKeys: CodingKey { case profile, block, presentation, canonicalVersion, descendantDefaults, authored }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(String.self, forKey: .profile); block = try c.decode(SoundBlock.self, forKey: .block)
        presentation = try c.decode([LibraryControl].self, forKey: .presentation)
        if decoder.userInfo[.libraryLegacy] as? Bool == true {
            canonicalVersion = 1; descendantDefaults = []
        } else {
            canonicalVersion = try c.decode(Int.self, forKey: .canonicalVersion)
            descendantDefaults = try c.decode([LibrarySavedPosition].self, forKey: .descendantDefaults)
        }
        authored = (3...5).contains(canonicalVersion) ? try c.decode(LibraryAuthoredFields.self, forKey: .authored)
            : try c.decodeIfPresent(LibraryAuthoredFields.self, forKey: .authored) ?? .empty
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .profile); try c.encode(block, forKey: .block)
        try c.encode(presentation, forKey: .presentation); try c.encode(canonicalVersion, forKey: .canonicalVersion)
        try c.encode(descendantDefaults, forKey: .descendantDefaults)
        if canonicalVersion >= 3 || authored != .empty { try c.encode(authored, forKey: .authored) }
    }
}
struct LibraryRevision: Equatable, Sendable, Codable {
    let definition: BlockDefinition
    let origin: String
    let profile: String
    let presentation: [LibraryControl]
    let contentHash: String
    let canonicalVersion: Int
    let descendantDefaults: [LibrarySavedPosition]

    let authored: LibraryAuthoredFields

    var payload: LibraryPayload {
        LibraryPayload(profile: profile, block: definition.content, presentation: presentation, canonicalVersion: canonicalVersion, descendantDefaults: descendantDefaults, authored: authored)
    }
    init(definition: BlockDefinition, origin: String, payload: LibraryPayload, contentHash: String) {
        self.definition = definition; self.origin = origin; profile = payload.profile
        presentation = payload.presentation; self.contentHash = contentHash
        canonicalVersion = payload.canonicalVersion; descendantDefaults = payload.descendantDefaults; authored = payload.authored
    }
    private enum CodingKeys: CodingKey { case definition, origin, profile, presentation, contentHash, canonicalVersion, descendantDefaults, authored }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        definition = try c.decode(BlockDefinition.self, forKey: .definition); origin = try c.decode(String.self, forKey: .origin)
        profile = try c.decode(String.self, forKey: .profile); presentation = try c.decode([LibraryControl].self, forKey: .presentation)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        if decoder.userInfo[.libraryLegacy] as? Bool == true {
            canonicalVersion = 1; descendantDefaults = []
        } else {
            canonicalVersion = try c.decode(Int.self, forKey: .canonicalVersion)
            descendantDefaults = try c.decode([LibrarySavedPosition].self, forKey: .descendantDefaults)
        }
        authored = (3...5).contains(canonicalVersion) ? try c.decode(LibraryAuthoredFields.self, forKey: .authored)
            : try c.decodeIfPresent(LibraryAuthoredFields.self, forKey: .authored) ?? .empty
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(definition, forKey: .definition); try c.encode(origin, forKey: .origin)
        try c.encode(profile, forKey: .profile); try c.encode(presentation, forKey: .presentation)
        try c.encode(contentHash, forKey: .contentHash); try c.encode(canonicalVersion, forKey: .canonicalVersion)
        try c.encode(descendantDefaults, forKey: .descendantDefaults)
        if canonicalVersion >= 3 || authored != .empty { try c.encode(authored, forKey: .authored) }
    }
}
/// Sole current metadata authority. Revision-shaped display fields are immutable history.
struct LibraryDefinitionRecord: Equatable, Sendable, Codable {
    let definition: DefinitionID
    let revision: DefinitionVersionID
    var name: String
    var inTheMenu: Bool
    let origin: String

    init(_ record: LibraryRevision) {
        definition = record.definition.id; revision = record.definition.version
        name = record.definition.name; inTheMenu = record.definition.inTheMenu; origin = record.origin
    }
}
struct LibraryOwnedUse: Equatable, Sendable, Codable {
    let target: ApplicationKey
    var use: RootSoundUse
    var draft: LibraryPayload?
    var positions: [LibrarySavedPosition]
    var authoring: LibraryDraftInfo? = nil
    var optionRemovals: [LibraryOptionRemoval]? = nil
}
struct LibrarySavedPosition: Equatable, Sendable, Codable {
    let id: ControlID
    let value: ControlValue
    let path: [UseSiteID]
    var adjustments: [MappingAxisDelta] = []
    var dormant: Bool = false
    var retiredControl: SoundControl? = nil
    init(id: ControlID, value: ControlValue, path: [UseSiteID] = []) { self.id = id; self.value = value; self.path = path }
    var key: OccurrenceControlKey { OccurrenceControlKey(path: path, control: id) }
    fileprivate enum CodingKeys: CodingKey { case id, value, path, adjustments, dormant, retiredControl }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ControlID.self, forKey: .id); value = try c.decode(ControlValue.self, forKey: .value)
        adjustments = try c.decodeIfPresent([MappingAxisDelta].self, forKey: .adjustments) ?? []
        retiredControl = try c.decodeIfPresent(SoundControl.self, forKey: .retiredControl)
        dormant = try c.decodeIfPresent(Bool.self, forKey: .dormant) ?? false
        path = decoder.userInfo[.libraryLegacy] as? Bool == true ? [] : try c.decode([UseSiteID].self, forKey: .path)
    }
}
extension LibrarySavedPosition {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(value, forKey: .value); try c.encode(path, forKey: .path)
        if !adjustments.isEmpty { try c.encode(adjustments, forKey: .adjustments) }
        if dormant { try c.encode(true, forKey: .dormant) }
        try c.encodeIfPresent(retiredControl, forKey: .retiredControl)
    }
}

struct LibraryArchive: Equatable, Sendable, Codable {
    let format: String
    let schema: Int
    let commit: UUID
    let provenance: String
    var revisions: [LibraryRevision]
    var heads: [LibraryDefinitionRecord]
    var uses: [LibraryOwnedUse]
    var assignments: [PlaybackAssignment]
    var enabled: Bool
    var workspaces: [LibraryWorkspace] = []
}

struct LibraryMetadata: Sendable {
    var revisions: [LibraryRevision]
    var heads: [LibraryDefinitionRecord]
    var owned: [LibraryOwnedUse]
    var provenance: String
    var workspaces: [LibraryWorkspace] = []
}
struct LibraryDraftCapture: Sendable {
    let info: LibraryDraftInfo
    let positions: UseListeningState
}
struct LibraryPending: Sendable {
    // Transient capture identity only; not part of any archive or hash.
    let capturedDrafts: [LibraryDraftOwner: LibraryDraftCapture]
    let capturedEdits: [UUID: LibraryEditHandle]
    let token: UUID
    let data: Data
    let candidate: DocumentContent
    let metadata: LibraryMetadata
    let enabled: Bool
    let generation: UInt64
    let carryPositions: [RootUseID: RootUseID]
    let task: Task<LibraryWriteOutcome, Never>
    var publication: LibraryPublicationMigration? = nil
}
struct LibraryCommittedBytes: Sendable {
    let data: Data
    private(set) var cachedToken: UUID?

    init(data: Data, token: UUID? = nil) {
        self.data = data; cachedToken = token
    }
    mutating func token() throws -> UUID {
        if let cachedToken { return cachedToken }
        let decoded = try JSONDecoder().decode(LibraryArchive.self, from: data).commit
        cachedToken = decoded
        return decoded
    }
}
struct LibraryOwnerState: Sendable {
    let port: any LibraryPersistence
    let limits: LibraryLimits
    let profiles: LibraryProfiles
    var metadata: LibraryMetadata
    var committed: LibraryCommittedBytes?
    var pending: LibraryPending?
    var uncertain: LibraryPending?
    var liveGeneration: UInt64 = 0
    var compareOriginal = false
    var drafts: [LibraryDraftOwner: LibraryWorkingDraft] = [:]
    var updateReports: [UUID: LibraryUpdateReport] = [:]
}

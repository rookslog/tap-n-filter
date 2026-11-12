import Foundation

public typealias LibraryPartsAdmission = @Sendable ([ListeningRenderPart]) throws -> Void
public enum LibraryEditTarget: Equatable, Sendable {
    case use(LibraryBinding)
    case definition(UUID)
}
public struct LibraryEditHandle: Equatable, Sendable {
    public let id: UUID
    public let target: LibraryEditTarget
    public let base: LibraryReference
}
public enum LibraryEditCommand: Sendable {
    case mapping(path: [UUID], LibraryMappingCommand)
    case setPhysical(part: UUID, parameter: String, value: Double)
    case addPart(type: String, at: Int)
    case removePart(UUID)
    case reorderParts([UUID])
    case bypassPart(UUID, Bool)
    case showAtTop(part: UUID, parameter: String, title: String)
    case moveControl(LibraryControlAddress, LibraryPosition)
}
public enum LibraryDraftDurability: Equatable, Sendable {
    case saved(token: UUID, digest: String)
    case unsaved
    case refused(LibraryWriteRefusal)
    case unresolved(token: UUID, digest: String)
}
public enum LibraryValueScale: Equatable, Sendable { case linear, logarithmic }
public struct LibraryValueSpecification: Equatable, Sendable {
    public let lower: Double
    public let upper: Double
    public let minimumInput: Double
    public let scale: LibraryValueScale
    public let discrete: Bool
    var domain: ParameterDomain {
        scale == .linear ? .linear(lower, upper) : .logarithmic(lower, upper)
    }
    public func normalized(_ physical: Double) throws -> Double {
        guard physical.isFinite, physical >= minimumInput,
              !discrete || physical.rounded(.towardZero) == physical else { throw LibraryError.unsupportedEdit }
        return try domain.position(physical).value
    }
    public func physical(_ normalized: Double) throws -> Double {
        let value = domain.value(try Position(normalized))
        _ = try self.normalized(value)
        return value
    }
}
public struct LibraryEditSeed: Equatable, Sendable {
    public let parameter: String
    public let value: Double
    public let unit: String
    public let specification: LibraryValueSpecification
}
public struct LibraryEditKind: Equatable, Sendable {
    public let type: String
    public let seed: [LibraryEditSeed]
    public let insertionFailure: String?
    public var canInsert: Bool { insertionFailure == nil }
}
public enum LibraryEditPiece: Equatable, Sendable {
    case part(UUID)
    case embedded(site: UUID, retainedParts: Int)
    case reference(site: UUID, exact: LibraryReference, retainedParts: Int)
}
public struct LibraryEditSetting: Equatable, Sendable {
    public let parameter: String
    public let physicalValue: Double
    public let unit: String
    public let base: Double
    public let adjustment: Double
    public let unadjustedSum: Double
    public let specification: LibraryValueSpecification
    public let sourceControls: [UUID]
    public let isChangedHere: Bool
    public let isShownAtTop: Bool
}
public struct LibraryEditPart: Equatable, Sendable {
    public let id: UUID
    public let type: String
    public let bypassed: Bool
    public let settings: [LibraryEditSetting]
}
public struct LibraryEditSnapshot: Equatable, Sendable {
    public let occurrences: [LibraryOccurrenceSummary]
    public let handle: LibraryEditHandle
    public let generation: UInt64
    public let pendingStructural: Bool
    public let durability: LibraryDraftDurability
    public let canUndo: Bool
    public let canRedo: Bool
    public let parts: [LibraryEditPart]
    public let pieces: [LibraryEditPiece]
    public let kinds: [LibraryEditKind]
    public let controls: [LibraryControl]
    public let positions: [LibraryControlAddress: LibraryPosition]
}

struct LibrarySettingAddress: Hashable, Sendable, Codable {
    let part: PartID
    let parameter: ParameterKey
    var order: String { part.rawValue.uuidString + ":" + parameter.rawValue }
}
struct LibraryAdjustment: Equatable, Sendable, Codable {
    let address: LibrarySettingAddress
    let value: Double
}
struct LibraryAuthoredFields: Equatable, Sendable, Codable {
    var bypassed: [PartID]
    var adjustments: [LibraryAdjustment]
    static let empty = Self(bypassed: [], adjustments: [])
    func validate(in block: SoundBlock) throws {
        let parts = block.pieces.compactMap { if case .part(let part) = $0 { return part }; return nil }
        guard Set(bypassed).count == bypassed.count,
              bypassed.allSatisfy({ id in parts.contains { $0.id == id } }),
              Set(adjustments.map(\.address)).count == adjustments.count,
              adjustments.allSatisfy({ item in item.value.isFinite && parts.contains {
                  $0.id == item.address.part && $0.settings.contains { $0.key == item.address.parameter }
              } }) else { throw LibraryError.invalidCanonical }
    }
    func adjustment(_ part: PartID, _ key: ParameterKey) -> Double {
        adjustments.first { $0.address.part == part && $0.address.parameter == key }?.value ?? 0
    }
}
struct LibraryDraftInfo: Equatable, Sendable, Codable {
    let id: UUID
    let generation: UInt64
    let structural: Bool
    func validate() throws { guard generation < UInt64.max else { throw LibraryError.invalidArchive } }
}
struct LibraryWorkspace: Equatable, Sendable, Codable {
    let definition: DefinitionID
    let base: DefinitionReference
    let payload: LibraryPayload
    let info: LibraryDraftInfo
    let positions: [LibrarySavedPosition]
    var optionRemovals: [LibraryOptionRemoval]? = nil
    func listening() throws -> UseListeningState {
        guard Set(positions.map(\.key)).count == positions.count else { throw LibraryError.invalidArchive }
        return try UseListeningState(saved: positions)
    }
}
enum LibraryDraftOwner: Hashable, Sendable {
    case use(RootUseID)
    case definition(DefinitionID)
}
struct LibraryWorkingDraft: Equatable, Sendable {
    let owner: LibraryDraftOwner
    let base: DefinitionReference
    var payload: LibraryPayload
    var info: LibraryDraftInfo
    var positions: UseListeningState
    var refusal: LibraryWriteRefusal? = nil
    var optionRemovals: [LibraryOptionRemoval] = []
}
struct LibraryPositionPatch: Sendable {
    let key: OccurrenceControlKey
    let before: ControlValue?
    let after: ControlValue?
}
private struct LibraryHistoryPosition: Encodable {
    let path: [UseSiteID]
    let control: ControlID
    let before: ControlValue?
    let after: ControlValue?
}
struct LibraryEditPatch: Sendable {
    var order: UInt64 = 0
    let before: LibraryPayload
    let after: LibraryPayload
    let beforeStructural: Bool
    let afterStructural: Bool
    let positions: [LibraryPositionPatch]
    var beforeAdjustments: [MappingAdjustment] = []
    var afterAdjustments: [MappingAdjustment] = []
    var beforeDormant: [LibrarySavedPosition] = []
    var afterDormant: [LibrarySavedPosition] = []
    var optionHistory: LibraryOptionHistory? = nil
    var approximateBytes: Int {
        do {
            let encoder = JSONEncoder()
            let history = positions.map { LibraryHistoryPosition(path: $0.key.path, control: $0.key.control, before: $0.before, after: $0.after) }
            let optionBytes = try encoder.encode(optionHistory).count
            return try encoder.encode(before).count + encoder.encode(after).count + encoder.encode(history).count + encoder.encode(beforeAdjustments).count + encoder.encode(afterAdjustments).count + encoder.encode(beforeDormant).count + encoder.encode(afterDormant).count + optionBytes
        } catch { return Int.max }

    }
}
struct LibraryEditContext: Sendable {
    var handle: LibraryEditHandle
    let owner: LibraryDraftOwner
    let admit: LibraryPartsAdmission
    var priorHandles: [LibraryEditHandle] = []
    var undo: [LibraryEditPatch] = []
    var redo: [LibraryEditPatch] = []
    var gesture: LibraryWorkingDraft? = nil
    var gesturePositions: [OccurrenceControlKey: LibraryPositionPatch] = [:]
    var staged: LibraryEditPatch? = nil
}

extension LibraryPayload {
    func replacing(block: SoundBlock? = nil, presentation: [LibraryControl]? = nil,
                   fields: LibraryAuthoredFields? = nil) throws -> Self {
        var changed = block ?? self.block
        let version = changed.needsVersion5 || canonicalVersion == 5 ? 5 : (changed.needsVersion4 || canonicalVersion == 4 ? 4 : max(3, canonicalVersion))
        if version >= 4 { changed = try changed.promoted() }
        return Self(profile: profile, block: changed, presentation: presentation ?? self.presentation,
            canonicalVersion: version, descendantDefaults: descendantDefaults, authored: fields ?? authored)
    }
}
extension LibraryOwnerState {
    var effectiveMetadata: LibraryMetadata { overlay(on: metadata) }
    func overlay(on original: LibraryMetadata) -> LibraryMetadata {
        var result = original
        for draft in drafts.values {
            switch draft.owner {
            case .use(let root):
                if let index = result.owned.firstIndex(where: { $0.use.id == root && $0.use.definition == draft.base }) {
                    result.owned[index].draft = draft.payload
                    result.owned[index].authoring = draft.info
                    result.owned[index].optionRemovals = draft.optionRemovals.isEmpty ? nil : draft.optionRemovals
                }
            case .definition(let id):
                result.workspaces.removeAll { $0.definition == id }
                result.workspaces.append(LibraryWorkspace(definition: id, base: draft.base, payload: draft.payload,
                    info: draft.info, positions: draft.positions.saved, optionRemovals: draft.optionRemovals.isEmpty ? nil : draft.optionRemovals))
            }
        }
        result.workspaces.sort { $0.definition.rawValue.uuidString < $1.definition.rawValue.uuidString }
        return result
    }
}

extension LibraryPayload {
    func structurallyDiffers(from base: LibraryPayload) -> Bool {
        func same(_ a: SoundBlock, _ b: SoundBlock) -> Bool {
            guard a.pieces.count == b.pieces.count, a.controls.count == b.controls.count,
                  a.mappings.count == b.mappings.count, a.bindings == b.bindings else { return false }
            for (left, right) in zip(a.pieces, b.pieces) {
                switch (left, right) {
                case (.part(let x), .part(let y)):
                    if x.id != y.id || x.type != y.type || x.settings.map(\.key) != y.settings.map(\.key) { return false }
                case (.reference(let x), .reference(let y)): if x != y { return false }
                case (.block(let x), .block(let y)): if x.site != y.site || !same(x.content, y.content) { return false }
                default: return false
                }
            }
            for (x, y) in zip(a.controls, b.controls) {
                if x.id != y.id || x.face != y.face || x.waypoints != y.waypoints { return false }
            }
            return zip(a.mappings, b.mappings).allSatisfy {
                $0.control == $1.control && $0.axis == $1.axis && $0.part == $1.part && $0.parameter == $1.parameter
            }
        }
        return !same(block, base.block)
    }
}

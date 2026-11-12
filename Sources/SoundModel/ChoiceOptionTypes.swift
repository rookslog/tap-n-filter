import Foundation

public enum LibraryOptionMutation: Equatable, Sendable {
    case add(id: UUID, title: String, at: Int)
    case remove(id: UUID, replacement: UUID)
}
public enum LibraryOptionError: Error, Equatable {
    case invalidMutation
    case reportingHistoryRequired
    case replacementRequired(LibraryControlAddress, UUID)
    case reportCapacity
}
public enum LibraryChoicePlace: Equatable, Sendable {
    case use(app: String, use: UUID)
    case workspace(definition: UUID)
}
public enum LibraryChoiceChangeReason: String, Sendable { case explicitReplacement, redistribution }
public struct LibraryChoiceChange: Equatable, Sendable {
    public let place: LibraryChoicePlace
    public let address: LibraryControlAddress
    public let before: UUID
    public let after: UUID
    public let reason: LibraryChoiceChangeReason
}
public struct LibraryChoiceReport: Equatable, Sendable {
    public let operation: UUID
    public let liveGeneration: UInt64
    public let changes: [LibraryChoiceChange]
}
public struct LibraryOptionEditPreview: Equatable, Sendable {
    public let id: UUID
    public let handle: LibraryEditHandle
    public let generation: UInt64
    public let address: LibraryControlAddress
    public let mutation: LibraryOptionMutation
    public let fingerprint: String
    public let report: LibraryChoiceReport
}
public struct LibraryOptionEditResult: Equatable, Sendable {
    public let snapshot: LibraryEditSnapshot
    public let report: LibraryChoiceReport
}
public struct LibraryOptionReplacement: Equatable, Sendable {
    public let address: LibraryControlAddress
    public let removed: UUID
    public let replacement: UUID
    public init(address: LibraryControlAddress, removed: UUID, replacement: UUID) {
        self.address = address; self.removed = removed; self.replacement = replacement
    }
}
public struct LibraryOptionRemovalSummary: Equatable, Sendable {
    public let base: LibraryReference
    public let address: LibraryControlAddress
    public let schema: [UUID]
    public let removed: UUID
    public let replacement: UUID
}
public struct LibraryUpdateReport: Equatable, Sendable {
    public let token: UUID
    public let capturedDigest: String
    public let carriedNewerState: Bool
    public let choices: LibraryChoiceReport
}
public struct LibraryUpdateResult: Equatable, Sendable {
    public let commit: LibraryCommit
    public let acceptedReport: LibraryUpdateReport?
}

// Unpublished semantic intent. This is deliberately not part of LibraryPayload.
struct LibraryOptionRemoval: Equatable, Sendable, Codable {
    let base: DefinitionReference
    let path: [UUID]
    let control: UUID
    let schema: [UUID]
    let removed: UUID
    var replacement: UUID
    var summary: LibraryOptionRemovalSummary {
        LibraryOptionRemovalSummary(base: LibraryReference(definition: base.id.rawValue, revision: base.version.rawValue), address: LibraryControlAddress(path: path, control: control),
            schema: schema, removed: removed, replacement: replacement)
    }
}
struct ChoiceOptionTransition: Equatable, Sendable {
    let address: LibraryControlAddress
    let before: SoundControl
    let after: SoundControl
    let replacements: [UUID: UUID]
    let copyNeighbor: UUID?
    var oldChoice: Choice { if case .choice(let c) = before.face { return c }; preconditionFailure() }
    var newChoice: Choice { if case .choice(let c) = after.face { return c }; preconditionFailure() }
    func destination(_ id: UUID) throws -> UUID {
        if newChoice.options.contains(OptionID(id)) { return id }
        guard let next = replacements[id], newChoice.options.contains(OptionID(next)) else {
            throw LibraryOptionError.replacementRequired(address, id)
        }
        return next
    }
    func anchor(_ value: Position) throws -> Position {
        guard let i = oldChoice.positions.firstIndex(of: value) else { return value }
        return try newChoice.position(of: OptionID(destination(oldChoice.options[i].rawValue)))
    }
    func value(_ value: ControlValue) throws -> ControlValue {
        guard case .scalar(let p) = value else { throw LibraryOptionError.invalidMutation }
        return .scalar(try newChoice.position(of: OptionID(destination(oldChoice.option(at: p).rawValue))))
    }
    func prefixed(_ path: [UUID]) -> Self {
        Self(address: LibraryControlAddress(path: path + address.path, control: address.control),
            before: before, after: after, replacements: replacements, copyNeighbor: copyNeighbor)
    }
    func reversed() -> Self {
        let inserted = newChoice.options.filter { !oldChoice.options.contains($0) }
        return Self(address: address, before: after, after: before,
            replacements: Dictionary(uniqueKeysWithValues: inserted.compactMap { id in copyNeighbor.map { (id.rawValue, $0) } }),
            copyNeighbor: replacements.values.first)
    }
}
struct LibraryOptionHistory: Sendable, Encodable {
    let transition: ChoiceOptionTransition
    let beforeRemovals: [LibraryOptionRemoval]
    let afterRemovals: [LibraryOptionRemoval]
    let beforeManual: ControlValue
    let afterManual: ControlValue
    let beforeHands: [MappingAxisKey: OptionID]
    let afterHands: [MappingAxisKey: OptionID]
    private enum CodingKeys: CodingKey { case path, control, before, after, replacements, neighbor, beforeRemovals, afterRemovals, beforeManual, afterManual, beforeHands, afterHands }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transition.address.path, forKey: .path); try c.encode(transition.address.control, forKey: .control)
        try c.encode(transition.before, forKey: .before); try c.encode(transition.after, forKey: .after)
        try c.encode(transition.replacements, forKey: .replacements); try c.encode(transition.copyNeighbor, forKey: .neighbor)
        try c.encode(beforeRemovals, forKey: .beforeRemovals); try c.encode(afterRemovals, forKey: .afterRemovals)
        try c.encode(beforeManual, forKey: .beforeManual); try c.encode(afterManual, forKey: .afterManual)
        try c.encode(beforeHands, forKey: .beforeHands); try c.encode(afterHands, forKey: .afterHands)
    }

}

extension SoundLibrarySession {
    public func previewOptionEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64,
        address: LibraryControlAddress, mutation: LibraryOptionMutation) async throws -> LibraryOptionEditPreview {
        try await document.libraryPreviewOption(handle, generation: expectedGeneration, address: address, mutation: mutation)
    }
    public func applyOptionEdit(_ preview: LibraryOptionEditPreview) async throws -> LibraryOptionEditResult {
        try await document.libraryApplyOption(preview)
    }
    public func undoOptionEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryOptionEditResult {
        try await document.libraryOptionHistory(handle, generation: expectedGeneration, undoing: true)
    }
    public func redoOptionEdit(_ handle: LibraryEditHandle, expectedGeneration: UInt64) async throws -> LibraryOptionEditResult {
        try await document.libraryOptionHistory(handle, generation: expectedGeneration, undoing: false)
    }
    public func takeUpdateReport(token: UUID) async throws -> LibraryUpdateReport? {
        try await document.libraryTakeUpdateReport(token)
    }
}

extension LibraryChoiceReport {
    var retainedBytes: Int {
        let rows: [[String:Any]] = changes.map { c in
            let place: String
            switch c.place { case .workspace(let id): place="workspace:"+id.uuidString; case .use(let app,let id): place=app+":"+id.uuidString }
            return ["place":place,"path":c.address.path.map(\.uuidString),"control":c.address.control.uuidString,
                "before":c.before.uuidString,"after":c.after.uuidString,"reason":c.reason.rawValue]
        }
        return (try? JSONSerialization.data(withJSONObject:["operation":operation.uuidString,"liveGeneration":String(liveGeneration),"changes":rows]).count) ?? Int.max
    }
}
extension LibraryUpdateReport {
    var retainedBytes: Int { choices.retainedBytes + capturedDigest.utf8.count + 128 }
}
extension LibraryUpdatePreview {
    var retainedBytes: Int {
        let rows: [[String:Any]] = removals.map { r in
            ["baseDefinition":r.base.definition.uuidString,"baseRevision":r.base.revision.uuidString,
             "path":r.address.path.map(\.uuidString),"control":r.address.control.uuidString,"schema":r.schema.map(\.uuidString),
             "removed":r.removed.uuidString,"replacement":r.replacement.uuidString]
        }
        let places = places.map { ["use":$0.use.uuidString,"path":$0.path.map(\.uuidString)] as [String:Any] }
        let metadata = (try? JSONSerialization.data(withJSONObject:["removals":rows,"places":places,"broken":brokenBindings.map(\.uuidString)]).count) ?? Int.max / 2
        return choices.retainedBytes + metadata + fingerprint.utf8.count + 512
    }
}

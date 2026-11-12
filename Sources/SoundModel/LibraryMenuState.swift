import Foundation

public struct LibraryMenuIdentity: Equatable, Sendable {
    public let ownerID: UUID
    public let binding: LibraryBinding
    public let reference: LibraryReference
    public init(ownerID: UUID, binding: LibraryBinding, reference: LibraryReference) {
        self.ownerID = ownerID; self.binding = binding; self.reference = reference
    }
}

/// Current consumer presentation. Persistence coverage is deliberately not part of this type.
public struct LibraryMenuState: Equatable, Sendable {
    public var transientPosition: LibraryControlAddress? = nil
    public var parameterPlans: [LibraryParameterPlan] = []
    public let ownerID: UUID
    public let liveGeneration: UInt64
    public let stateRevision: UInt64
    public let live: LibraryLiveState
    public let definitions: [LibraryDefinitionSummary]
    public let uses: [LibraryUseSummary]
    public let assignments: [LibraryAssignmentSummary]
    public var isEnabled: Bool { live.isEnabled }
    public var compareOriginal: Bool { live.compareOriginal }
    public var writing: Bool { live.writing }
    public var unresolved: Bool { live.unresolved }
    public var pendingCommit: UUID? { live.pendingCommit }

    public func identity(for binding: LibraryBinding) -> LibraryMenuIdentity? {
        guard assignments.contains(where: { $0.id == binding.assignment && $0.use == binding.use && $0.target == binding.target }),
              let use = uses.first(where: { $0.id == binding.use && $0.target == binding.target }) else { return nil }
        return LibraryMenuIdentity(ownerID: ownerID, binding: binding,
            reference: LibraryReference(definition: use.definition, revision: use.baseRevision))
    }

    public func applying(_ delta: LibraryMenuDelta) -> Self? {
        guard identity(for: delta.identity.binding) == delta.identity, live == delta.live,
              delta.baseGeneration == liveGeneration, delta.baseStateRevision == stateRevision,
              delta.liveGeneration >= liveGeneration,
              let useIndex = uses.firstIndex(where: { $0.id == delta.identity.binding.use }),
              let assignmentIndex = assignments.firstIndex(where: { $0.id == delta.identity.binding.assignment }) else { return nil }
        var uses = uses, assignments = assignments
        let old = uses[useIndex]
        uses[useIndex] = LibraryUseSummary(id: old.id, target: old.target, definition: old.definition,
            baseRevision: old.baseRevision, name: old.name, hasOwnName: old.hasOwnName,
            hasLocalDraft: old.hasLocalDraft, controls: old.controls,
            positions: delta.occurrences.first(where: { $0.path.isEmpty })?.positions ?? [:],
            occurrences: delta.occurrences, defaults: old.defaults, builtin: old.builtin,
            optionControls: delta.optionControls, directSliderControls: delta.directSliderControls)
        let assignment = assignments[assignmentIndex]
        assignments[assignmentIndex] = LibraryAssignmentSummary(isEnabled: delta.assignment.isEnabled,
            id: assignment.id, target: assignment.target, use: assignment.use,
            definition: assignment.definition, parts: delta.assignment.parts)
        var result = Self(ownerID: ownerID, liveGeneration: delta.liveGeneration, stateRevision: delta.stateRevision, live: delta.live,
            definitions: definitions, uses: uses, assignments: assignments)
        result.transientPosition = delta.transientPosition
        if delta.transientPosition != nil { result.parameterPlans = parameterPlans }
        return result
    }
}

public enum LibraryMenuAppliedOutcome: Equatable, Sendable {
    case changed, noChange
    public var mutation: LibraryLiveMutation { self == .changed ? .changed : .noChange }
}

public struct LibraryMenuDelta: Equatable, Sendable {
    public var transientPosition: LibraryControlAddress? = nil
    public let identity: LibraryMenuIdentity
    public let liveGeneration: UInt64
    public let baseGeneration: UInt64
    public let stateRevision: UInt64
    public let baseStateRevision: UInt64
    public let live: LibraryLiveState
    public let outcome: LibraryMenuAppliedOutcome
    public let occurrences: [LibraryOccurrenceSummary]
    public let optionControls: [LibraryOptionControl]
    public let directSliderControls: [LibraryControlAddress]?
    public let assignment: ListeningRenderAssignment
    public var positions: [LibraryControlAddress: LibraryPosition] {
        Dictionary(uniqueKeysWithValues: occurrences.flatMap { occurrence in
            occurrence.positions.map { (LibraryControlAddress(path: occurrence.path, control: $0.key), $0.value) }
        })
    }
}

public enum LibraryMenuMoveResult: Equatable, Sendable {
    case delta(LibraryMenuDelta)
    case fullRequired(LibraryLiveMutation, LibraryLiveState)
    case superseded
    public var outcome: LibraryLiveMutation {
        switch self {
        case .delta(let delta): return delta.outcome.mutation
        case .fullRequired(let outcome, _): return outcome
        case .superseded: return .superseded
        }
    }
}

extension SoundLibrarySession {
    public func menuState() async throws -> LibraryMenuState { try await document.libraryMenuState() }
    public func moveForMenu(_ address: LibraryControlAddress, expected: LibraryMenuIdentity,
                           optionGesture: LibraryOptionGesture? = nil, to value: LibraryPosition) async throws -> LibraryMenuMoveResult {
        try await document.libraryMenuMove(expected: expected, key: address.key, option: optionGesture, value: value)
    }
}

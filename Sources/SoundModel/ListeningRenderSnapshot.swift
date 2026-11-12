import Foundation

/// Control-rate transport, independent of library names, controls and decoration.
public struct ListeningRenderAssignment: Equatable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    public let isEnabled: Bool
    public let parts: [ListeningRenderPart]
    public init(id: UUID, bundleIdentifier: String, isEnabled: Bool, parts: [ListeningRenderPart]) {
        self.id = id; self.bundleIdentifier = bundleIdentifier; self.isEnabled = isEnabled; self.parts = parts
    }
    public init(legacy: ListeningAssignment) {
        self.init(id: legacy.id, bundleIdentifier: legacy.bundleIdentifier, isEnabled: legacy.isEnabled, parts: legacy.parts)
    }
}
public struct ListeningRenderSnapshot: Equatable, Sendable {
    public let isEnabled: Bool
    public let assignments: [ListeningRenderAssignment]
    public init(isEnabled: Bool, assignments: [ListeningRenderAssignment]) {
        self.isEnabled = isEnabled; self.assignments = assignments
    }
    public init(legacy: ListeningSnapshot) {
        self.init(isEnabled: legacy.isEnabled, assignments: legacy.assignments.map(ListeningRenderAssignment.init(legacy:)))
    }
    public init(library: LibrarySnapshot) {
        self.init(isEnabled: library.isEnabled, assignments: library.assignments.map {
            ListeningRenderAssignment(id: $0.id, bundleIdentifier: $0.target, isEnabled: $0.isEnabled, parts: $0.parts)
        })
    }
    /// Failure fallback can turn an admitted graph OFF, never turn it ON or substitute parts.
    public func restricting(to live: LibraryLiveState) -> Self {
        Self(isEnabled: isEnabled && live.isEnabled, assignments: assignments.map { old in
            let current = live.assignments.first { $0.binding.assignment == old.id && $0.binding.target == old.bundleIdentifier }
            return ListeningRenderAssignment(id: old.id, bundleIdentifier: old.bundleIdentifier,
                isEnabled: old.isEnabled && current?.isEnabled == true, parts: old.parts)
        })
    }
}

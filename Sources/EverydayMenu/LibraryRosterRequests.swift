import Foundation
import SoundModel

public enum LibraryRosterReceipt: Equatable, Sendable {
    case accepted(command: UUID, commit: UUID)
    case unresolved(command: UUID, commit: UUID)
    case refused(command: UUID, commit: UUID, reason: LibraryWriteRefusal)
    case failed(command: UUID)
    case blocked(command: UUID)
    case reconciled(command: UUID, commit: UUID, accepted: Bool)
}

/// Library mode only. Unlike legacy diagnostics, a snapshot never acknowledges uncertainty.
public struct LibraryRosterRequests: Equatable, Sendable {
    public enum Direction: Equatable, Sendable { case add, remove }
    public enum Phase: Equatable, Sendable {
        case issued
        case uncertain(commit: UUID)
        case accepted(commit: UUID)
    }
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let bundle: String
        public let direction: Direction
        public fileprivate(set) var phase: Phase
    }
    public private(set) var committed: Set<String> = []
    public private(set) var pending: [String: Request] = [:]
    private var bound: Set<UUID> = []
    public init() {}
    /// Bind synchronously before invoking/scheduling the command. Request IDs are single-use.
    @discardableResult
    public mutating func bind(_ id: UUID, bundle: String, direction: Direction) -> Bool {
        guard pending[bundle] == nil, committed.contains(bundle) == (direction == .remove),
              !bound.contains(id) else { return false }
        bound.insert(id)
        pending[bundle] = Request(id: id, bundle: bundle, direction: direction, phase: .issued)
        return true
    }
    public func isEnabled(_ bundle: String) -> Bool { pending[bundle] == nil }
    public mutating func update(_ presentation: LibraryMenuState) {
        committed = Set(presentation.assignments.map(\.target))
        settleAccepted()
    }
    public mutating func update(_ snapshot: LibrarySnapshot) {
        committed = Set(snapshot.assignments.map(\.target))
        settleAccepted()
    }
    public mutating func receive(_ receipt: LibraryRosterReceipt) {
        let id: UUID
        switch receipt {
        case .accepted(let command, _), .unresolved(let command, _), .refused(let command, _, _),
             .failed(let command), .blocked(let command), .reconciled(let command, _, _): id = command
        }
        guard let bundle = pending.first(where: { $0.value.id == id })?.key, var request = pending[bundle] else { return }
        switch receipt {
        case .accepted(_, let commit):
            switch request.phase {
            case .issued: request.phase = .accepted(commit: commit)
            case .uncertain(let held) where held == commit: request.phase = .accepted(commit: commit)
            case .accepted(let held) where held == commit: break
            default: return
            }
        case .unresolved(_, let commit):
            guard case .issued = request.phase else { return }
            request.phase = .uncertain(commit: commit)
        case .refused(_, let commit, _):
            if case .uncertain(let held) = request.phase, held != commit { return }
            guard case .accepted = request.phase else { pending.removeValue(forKey: bundle); return }
            return
        case .failed, .blocked:
            // Never acquire the model's unrelated blocking commit token.
            guard case .issued = request.phase else { return }
            pending.removeValue(forKey: bundle); return
        case .reconciled(_, let commit, let accepted):
            guard case .uncertain(let held) = request.phase, held == commit else { return }
            if !accepted { pending.removeValue(forKey: bundle); return }
            request.phase = .accepted(commit: commit)
        }
        pending[bundle] = request
        settleAccepted()
    }
    private mutating func settleAccepted() {
        for (bundle, request) in pending {
            guard case .accepted = request.phase else { continue }
            if committed.contains(bundle) == (request.direction == .add) { pending.removeValue(forKey: bundle) }
        }
    }
}

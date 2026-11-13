import Foundation
import SoundModel

public enum PositionDeliveryResult: Equatable {
    case applied, retainedInactive, requiresFull, closed
}

/// The control-rate entry has no lane construction, capture, start or retry capability.
struct PlaybackPositionDelivery {
    let snapshot: ListeningRenderSnapshot
    let running: Set<UUID>
    var starting: Set<UUID> = []
    let known: [UUID: String]

    @MainActor
    func apply(update: (ListeningRenderAssignment) throws -> Void,
               stop: (UUID) -> Void) -> PositionDeliveryResult {
        let present = Set(snapshot.assignments.map(\.id))
        let active = running.union(starting)
        for id in active where !present.contains(id) { stop(id) }
        var applied = false, needsFull = false
        for assignment in snapshot.assignments {
            guard known[assignment.id] == assignment.bundleIdentifier else {
                if active.contains(assignment.id) { stop(assignment.id) }
                needsFull = true; continue
            }
            guard snapshot.isEnabled && assignment.isEnabled else {
                if active.contains(assignment.id) { stop(assignment.id) }
                continue
            }
            guard running.contains(assignment.id) else { continue }
            do { try update(assignment); applied = true }
            catch { stop(assignment.id); needsFull = true }
        }
        return needsFull ? .requiresFull : applied ? .applied : .retainedInactive
    }
}

struct PlaybackStopResumePolicy {
    struct Stop: Sendable {
        let assignment: UUID
        let activation: UInt64
        let includesCurrentActivation: Bool
    }
    private struct Binding: Equatable {
        let bundle: String
        let enabled: Bool
    }
    private struct Scope: Equatable {
        let enabled: Bool
        let bindings: [UUID: Binding]
        init(_ snapshot: ListeningRenderSnapshot) {
            enabled = snapshot.isEnabled
            bindings = Dictionary(uniqueKeysWithValues: snapshot.assignments.map {
                ($0.id, Binding(bundle: $0.bundleIdentifier, enabled: $0.isEnabled))
            })
        }
    }
    private var activation: UInt64 = 0
    private var scope: Scope?
    mutating func activate(_ snapshot: ListeningRenderSnapshot) {
        activation &+= 1
        scope = Scope(snapshot)
    }
    func stopping(assignment: UUID, includesCurrentActivation: Bool) -> Stop {
        Stop(assignment: assignment, activation: activation, includesCurrentActivation: includesCurrentActivation)
    }
    func mayResume(_ stop: Stop, desired: ListeningRenderSnapshot) -> Bool {
        guard desired.isEnabled, scope?.enabled == true,
              let assignment = desired.assignments.first(where: { $0.id == stop.assignment }), assignment.isEnabled,
              scope?.bindings[stop.assignment] == Binding(bundle: assignment.bundleIdentifier, enabled: true) else { return false }
        return activation > stop.activation || stop.includesCurrentActivation && activation == stop.activation
    }
}

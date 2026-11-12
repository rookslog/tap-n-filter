import Foundation
import SoundModel

public enum PositionDeliveryResult: Equatable {
    case applied, retainedInactive, requiresFull, closed
}

/// The control-rate entry has no lane construction, capture, start or retry capability.
struct PlaybackPositionDelivery {
    let snapshot: ListeningRenderSnapshot
    let running: Set<UUID>
    let known: [UUID: String]

    @MainActor
    func apply(update: (ListeningRenderAssignment) throws -> Void,
               stop: (UUID) -> Void) -> PositionDeliveryResult {
        let present = Set(snapshot.assignments.map(\.id))
        for id in running where !present.contains(id) { stop(id) }
        var applied = false, needsFull = false
        for assignment in snapshot.assignments {
            guard known[assignment.id] == assignment.bundleIdentifier else {
                if running.contains(assignment.id) { stop(assignment.id) }
                needsFull = true; continue
            }
            guard snapshot.isEnabled && assignment.isEnabled else {
                if running.contains(assignment.id) { stop(assignment.id) }
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
    func stopping(includesCurrentActivation: Bool) -> Stop {
        Stop(activation: activation, includesCurrentActivation: includesCurrentActivation)
    }
    func mayResume(_ stop: Stop, desired: ListeningRenderSnapshot) -> Bool {
        desired.isEnabled && desired.assignments.contains(where: \.isEnabled)
            && scope == Scope(desired)
            && (activation > stop.activation || stop.includesCurrentActivation && activation == stop.activation)
    }
}

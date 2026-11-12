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

import Foundation
import SoundModel

struct TNFEditorLaneIdentity: Equatable {
    let token: LibraryEditorToken
    let generation: UInt64
    let path: [UUID]
    let binding: UUID
    let option: UUID?
}

struct TNFEditorPointRelease {
    let position: Double
    let lane: LibraryMappingLane
    let insertsWaypoint: Bool
    let stepJumps: [(Int, Double)]

    init(lane: LibraryMappingLane, sourceWaypoints: [Double], from: Double,
         to: Double, value: Double, snap: Double = 0.025) throws {
        guard to.isFinite, value.isFinite, (0...1).contains(to), (0...1).contains(value),
              lane.points.contains(where: { $0.position == from }) else { throw TNFEditorError.noLane }
        let nearest = sourceWaypoints.min { abs($0 - to) < abs($1 - to) }
        let destination = (from == 0 || from == 1) ? from : (nearest.flatMap { abs($0 - to) <= snap ? $0 : nil } ?? to)
        var points = lane.points.filter { $0.position != from && $0.position != destination }
        points.append(LibraryLanePoint(destination, value))
        points.sort { $0.position < $1.position }
        let old = try lane.stretches()
        let shapes = points.dropLast().map { left -> LibraryStretch in
            let origin = left.position == destination ? from : left.position
            if let i = lane.points.firstIndex(where: { $0.position == origin }), old.indices.contains(i) { return old[i].kind }
            return .curve
        }
        stepJumps = points.dropLast().enumerated().compactMap { index, left in
            let origin = left.position == destination ? from : left.position
            guard let i = lane.points.firstIndex(where: { $0.position == origin }), old.indices.contains(i),
                  old[i].kind == .step, old[i].jump != 0.5 else { return nil }
            return (index, old[i].jump)
        }
        self.position = destination
        self.lane = try LibraryMappingLane(points: points, stretches: shapes)
        insertsWaypoint = !sourceWaypoints.contains(destination)
    }
}

@MainActor extension TNFEditorCommands {
    func laneIdentity(_ binding: LibraryMappingSummary, option: UUID?) throws -> TNFEditorLaneIdentity {
        guard let token = adapter.token, let edit, projection?.snapshot.generation == edit.generation,
              projection?.mappings.bindings.contains(binding) == true else { throw TNFEditorError.noSelection }
        return TNFEditorLaneIdentity(token: token, generation: edit.generation, path: binding.path,
                                     binding: binding.id, option: option)
    }
    func checkLane(_ identity: TNFEditorLaneIdentity) throws {
        guard editing, canAuthor, adapter.token == identity.token,
              adapter.state.edit?.generation == identity.generation else { throw TNFEditorError.stale }
    }
    /// One release, one group. Pointer movement never reaches the owner.
    func releasePoint(_ identity: TNFEditorLaneIdentity, lane: LibraryMappingLane,
                      waypoints: [Double], from: Double, to: Double, value: Double) async throws {
        try checkLane(identity)
        let release = try TNFEditorPointRelease(lane: lane, sourceWaypoints: waypoints, from: from, to: to, value: value)
        if release.position == from {
            try await mapping(.point(binding: identity.binding, option: identity.option, position: from, value: value), path: identity.path)
            return
        }
        let gesture = UUID()
        _ = try await accept(adapter.barrier(identity.token, .begin(gesture)))
        do {
            if release.insertsWaypoint {
                _ = try await accept(adapter.submit(identity.token, command: .mapping(path: identity.path,
                    .insertPoint(binding: identity.binding, option: identity.option, position: release.position)), gesture: gesture))
            }
            _ = try await accept(adapter.submit(identity.token, command: .mapping(path: identity.path,
                .lane(binding: identity.binding, option: identity.option, lane: release.lane)), gesture: gesture))
            for (index, jump) in release.stepJumps {
                _ = try await accept(adapter.submit(identity.token, command: .mapping(path: identity.path,
                    .stretch(binding: identity.binding, option: identity.option, index: index, shape: .step, jump: jump)), gesture: gesture))
            }
            _ = try await accept(adapter.barrier(identity.token, .end(gesture)))
        } catch {
            if adapter.token == identity.token { _ = try? await accept(adapter.barrier(identity.token, .cancel(gesture))) }
            throw error
        }
        try await refresh()
    }
    func removePoint(_ identity: TNFEditorLaneIdentity, lane: LibraryMappingLane, position: Double) async throws {
        try checkLane(identity)
        let points = lane.points.filter { $0.position != position }, stretches = try lane.stretches()
        let indices = points.dropLast().compactMap { point in lane.points.firstIndex { $0.position == point.position } }
        let result = try LibraryMappingLane(points: points, stretches: indices.map { stretches[$0].kind })
        let gesture = UUID()
        _ = try await accept(adapter.barrier(identity.token, .begin(gesture)))
        do {
            _ = try await accept(adapter.submit(identity.token, command: .mapping(path: identity.path,
                .lane(binding: identity.binding, option: identity.option, lane: result)), gesture: gesture))
            for (new, old) in indices.enumerated() where stretches[old].kind == .step && stretches[old].jump != 0.5 {
                _ = try await accept(adapter.submit(identity.token, command: .mapping(path: identity.path,
                    .stretch(binding: identity.binding, option: identity.option, index: new, shape: .step, jump: stretches[old].jump)), gesture: gesture))
            }
            _ = try await accept(adapter.barrier(identity.token, .end(gesture)))
        } catch {
            _ = try? await accept(adapter.barrier(identity.token, .cancel(gesture))); throw error
        }
        try await refresh()
    }
    func setByEar(_ binding: LibraryMappingSummary, option: UUID?, at position: Double, value: Double) async throws {
        guard editing, let token = adapter.token,
              let lane = option.flatMap({ binding.cases[$0] }) ?? binding.lane,
              case .setting(let part, let parameter) = binding.target, binding.path.isEmpty,
              let setting = edit?.parts.first(where: { $0.id == part })?.settings.first(where: { $0.parameter == parameter }) else { throw TNFEditorError.noLane }
        // Fold the setting's authored nudge into this response, not the other drivers' contribution.
        let response = try lane.value(at: position) + value - setting.unadjustedSum
        guard response.isFinite, (0...1).contains(response) else { throw LibraryError.unsupportedEdit }
        let physical = try setting.specification.physical(value), gesture = UUID()
        _ = try await accept(adapter.barrier(token, .begin(gesture)))
        do {
            if !binding.sourceWaypoints.contains(position) {
                _ = try await accept(adapter.submit(token, command: .mapping(path: binding.path,
                    .insertPoint(binding: binding.id, option: option, position: position)), gesture: gesture))
            }
            _ = try await accept(adapter.submit(token, command: .mapping(path: binding.path,
                .point(binding: binding.id, option: option, position: position, value: response)), gesture: gesture))
            _ = try await accept(adapter.submit(token, command: .setPhysical(part: part, parameter: parameter, value: physical), gesture: gesture))
            _ = try await accept(adapter.barrier(token, .end(gesture)))
        } catch {
            _ = try? await accept(adapter.barrier(token, .cancel(gesture))); throw error
        }
        try await refresh()
    }
}

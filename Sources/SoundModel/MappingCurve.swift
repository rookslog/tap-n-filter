import Foundation

enum StretchShape: String, CaseIterable, Codable, Sendable {
    case curve, straight, ease, step
}

struct Waypoint: Equatable, Sendable, Codable {
    let position: Position
    let value: Position
}

struct MappingCurve: Equatable, Sendable, Codable {
    private struct Segment: Equatable, Sendable, Codable {
        let shape: StretchShape
        let first: Position
        let second: Position
        let jump: Position
    }

    let waypoints: [Waypoint]
    private let segments: [Segment]

    init(waypoints: [Waypoint], shapes: [StretchShape]) throws {
        try Self.validate(waypoints)
        guard shapes.count == waypoints.count - 1 else { throw SoundModelError.invalidCurve }
        let secants = zip(waypoints, waypoints.dropFirst()).map {
            ($1.value.value - $0.value.value) / ($1.position.value - $0.position.value)
        }
        guard secants.allSatisfy(\.isFinite) else { throw SoundModelError.invalidCurve }

        func slope(segment: Int, point: Int) -> Double {
            let own = secants[segment]
            let other = point == segment ? segment - 1 : segment + 1
            guard shapes.indices.contains(other) else {
                guard secants.count > 1 else { return own }
                let neighbor = point == 0 ? 1 : secants.count - 2
                let h = waypoints[segment + 1].position.value - waypoints[segment].position.value
                let h1 = waypoints[neighbor + 1].position.value - waypoints[neighbor].position.value
                let candidate = own + (own - secants[neighbor]) * (h / (h + h1))
                return candidate * own <= 0 ? 0 : copysign(min(abs(candidate), 2 * abs(own)), own)
            }
            switch shapes[other] {
            case .curve:
                let next = secants[other]
                guard own != 0, next != 0, (own > 0) == (next > 0) else { return 0 }
                let h = waypoints[segment + 1].position.value - waypoints[segment].position.value
                let h1 = waypoints[other + 1].position.value - waypoints[other].position.value
                let weighted = own * (h1 / (h + h1)) + next * (h / (h + h1))
                return copysign(min(2 * abs(own), 2 * abs(next), abs(weighted)), own)
            case .straight:
                let next = secants[other]
                guard own != 0, next != 0, (own > 0) == (next > 0) else { return 0 }
                return copysign(min(abs(next), 3 * abs(own)), own)
            case .ease, .step:
                return 0
            }
        }

        self.waypoints = waypoints
        segments = try shapes.indices.map { index in
            let a = waypoints[index]
            let b = waypoints[index + 1]
            let width = b.position.value - a.position.value
            let first: Double
            let second: Double
            switch shapes[index] {
            case .curve:
                first = a.value.value + slope(segment: index, point: index) * width / 3
                second = b.value.value - slope(segment: index, point: index + 1) * width / 3
            case .straight:
                first = a.value.value + (b.value.value - a.value.value) / 3
                second = b.value.value - (b.value.value - a.value.value) / 3
            case .ease, .step:
                first = a.value.value
                second = b.value.value
            }
            func coefficient(_ value: Double) throws -> Position {
                let lower = min(a.value.value, b.value.value)
                let upper = max(a.value.value, b.value.value)
                let roundoff = 16 * Double.ulpOfOne
                guard value.isFinite, value >= lower - roundoff, value <= upper + roundoff else {
                    throw SoundModelError.invalidCurve
                }
                // A tangent capped at exactly 3× the secant can miss its endpoint by an ulp.
                return try Position(min(upper, max(lower, value)))
            }
            return Segment(
                shape: shapes[index], first: try coefficient(first),
                second: try coefficient(second), jump: .interpolated(0.5))
        }
        try validateSegments()
    }

    private init(waypoints: [Waypoint], segments: [Segment]) throws {
        try Self.validate(waypoints)
        self.waypoints = waypoints
        self.segments = segments
        try validateSegments()
    }

    private static func validate(_ waypoints: [Waypoint]) throws {
        guard waypoints.count >= 2, waypoints.first?.position == .start,
            waypoints.last?.position == .end,
            zip(waypoints, waypoints.dropFirst()).allSatisfy({ $0.position.value < $1.position.value })
        else { throw SoundModelError.invalidCurve }
    }

    private func validateSegments() throws {
        guard segments.count == waypoints.count - 1 else { throw SoundModelError.invalidCurve }
        for (index, segment) in segments.enumerated() where segment.shape != .step {
            let a = waypoints[index].value.value
            let b = waypoints[index + 1].value.value
            let lower = min(a, b)
            let upper = max(a, b)
            guard (lower...upper).contains(segment.first.value),
                (lower...upper).contains(segment.second.value)
            else { throw SoundModelError.invalidCurve }
            if segment.shape == .straight {
                let first = a + (b - a) / 3
                let second = b - (b - a) / 3
                guard abs(segment.first.value - first) <= 16 * Double.ulpOfOne,
                    abs(segment.second.value - second) <= 16 * Double.ulpOfOne
                else { throw SoundModelError.invalidCurve }
            }
            let direction = b >= a ? 1.0 : -1.0
            let d0 = direction * (segment.first.value - a)
            let d1 = direction * (segment.second.value - segment.first.value)
            let d2 = direction * (b - segment.second.value)
            let quadratic = d0 - 2 * d1 + d2
            let linear = 2 * (d1 - d0)
            if quadratic > 0 {
                let u = -linear / (2 * quadratic)
                if (0...1).contains(u), quadratic * u * u + linear * u + d0 < -1e-12 {
                    throw SoundModelError.invalidCurve
                }
            }
        }
    }

    func value(at position: Position) -> Position {
        if position == .end { return waypoints[waypoints.count - 1].value }
        let index = waypoints.indices.dropLast().last { waypoints[$0].position.value <= position.value } ?? 0
        let a = waypoints[index]
        let b = waypoints[index + 1]
        let segment = segments[index]
        if a.value == b.value, segment.first == a.value, segment.second == a.value {
            return a.value
        }
        let u = (position.value - a.position.value) / (b.position.value - a.position.value)
        if u == 0 { return a.value }
        if segment.shape == .step {
            let jump = a.position.value + segment.jump.value * (b.position.value - a.position.value)
            return position.value < jump ? a.value : b.value
        }
        let v = 1 - u
        let result =
            v * v * v * a.value.value + 3 * v * v * u * segment.first.value
            + 3 * v * u * u * segment.second.value + u * u * u * b.value.value
        // Bezier coefficients are bounded at construction, so only roundoff can leave 0...1.
        return Position.interpolated(result)
    }

    func insertingWaypoint(at position: Position) throws -> MappingCurve {
        guard !waypoints.contains(where: { $0.position == position }) else {
            throw SoundModelError.duplicateWaypoint
        }
        guard
            let index = waypoints.indices.dropLast().first(where: {
                waypoints[$0].position.value < position.value
                    && position.value < waypoints[$0 + 1].position.value
            })
        else { throw SoundModelError.invalidCurve }
        let a = waypoints[index]
        let b = waypoints[index + 1]
        let segment = segments[index]
        let u = (position.value - a.position.value) / (b.position.value - a.position.value)
        func mix(_ x: Position, _ y: Position) throws -> Position {
            try Position.evaluated(x.value + (y.value - x.value) * u)
        }
        let value = value(at: position)
        let left: Segment
        let right: Segment
        if segment.shape == .step {
            let jump = a.position.value + segment.jump.value * (b.position.value - a.position.value)
            if position.value < jump {
                left = Segment(shape: .step, first: a.value, second: value, jump: .end)
                right = Segment(
                    shape: .step, first: value, second: b.value,
                    jump: try Position.evaluated(
                        (jump - position.value) / (b.position.value - position.value)))
            } else {
                left = Segment(
                    shape: .step, first: a.value, second: value,
                    jump: try Position.evaluated(
                        (jump - a.position.value) / (position.value - a.position.value)))
                right = Segment(shape: .step, first: value, second: b.value, jump: .end)
            }
        } else {
            let p01 = try mix(a.value, segment.first)
            let p12 = try mix(segment.first, segment.second)
            let p23 = try mix(segment.second, b.value)
            left = Segment(shape: segment.shape, first: p01, second: try mix(p01, p12), jump: .end)
            right = Segment(shape: segment.shape, first: try mix(p12, p23), second: p23, jump: .end)
        }
        var points = waypoints
        var pieces = segments
        points.insert(Waypoint(position: position, value: value), at: index + 1)
        pieces.replaceSubrange(index...index, with: [left, right])
        return try MappingCurve(waypoints: points, segments: pieces)
    }

    // Persisted segments are authoritative. Rebuilding the whole curve would
    // discard exact subdivisions made by insertingWaypoint.
    func settingValue(_ value: Position, at position: Position) throws -> MappingCurve {
        guard let index = waypoints.firstIndex(where: { $0.position == position }) else {
            throw SoundModelError.invalidWaypoints
        }
        guard waypoints[index].value != value else { return self }
        var points = waypoints
        points[index] = Waypoint(position: position, value: value)
        let candidate = try MappingCurve(waypoints: points, shapes: segments.map(\.shape))
        var pieces = segments
        for segmentIndex in segments.indices where segmentIndex == index || segmentIndex + 1 == index {
            let regenerated = candidate.segments[segmentIndex]
            pieces[segmentIndex] = Segment(
                shape: regenerated.shape, first: regenerated.first, second: regenerated.second,
                jump: segments[segmentIndex].jump)
        }
        return try MappingCurve(waypoints: points, segments: pieces)
    }

    func settingStretch(index: Int, shape: StretchShape, jump: Position) throws -> Self {
        guard segments.indices.contains(index) else { throw SoundModelError.invalidCurve }
        var shapes = segments.map(\.shape); shapes[index] = shape
        let candidate = try Self(waypoints: waypoints, shapes: shapes)
        var changed = segments, segment = candidate.segments[index]
        segment = Segment(shape: segment.shape, first: segment.first, second: segment.second, jump: jump)
        changed[index] = segment
        return try Self(waypoints: waypoints, segments: changed)
    }

    func appendCanonical(to stream: inout AuthoredStream) {
        stream.count(waypoints.count)
        for point in waypoints { stream.number(point.position.value); stream.number(point.value.value) }
        stream.count(segments.count)
        for segment in segments {
            stream.text(segment.shape.rawValue)
            stream.number(segment.first.value); stream.number(segment.second.value)
            stream.number(segment.jump.value)
        }
    }

    private enum CodingKeys: CodingKey { case waypoints, segments }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            waypoints: container.decode([Waypoint].self, forKey: .waypoints),
            segments: container.decode([Segment].self, forKey: .segments))
    }
}

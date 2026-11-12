import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct MappingCurveCases: Sendable {
    func test_constant_spans_preserve_exact_endpoint_bits() throws {
        let normalized320 = log(320.0 / 20) / log(1000.0)
        for shape in StretchShape.allCases {
            for constant in [0.0, 1.0, 0.1, 0.5, normalized320] {
                let curve = try MappingCurve(
                    waypoints: [point(0, constant), point(1, constant)], shapes: [shape])
                let split = try curve.insertingWaypoint(at: Position(0.371))
                for position in [0.0, 0.03, 0.17, 0.371, 0.5, 5.0 / 6, 11.0 / 12, 0.999, 1] {
                    for candidate in [curve, split] {
                        let actual = candidate.value(at: try Position(position)).value
                        try requireEqual(actual.bitPattern, constant.bitPattern,
                            "constant \(shape) \(constant) at \(position)")
                    }
                }
            }
        }
        let staged = try MappingCurve(
            waypoints: [point(0, 0.8), point(2.0 / 3, normalized320), point(1, normalized320)],
            shapes: [.straight, .straight])
        for position in [2.0 / 3, 5.0 / 6, 11.0 / 12, 1] {
            try requireEqual(staged.value(at: try Position(position)).value.bitPattern,
                normalized320.bitPattern, "E1 normalized 320Hz hold at \(position)")
        }
    }

    private struct Random {
        var state: UInt64 = 20_261_028
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    private func point(_ x: Double, _ y: Double) throws -> Waypoint {
        try Waypoint(position: Position(x), value: Position(y))
    }

    private func makeCurve(_ points: [Waypoint], _ shapes: [StretchShape], context: String) throws
        -> MappingCurve
    {
        do { return try MappingCurve(waypoints: points, shapes: shapes) } catch {
            throw ContractFailure(description: "\(context): \(error), points \(points), shapes \(shapes)")
        }
    }

    func test_m1_m2_m3_m5_on_3000_deterministic_random_curves() throws {
        var random = Random()
        for trial in 0..<3000 {
            let count = 2 + Int(random.next() * 6)
            let positions = [0.0] + (0..<(count - 2)).map { _ in random.next() }.sorted() + [1.0]
            let points = try positions.map { try point($0, random.next()) }
            let shapes = (0..<(count - 1)).map { _ in StretchShape.allCases[Int(random.next() * 4)] }
            let curve = try makeCurve(points, shapes, context: "M1-M5 trial \(trial)")
            for point in points {
                try requireEqual(
                    curve.value(at: point.position).value, point.value.value, accuracy: 1e-12,
                    "M2 trial \(trial)")
            }
            for (index, pair) in zip(points, points.dropFirst()).enumerated() {
                let (a, b) = pair
                let rise = b.value.value - a.value.value
                var previous = a.value.value
                for step in 1...128 {
                    let x = a.position.value + (b.position.value - a.position.value) * Double(step) / 128
                    let value = curve.value(at: try Position(x)).value
                    try requireTrue((0...1).contains(value), "M5 trial \(trial)")
                    if rise >= 0 {
                        try requireAtLeast(value + 1e-12, previous, "M1 trial \(trial)")
                    } else {
                        try requireAtMost(value - 1e-12, previous, "M1 trial \(trial)")
                    }
                    if shapes[index] != .step {
                        try requireAtMost(
                            abs(value - previous), 10 * abs(rise) / 128 + 1e-12,
                            "M3 trial \(trial)")
                    }
                    previous = value
                }
            }
        }
    }

    func test_m4_insertion_preserves_every_shape_and_step_jump() throws {
        var random = Random()
        for trial in 0..<2000 {
            let middle = 0.1 + random.next() * 0.8
            let points = try [point(0, random.next()), point(middle, random.next()), point(1, random.next())]
            let shapes = (0..<2).map { _ in StretchShape.allCases[Int(random.next() * 4)] }
            let before = try makeCurve(points, shapes, context: "M4 construction trial \(trial)")
            let at = try Position(0.01 + random.next() * 0.98)
            let after: MappingCurve
            do { after = try before.insertingWaypoint(at: at) } catch {
                throw ContractFailure(
                    description:
                        "M4 insertion trial \(trial): \(error), at \(at), points \(points), shapes \(shapes)")
            }
            try requireEqual(after.waypoints.count, before.waypoints.count + 1)
            try requireEqual(after.value(at: at).value, before.value(at: at).value, accuracy: 1e-12)
            for step in 0...400 {
                let position = try Position(Double(step) / 400)
                try requireEqual(
                    before.value(at: position).value, after.value(at: position).value,
                    accuracy: 1e-12, "M4 trial \(trial), x \(position.value)")
            }
            let restored = try JSONDecoder().decode(MappingCurve.self, from: JSONEncoder().encode(after))
            try requireEqual(restored, after)
        }
    }

    func test_step_insertion_at_before_and_after_jump_keeps_the_jump() throws {
        let curve = try MappingCurve(waypoints: [point(0, 0.2), point(1, 0.8)], shapes: [.step])
        try requireEqual(curve.value(at: try Position(0.49)).value, 0.2)
        try requireEqual(curve.value(at: try Position(0.5)).value, 0.8)
        for at in [0.25, 0.5, 0.75] {
            let split = try curve.insertingWaypoint(at: Position(at))
            for position in [0.0, 0.249, 0.25, 0.49, 0.5, 0.501, 0.75, 1.0] {
                try requireEqual(
                    split.value(at: try Position(position)), curve.value(at: try Position(position)))
            }
        }
    }

    func test_invalid_curves_and_duplicate_insertions_are_rejected() throws {
        let start = try point(0, 0)
        let end = try point(1, 1)
        for points in [[], [start], [end, start], [start, start, end], [try point(0.1, 0), end]] {
            try requireThrows(try MappingCurve(waypoints: points, shapes: [.straight]))
        }
        try requireThrows(try MappingCurve(waypoints: [start, end], shapes: []))
        let valid = try MappingCurve(waypoints: [start, end], shapes: [.straight])
        try requireThrows(try valid.insertingWaypoint(at: .start))
        try requireThrows(try valid.insertingWaypoint(at: .end))
        var object = try requireValue(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["segments"] = []
        try requireThrows(
            try JSONDecoder().decode(MappingCurve.self, from: JSONSerialization.data(withJSONObject: object)))
        object = try requireValue(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["segments"] = [["shape": "curve", "first": 1.0, "second": 0.0, "jump": 0.5]]
        object["waypoints"] = [["position": 0.0, "value": 0.4], ["position": 1.0, "value": 0.6]]
        try requireThrows(
            try JSONDecoder().decode(MappingCurve.self, from: JSONSerialization.data(withJSONObject: object)))
        object = try requireValue(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["segments"] = [["shape": "straight", "first": 0.8, "second": 0.9, "jump": 0.5]]
        try requireThrows(
            try JSONDecoder().decode(MappingCurve.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}

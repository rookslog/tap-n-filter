import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct ReviewResponseCases: Sendable {
    func test_local_curve_edit_keeps_nonincident_split_stretches() throws {
        let original = try MappingCurve(
            waypoints: zip([0.0, 0.25, 0.5, 0.75, 1.0], [0.1, 0.8, 0.2, 0.4, 0.9]).map {
                try Waypoint(position: Position($0.0), value: Position($0.1))
            }, shapes: [.curve, .curve, .curve, .curve])
        let split = try original.insertingWaypoint(at: Position(0.1))
        let edited = try split.settingValue(Position(0.6), at: Position(0.75))
        try requireEqual(edited.value(at: Position(0.75)), Position(0.6))
        for index in 0...500 {
            let position = try Position(Double(index) / 1000)
            try requireEqual(edited.value(at: position), split.value(at: position))
        }
        try requireEqual(try split.settingValue(Position(0.4), at: Position(0.75)), split)
        try requireThrows(try split.settingValue(.start, at: Position(0.3)))
        let bytes = try JSONEncoder().encode(edited)
        try requireEqual(try JSONDecoder().decode(MappingCurve.self, from: bytes), edited)
    }

    func test_local_edits_keep_mapping_laws_and_step_jump() throws {
        for shape in StretchShape.allCases {
            for value in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let curve = try MappingCurve(
                    waypoints: [
                        Waypoint(position: .start, value: Position(0.2)),
                        Waypoint(position: Position(0.4), value: Position(0.7)),
                        Waypoint(position: .end, value: Position(0.8)),
                    ], shapes: [shape, shape]
                )
                .insertingWaypoint(at: Position(0.1))
                let edited = try curve.settingValue(Position(value), at: Position(0.4))
                try requireEqual(edited.value(at: Position(0.4)), Position(value))
                // The nonincident first split segment must stay exact for every shape.
                for index in 0...100 {
                    let x = try Position(Double(index) / 1000)
                    try requireEqual(edited.value(at: x), curve.value(at: x))
                }
                for (a, b) in zip(edited.waypoints, edited.waypoints.dropFirst()) {
                    var previous = edited.value(at: a.position).value
                    for sample in 1...100 {
                        let x = try Position(
                            a.position.value + (b.position.value - a.position.value) * Double(sample) / 100)
                        let current = edited.value(at: x).value
                        try requireAtLeast(current, min(a.value.value, b.value.value) - 1e-12)
                        try requireAtMost(current, max(a.value.value, b.value.value) + 1e-12)
                        if b.value.value >= a.value.value {
                            try requireAtLeast(current, previous - 1e-12)
                        } else {
                            try requireAtMost(current, previous + 1e-12)
                        }
                        if shape != .step {
                            try requireAtMost(
                                abs(current - previous), abs(b.value.value - a.value.value) / 10 + 1e-12)
                        }
                        previous = current
                    }
                }
                if shape == .step {
                    // Originally .4...1 jumps at .7; a value edit must not move it.
                    try requireEqual(edited.value(at: Position(0.699)), Position(value))
                    try requireEqual(edited.value(at: Position(0.7)), Position(0.8))
                }
            }
        }
    }

    func test_xy_waypoints_are_independent_and_m6_uses_source_axis() throws {
        let key = try ParameterKey("gain")
        let part = SoundPart(
            id: PartID(), type: "gain", settings: [ParameterSetting(key: key, position: .start)])
        let control = SoundControl(
            id: ControlID(), face: .xy,
            position: .xy(x: try Position(0.5), y: try Position(0.2)),
            waypoints: .xy(x: [.start, try Position(0.5), .end], y: [.start, .end]))
        let curve = try MappingCurve(
            waypoints: [Waypoint(position: .start, value: .start), Waypoint(position: .end, value: .end)],
            shapes: [.straight]
        ).insertingWaypoint(at: Position(0.5))
        let mapping = ParameterMapping(
            control: control.id, axis: .x, part: part.id, parameter: key, curve: curve)
        let block = SoundBlock(pieces: [.part(part)], controls: [control], mappings: [mapping])
        let catalog = [PartDescriptor(type: "gain", parameters: [key])]
        let root = RootUseID()
        let result = try CompiledSound(block: block, root: root, catalog: catalog)
        try requireEqual(result.targets.values.first?.value, 0.5)
        let bytes = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(SoundBlock.self, from: bytes)
        try requireEqual(try CompiledSound(block: decoded, root: root, catalog: catalog), result)
        let wrongAxis = ParameterMapping(
            control: control.id, axis: .y, part: part.id, parameter: key, curve: curve)
        try requireThrows(
            try CompiledSound(
                block: SoundBlock(pieces: [.part(part)], controls: [control], mappings: [wrongAxis]),
                root: root, catalog: catalog)
        ) { error in
            try requireEqual(error as? SoundModelError, .invalidWaypoints)
        }
        for points in [
            ControlWaypoints.scalar([.start, .end]),
            .xy(x: [.start, .end], y: [.start, try Position(0.5)]),
            .xy(x: [.start, .start, .end], y: [.start, .end]),
        ] {
            let invalid = SoundControl(
                id: control.id, face: .xy, position: control.position, waypoints: points)
            try requireThrows(try invalid.validate())
        }
    }

    func test_choice_exact_halfway_ties_take_higher_option() throws {
        for count in [2, 3, 5, 17] {
            let options = (0..<count).map { _ in OptionID() }
            let choice = try Choice(options: options)
            for index in 0..<(count - 1) {
                let midpoint = try Position((Double(index) + 0.5) / Double(count - 1))
                try requireEqual(choice.option(at: midpoint), options[index + 1])
            }
        }
    }
}

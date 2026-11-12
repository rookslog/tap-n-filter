import Foundation

#if canImport(SoundModel)
    @testable import SoundModel
#endif

struct CompiledSoundCases: Sendable {
    private var key: ParameterKey { try! ParameterKey("gain") }
    private var catalog: [PartDescriptor] { [PartDescriptor(type: "tnf.gain", parameters: [key])] }

    private func part(_ value: Double = 0.5, id: PartID = PartID()) throws -> SoundPart {
        try SoundPart(
            id: id, type: "tnf.gain", settings: [ParameterSetting(key: key, position: Position(value))])
    }

    private func block(
        _ pieces: [BlockPiece], controls: [SoundControl] = [], mappings: [ParameterMapping] = []
    ) -> SoundBlock {
        SoundBlock(pieces: pieces, controls: controls, mappings: mappings)
    }

    private func curve(_ a: Double, _ b: Double) throws -> MappingCurve {
        try MappingCurve(
            waypoints: [
                Waypoint(position: .start, value: Position(a)),
                Waypoint(position: .end, value: Position(b)),
            ], shapes: [.straight])
    }

    func test_nested_mixed_order_roundtrips_and_addresses_survive_reorder() throws {
        let root = RootUseID()
        let site = UseSiteID()
        let a = try part()
        let b = try part()
        let c = try part()
        let child = BlockPiece.block(BlockUse(site: site, content: block([.part(b)])))
        let first = block([.part(c), child, .part(a)])
        let bytes = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode(SoundBlock.self, from: bytes)
        let original = try CompiledSound(block: first, root: root, catalog: catalog)
        let roundtrip = try CompiledSound(block: restored, root: root, catalog: catalog)
        try requireEqual(roundtrip, original)
        try requireEqual(roundtrip.parts.map(\.address.part), [c.id, b.id, a.id])
        let reordered = try CompiledSound(
            block: block([child, .part(a), .part(c)]), root: root, catalog: catalog)
        try requireEqual(reordered.parts.map(\.address.part), [b.id, a.id, c.id])
        try requireEqual(reordered.targets, original.targets)
        try requireEqual(original.parts[1].address.occurrence.path, [site])
    }

    func test_two_occurrences_of_one_part_keep_independent_addresses() throws {
        let part = try part()
        let root = RootUseID()
        let uses = (0..<2).map { _ in
            BlockPiece.block(BlockUse(site: UseSiteID(), content: block([.part(part)])))
        }
        let compiled = try CompiledSound(block: block(uses), root: root, catalog: catalog)
        try requireEqual(compiled.targets.count, 2)
        try requireDifferent(compiled.parts[0].address, compiled.parts[1].address)
        let anotherRoot = try CompiledSound(block: block(uses), root: RootUseID(), catalog: catalog)
        try requireTrue(Set(compiled.targets.keys).isDisjoint(with: anotherRoot.targets.keys))
    }

    func test_multiple_mappings_add_relative_to_baseline_then_clamp() throws {
        let part = try part(0.5)
        let a = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.end), waypoints: .scalar([.start, .end]))
        let b = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.end), waypoints: .scalar([.start, .end]))
        for (end, expected) in [(0.8, 1.0), (0.2, 0.0), (0.6, 0.7)] {
            let mappings = try [a, b].map {
                ParameterMapping(
                    control: $0.id, axis: .value, part: part.id, parameter: key, curve: try curve(0.5, end))
            }
            let compiled = try CompiledSound(
                block: block([.part(part)], controls: [a, b], mappings: mappings),
                root: RootUseID(), catalog: catalog)
            try requireEqual(requireValue(compiled.targets.values.first).value, expected, accuracy: 1e-12)
        }
    }

    func test_a19_choice_and_both_xy_axes_compile_from_normalized_positions() throws {
        let choice = try Choice(options: [OptionID(), OptionID(), OptionID(), OptionID(), OptionID()])
        let part = try part(0)
        let pick = SoundControl(
            id: ControlID(), face: .choice(choice), position: .scalar(try Position(0.76)),
            waypoints: .scalar(choice.positions))
        let mapping = try ParameterMapping(
            control: pick.id, axis: .value, part: part.id, parameter: key,
            curve: curve(0, 1))
        let chosen = try CompiledSound(
            block: block([.part(part)], controls: [pick], mappings: [mapping]),
            root: RootUseID(), catalog: catalog)
        try requireEqual(chosen.targets.values.first?.value, 0.75)
        let xy = SoundControl(
            id: ControlID(), face: .xy,
            position: .xy(x: try Position(0.2), y: try Position(0.3)),
            waypoints: .xy(x: [.start, .end], y: [.start, .end]))
        let axes = try [ControlAxis.x, .y].map {
            ParameterMapping(control: xy.id, axis: $0, part: part.id, parameter: key, curve: try curve(0, 1))
        }
        let result = try CompiledSound(
            block: block([.part(part)], controls: [xy], mappings: axes),
            root: RootUseID(), catalog: catalog)
        try requireEqual(result.targets.values.first?.value, 0.5)
    }

    func test_m6_rejects_curve_points_outside_control_waypoints() throws {
        let part = try part()
        let control = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.start), waypoints: .scalar([.start, .end]))
        let curve = try curve(0, 1).insertingWaypoint(at: Position(0.4))
        let mapping = ParameterMapping(
            control: control.id, axis: .value, part: part.id, parameter: key, curve: curve)
        try requireThrows(
            try CompiledSound(
                block: block([.part(part)], controls: [control], mappings: [mapping]),
                root: RootUseID(), catalog: catalog)
        ) { error in
            try requireEqual(error as? SoundModelError, .invalidWaypoints)
        }
    }

    func test_missing_unknown_and_duplicate_parameters_never_default() throws {
        let id = PartID()
        let setting = try part().settings[0]
        for settings in [
            [], [setting, setting], [ParameterSetting(key: try ParameterKey("unknown"), position: .start)],
        ] {
            let invalid = SoundPart(id: id, type: "tnf.gain", settings: settings)
            try requireThrows(
                try CompiledSound(block: block([.part(invalid)]), root: RootUseID(), catalog: catalog))
        }
        let unknown = SoundPart(id: id, type: "unknown", settings: [setting])
        try requireThrows(
            try CompiledSound(block: block([.part(unknown)]), root: RootUseID(), catalog: catalog))
        try requireThrows(try CompiledSound(block: block([]), root: RootUseID(), catalog: catalog + catalog))
    }

    func test_duplicate_parts_sites_controls_and_mappings_are_rejected() throws {
        let part = try part()
        let control = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.start), waypoints: .scalar([.start, .end]))
        let mapping = try ParameterMapping(
            control: control.id, axis: .value, part: part.id, parameter: key, curve: curve(0, 1))
        let child = BlockPiece.block(BlockUse(site: UseSiteID(), content: block([])))
        for invalid in [
            block([.part(part), .part(part)]), block([child, child]),
            block([.part(part)], controls: [control, control]),
            block([.part(part)], controls: [control], mappings: [mapping, mapping]),
        ] {
            try requireThrows(try CompiledSound(block: invalid, root: RootUseID(), catalog: catalog))
        }
    }

    func test_unknown_references_and_mismatched_control_axes_are_rejected() throws {
        let part = try part()
        let control = SoundControl(
            id: ControlID(), face: .slider, position: .scalar(.start), waypoints: .scalar([.start, .end]))
        for (id, axis, target) in [
            (ControlID(), ControlAxis.value, part.id),
            (control.id, .x, part.id), (control.id, .value, PartID()),
        ] {
            let mapping = try ParameterMapping(
                control: id, axis: axis, part: target, parameter: key, curve: curve(0, 1))
            try requireThrows(
                try CompiledSound(
                    block: block([.part(part)], controls: [control], mappings: [mapping]),
                    root: RootUseID(), catalog: catalog))
        }
    }
}

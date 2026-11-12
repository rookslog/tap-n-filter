import Foundation

struct QuickMenuEveryday: BuiltinSound {
    let kind = BuiltinBlock.everyday
    let root: RootUseID
    let definition: BlockDefinition
    let presentation: [ListeningControl]
    private let legacy: Everyday

    init() throws {
        legacy = try Everyday()
        root = legacy.root
        func id<Kind>(_ byte: UInt8) -> EntityID<Kind> {
            EntityID(UUID(uuid: (0x54, 0x4E, 0x46, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
        }
        let promoted = try legacy.definition.content.promoted()
        let pieces = try promoted.pieces.map { piece -> BlockPiece in
            guard case .part(let part) = piece, part.type == "reverb" else { return piece }
            return .part(SoundPart(id: part.id, type: "sizedReverb", settings: part.settings + [
                ParameterSetting(key: try ParameterKey("roomSize"), position: try Position(0.5))]))
        }
        let parts = pieces.compactMap { piece -> SoundPart? in
            if case .part(let part) = piece { return part }; return nil
        }
        var bindings = (promoted.bindings ?? []).map { binding in
            var binding = binding
            if case .setting(let part, _) = binding.target {
                binding.provenance.setting = parts.first { $0.id.rawValue == part }
            }
            return binding
        }
        var controls = promoted.controls
        var presentation = legacy.presentation
        var relations: [OptionControl] = []
        func child(_ byte: UInt8, parent: UInt8, option: UInt8, title: String, ends: (String, String)) throws -> SoundControl {
            let control = SoundControl(id: id(byte), face: .slider, position: .scalar(try Position(0.5)),
                waypoints: .scalar([.start, try Position(0.5), .end]))
            controls.append(control)
            presentation.append(ListeningControl(id: control.id.rawValue, title: title, face: .slider(ends.0, ends.1), readout: .positionPercent))
            relations.append(.choiceOption(parentChoice: id(parent), option: id(option), child: control.id))
            return control
        }
        var ordinal: UInt8 = 100
        func map(_ source: SoundControl, part: UInt8, parameter: String, values: [Double]) throws {
            guard let setting = parts.first(where: { $0.id == id(part) }) else { throw SoundModelError.invalidReference }
            let curve = try MappingCurve(waypoints: zip([Position.start, try Position(0.5), .end], values).map {
                Waypoint(position: $0.0, value: try Position($0.1))
            }, shapes: [.straight, .straight])
            let identity: ControlID = id(ordinal)
            ordinal += 1
            bindings.append(MappingBinding(id: identity.rawValue, source: LibraryMappingSource(source.id.rawValue),
                target: .setting(part: setting.id.rawValue, parameter: parameter), reference: try Position(0.5),
                response: .lane(.continuous(curve)), status: .active,
                provenance: MappingProvenance(source: source, selector: nil, target: nil, setting: setting)))
        }
        let size = try child(20, parent: 16, option: 66, title: "Room size", ends: ("Small", "Large"))
        try map(size, part: 35, parameter: "roomSize", values: [0, 0.5, 1])
        let wall = try child(21, parent: 16, option: 65, title: "Wall", ends: ("Thin", "Thick"))
        try map(wall, part: 34, parameter: "lowPassHz", values: [0.62, 0.5, 0.38])
        try map(wall, part: 37, parameter: "gainDb", values: [0.53, 0.5, 0.47])
        let distance = try child(22, parent: 16, option: 67, title: "Distance", ends: ("Near", "Far"))
        try map(distance, part: 34, parameter: "lowPassHz", values: [0.6, 0.5, 0.4])
        try map(distance, part: 35, parameter: "wetPercent", values: [0.4, 0.5, 0.65])
        try map(distance, part: 37, parameter: "gainDb", values: [0.54, 0.5, 0.46])
        let crunch = try child(23, parent: 17, option: 71, title: "Crunch", ends: ("Clean", "Crunchy"))
        try map(crunch, part: 33, parameter: "wetPercent", values: [0.25, 0.5, 0.85])
        let line = try child(24, parent: 17, option: 70, title: "Line", ends: ("Clear", "Rough"))
        try map(line, part: 32, parameter: "highPassHz", values: [0.47, 0.5, 0.54])
        try map(line, part: 32, parameter: "lowPassHz", values: [0.55, 0.5, 0.43])
        try map(line, part: 33, parameter: "wetPercent", values: [0.5, 0.5, 0.62])
        definition = BlockDefinition(id: legacy.definition.id, version: id(7), name: legacy.definition.name,
            content: SoundBlock(pieces: pieces, controls: controls, storage: .bindings(bindings), optionControls: relations))
        self.presentation = presentation
    }

    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        if type == "sizedReverb" {
            if parameter.rawValue == "roomSize" { return position.value }
            return try legacy.nativeValue(type: "reverb", parameter: parameter, position: position)
        }
        return try legacy.nativeValue(type: type, parameter: parameter, position: position)
    }
}

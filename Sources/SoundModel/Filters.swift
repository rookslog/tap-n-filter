import Foundation

struct Filters: BuiltinSound {
    let kind = BuiltinBlock.filters
    let root: RootUseID
    let definition: BlockDefinition
    let presentation: [ListeningControl]
    private let domains: [String: [String: ParameterDomain]]

    init() throws {
        func id<Kind>(_ byte: UInt8) -> EntityID<Kind> {
            EntityID(UUID(uuid: (0x54, 0x4E, 0x46, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
        }
        root = id(3)
        let frequency = ParameterDomain.logarithmic(20, 20_000)
        let domains: [String: [String: ParameterDomain]] = [
            "deviceEQ": ["highPassHz": frequency, "lowPassHz": frequency],
            "reverb": ["wetPercent": .linear(0, 100), "roomPreset": .linear(1, 3)],
            "dynamics": [
                "thresholdDb": .linear(-40, 20), "headroomDb": .linear(0.1, 40),
                "expansionRatio": .linear(1, 50), "expansionThresholdDb": .linear(-120, 0),
                "attackSeconds": .linear(0.001, 0.2), "releaseSeconds": .linear(0.01, 3),
                "makeupDb": .linear(-40, 40),
            ],
            "gain": ["gainDb": .linear(-24, 6)],
        ]
        self.domains = domains
        let seeds: [(String, [(String, Double)])] = [
            ("deviceEQ", [("highPassHz", 20), ("lowPassHz", 20_000)]),
            ("reverb", [("wetPercent", 0), ("roomPreset", 2)]),
            (
                "dynamics",
                [
                    ("thresholdDb", 20), ("headroomDb", 40), ("expansionRatio", 1),
                    ("expansionThresholdDb", -120), ("attackSeconds", 0.080),
                    ("releaseSeconds", 0.650), ("makeupDb", 0),
                ]
            ),
            ("gain", [("gainDb", 0)]),
        ]
        let defaults: [Double] = [0, 0, 0, 0.8, 0.4, 0]
        let controls: [SoundControl] = try (0..<6).map { i in
            let points: [Position]
            if i == 5 { points = try [.start, Position(0.25), Position(0.5), .end] }
            else if i == 4 { points = try [.start, Position(0.5), .end] }
            else { points = [.start, .end] }
            return SoundControl(
                id: id(UInt8(16 + i)), face: .slider,
                position: .scalar(try Position(defaults[i])), waypoints: .scalar(points))
        }
        let parts: [SoundPart] = try seeds.enumerated().map { i, seed in
            SoundPart(
                id: id(UInt8(32 + i)), type: seed.0,
                settings: try seed.1.map { name, value in
                    guard let domain = domains[seed.0]?[name] else {
                        throw SoundModelError.invalidReference
                    }
                    return ParameterSetting(
                        key: try ParameterKey(name), position: try domain.position(value))
                })
        }
        var mappings: [ParameterMapping] = []
        func map(
            _ control: Int, _ part: Int, _ parameter: String, _ values: [Double], step: Bool = false
        ) throws {
            guard let domain = domains[parts[part].type]?[parameter] else {
                throw SoundModelError.invalidReference
            }
            let points = try controls[control].waypoints.positions(on: .value)
            guard values.count == points.count else { throw SoundModelError.invalidWaypoints }
            mappings.append(
                ParameterMapping(
                    control: controls[control].id, axis: .value, part: parts[part].id,
                    parameter: try ParameterKey(parameter),
                    curve: try MappingCurve(
                        waypoints: zip(points, values).map {
                            Waypoint(position: $0.0, value: try domain.position($0.1))
                        },
                        shapes: Array(repeating: step ? .step : .straight, count: points.count - 1))
                ))
        }
        try map(0, 0, "highPassHz", [20, 2000])
        try map(1, 0, "lowPassHz", [20_000, 100])
        try map(2, 1, "wetPercent", [0, 50])
        try map(3, 3, "gainDb", [-24, 6])
        try map(4, 1, "roomPreset", [1, 2, 3], step: true)
        try map(5, 2, "thresholdDb", [20, -18, -26, -32])
        try map(5, 2, "headroomDb", [40, 20, 12, 5])
        definition = BlockDefinition(
            id: id(1), version: id(6), name: "Filters",
            content: SoundBlock(
                pieces: parts.map(BlockPiece.part), controls: controls, mappings: mappings))
        let titles = ["Low cut", "High cut", "Reverb", "Volume", "Room size", "Evener"]
        let faces: [ListeningControlFace] = [
            .slider("Off", "2 kHz"), .slider("Off", "100 Hz"),
            .slider("Off", "50%"), .slider("−24 dB", "+6 dB"), .slider("Small", "Large"),
            .slider("Off", "Full"),
        ]
        let readouts: [ListeningReadout] = [
            .frequency(20, 2000), .frequency(20_000, 100), .wetPercent(50),
            .decibels(-24, 6), .positionPercent, .positionPercent,
        ]
        presentation = (0..<6).map { i in
            ListeningControl(
                id: controls[i].id.rawValue, title: titles[i], face: faces[i],
                placement: i < 4 ? .primary : .more, readout: readouts[i])
        }
    }
    func authoringParameters(type: String) throws -> [(String, ParameterDomain, Double)] {
        guard let domains = domains[type], let part = definition.content.pieces.compactMap({ piece -> SoundPart? in
            if case .part(let part) = piece, part.type == type { return part }; return nil
        }).first else { throw SoundModelError.invalidReference }
        return try part.settings.map { setting in
            guard let domain = domains[setting.key.rawValue] else { throw SoundModelError.invalidReference }
            return (setting.key.rawValue, domain, domain.value(setting.position))
        }
    }

    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        guard let domain = domains[type]?[parameter.rawValue] else {
            throw SoundModelError.invalidReference
        }
        return domain.value(position)
    }
}

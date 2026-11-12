import Foundation

enum BuiltinDistortionPreset: Double {
    case speechRadioTower = 1
    case speechGoldenPi = 2
}

enum ParameterDomain: Sendable {
    case linear(Double, Double)
    case logarithmic(Double, Double)

    func position(_ value: Double) throws -> Position {
        switch self {
        case .linear(let lower, let upper): return try Position((value - lower) / (upper - lower))
        case .logarithmic(let lower, let upper):
            return try Position(log(value / lower) / log(upper / lower))
        }
    }

    func value(_ position: Position) -> Double {
        switch self {
        case .linear(let lower, let upper): return lower + position.value * (upper - lower)
        case .logarithmic(let lower, let upper): return lower * pow(upper / lower, position.value)
        }
    }
}

struct Everyday: BuiltinSound {
    let kind = BuiltinBlock.everyday
    private struct PartRecipe: Sendable {
        let id: PartID
        let type: String
        let parameters: [(String, ParameterDomain, Double)]
    }

    let root: RootUseID
    let definition: BlockDefinition
    let catalog: [PartDescriptor]
    let presentation: [ListeningControl]
    private let recipes: [PartRecipe]

    init() throws {
        func id<Kind>(_ byte: UInt8) -> EntityID<Kind> {
            EntityID(UUID(uuid: (0x54, 0x4E, 0x46, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
        }
        root = id(3)
        let place: ControlID = id(16)
        let device: ControlID = id(17)
        let softer: ControlID = id(18)
        let volume: ControlID = id(19)
        let frequency = ParameterDomain.logarithmic(20, 20_000)
        let gain = ParameterDomain.linear(-96, 6)
        let wet = ParameterDomain.linear(0, 100)
        let room = ParameterDomain.linear(1, 3)
        let headroom = ParameterDomain.linear(0.1, 40)
        let threshold = ParameterDomain.linear(-40, 20)
        let recipes: [PartRecipe] = [
            PartRecipe(
                id: id(32), type: "deviceEQ",
                parameters: [
                ("highPassHz", frequency, 20), ("lowPassHz", frequency, 20_000),
                ]),
            PartRecipe(
                id: id(33), type: "deviceColour",
                parameters: [
                    ("wetPercent", wet, 0), ("preGainDb", .linear(-80, 20), 0),
                    ("factoryPreset", .linear(1, 2), BuiltinDistortionPreset.speechRadioTower.rawValue),
                ]),
            PartRecipe(id: id(34), type: "placeEQ", parameters: [("lowPassHz", frequency, 20_000)]),
            PartRecipe(
                id: id(35), type: "reverb",
                parameters: [
                    ("wetPercent", wet, 0), ("roomPreset", room, 1),
                ]),
            PartRecipe(
                id: id(36), type: "dynamics",
                parameters: [
                ("thresholdDb", threshold, 20), ("headroomDb", headroom, 40),
                    ("expansionRatio", .linear(1, 50), 1),
                    ("expansionThresholdDb", .linear(-120, 0), -120),
                    ("attackSeconds", .linear(0.0001, 0.2), 0.001),
                    ("releaseSeconds", .linear(0.01, 3), 0.180),
                    ("makeupDb", .linear(-40, 40), 0),
                ]),
            PartRecipe(id: id(37), type: "gain", parameters: [("gainDb", gain, 0)]),
        ]
        let placeOptions: [OptionID] = [id(64), id(65), id(66), id(67)]
        let deviceOptions: [OptionID] = [id(68), id(69), id(70), id(71)]
        let placeChoice = try Choice(options: placeOptions)
        let deviceChoice = try Choice(options: deviceOptions)
        let controls = [
            SoundControl(
                id: place, face: .choice(placeChoice), position: .scalar(.start),
                waypoints: .scalar(placeChoice.positions)),
            SoundControl(
                id: device, face: .choice(deviceChoice), position: .scalar(.start),
                waypoints: .scalar(deviceChoice.positions)),
            SoundControl(
                id: softer, face: .slider, position: .scalar(.start),
                waypoints: .scalar([.start, try Position(0.25), try Position(0.5), .end])),
            SoundControl(
                id: volume, face: .slider, position: .scalar(try Position(0.8)),
                waypoints: .scalar([.start, .end])),
        ]
        let parts = try recipes.map { recipe in
            BlockPiece.part(
                SoundPart(
                    id: recipe.id, type: recipe.type,
                    settings: try recipe.parameters.map {
                        ParameterSetting(key: try ParameterKey($0.0), position: try $0.1.position($0.2))
                    }))
        }
        var mappings: [ParameterMapping] = []
        func map(_ control: ControlID, _ recipe: Int, _ parameter: String, _ values: [Double]) throws {
            let part = recipes[recipe]
            guard let domain = part.parameters.first(where: { $0.0 == parameter })?.1,
                let source = controls.first(where: { $0.id == control })
            else {
                throw SoundModelError.invalidReference
            }
            let positions = try source.waypoints.positions(on: .value)
            guard values.count == positions.count else { throw SoundModelError.invalidWaypoints }
            mappings.append(
                ParameterMapping(
                    control: control, axis: .value, part: part.id, parameter: try ParameterKey(parameter),
                    curve: try MappingCurve(
                        waypoints: try zip(positions, values).map {
                            Waypoint(position: $0.0, value: try domain.position($0.1))
                        }, shapes: Array(repeating: .straight, count: values.count - 1))))
        }
        try map(device, 0, "highPassHz", [20, 120, 180, 300])
        try map(device, 0, "lowPassHz", [20_000, 9500, 7500, 3400])
        try map(device, 1, "wetPercent", [0, 0, 0, 25])
        try map(device, 5, "gainDb", [0, 0, 0, -2])
        try map(place, 2, "lowPassHz", [20_000, 1200, 10_000, 6000])
        try map(place, 3, "wetPercent", [0, 12, 8, 25])
        try map(place, 3, "roomPreset", [1, 1, 2, 3])
        try map(place, 5, "gainDb", [0, -8, -6, -9])
        // Log-frequency deltas multiply any Place cutoff by the same factor.
        try map(softer, 2, "lowPassHz", [20_000, 20_000 * pow(0.7, 0.25), 20_000 * pow(0.7, 0.5), 14_000])
        try map(softer, 5, "gainDb", [0, -0.5, -1, -2])
        try map(softer, 4, "thresholdDb", [20, -10, -20, -30])
        // Headroom stays in the archived native domain; lower values strengthen compression.
        try map(softer, 4, "headroomDb", [40, 34, 28, 24])
        try map(volume, 5, "gainDb", [-24, 6])
        definition = BlockDefinition(
            id: id(1), version: id(6), name: "Everyday",
            content: SoundBlock(pieces: parts, controls: controls, mappings: mappings))
        catalog = try recipes.map {
            PartDescriptor(type: $0.type, parameters: try $0.parameters.map { try ParameterKey($0.0) })
        }
        presentation = [
            ListeningControl(
                id: place.rawValue, title: "Place",
                face: .choice(
                    zip(placeOptions, ["Here", "Next room", "Corner", "Far away"]).enumerated().map {
                        ListeningOption(
                            id: $0.element.0.rawValue, title: $0.element.1,
                            position: placeChoice.positions[$0.offset].value)
                    })),
            ListeningControl(
                id: device.rawValue, title: "Device",
                face: .choice(
                    zip(deviceOptions, ["Speakers", "TV", "Phone", "Radio"])
                        .enumerated().map {
                            ListeningOption(
                                id: $0.element.0.rawValue, title: $0.element.1,
                                position: deviceChoice.positions[$0.offset].value)
                        })),
            ListeningControl(id: softer.rawValue, title: "Softer", face: .slider("As is", "Gentle")),
            ListeningControl(
                id: volume.rawValue, title: "Volume", face: .slider("−24 dB", "+6 dB"),
                readout: .decibels(-24, 6)),
        ]
        self.recipes = recipes
    }

    func authoringParameters(type: String) throws -> [(String, ParameterDomain, Double)] {
        guard let recipe = recipes.first(where: { $0.type == type }) else { throw SoundModelError.invalidReference }
        return recipe.parameters
    }

    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double {
        guard
            let domain = recipes.first(where: { $0.type == type })?.parameters
                .first(where: { $0.0 == parameter.rawValue })?.1
        else {
            throw SoundModelError.invalidReference
        }
        return domain.value(position)
    }
}

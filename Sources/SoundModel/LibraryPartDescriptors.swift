import Foundation

struct LibraryParameterDescriptor: Sendable {
    let key: ParameterKey
    let domain: ParameterDomain
    let seed: Double
    let unit: String
    let discrete: Bool
    var specification: LibraryValueSpecification {
        let lower: Double, upper: Double, scale: LibraryValueScale
        switch domain {
        case .linear(let a, let b): lower = a; upper = b; scale = .linear
        case .logarithmic(let a, let b): lower = a; upper = b; scale = .logarithmic
        }
        return LibraryValueSpecification(lower: lower, upper: upper,
            minimumInput: key.rawValue == "attackSeconds" ? max(lower, 0.001) : lower,
            scale: scale, discrete: discrete)
    }
    func position(_ value: Double) throws -> Position {
        try Position(specification.normalized(value))
    }
}
struct LibraryPartDescriptor: Sendable {
    let type: String
    let parameters: [LibraryParameterDescriptor]
    func seed() throws -> SoundPart {
        SoundPart(id: PartID(), type: type, settings: try parameters.map {
            ParameterSetting(key: $0.key, position: try $0.position($0.seed))
        })
    }
}
extension LibraryProfiles {
    static let authoringKinds = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"]
    func descriptor(_ profile: String, type: String) throws -> LibraryPartDescriptor {
        _ = try recipe(profile)
        guard Self.authoringKinds.contains(type) || (profile == Self.quickMenu && type == "sizedReverb") else { throw LibraryError.unsupportedEdit }
        let parameters: [(String, ParameterDomain, Double)]
        if type == "sizedReverb" {
            parameters = [("wetPercent", .linear(0, 100), 0), ("roomPreset", .linear(1, 3), 1), ("roomSize", .linear(0, 1), 0.5)]
        } else if profile == Self.filters, ["deviceEQ", "reverb", "dynamics", "gain"].contains(type) {
            parameters = try recipes.filters.authoringParameters(type: type)
        } else {
            parameters = try recipes.everyday.authoringParameters(type: type)
        }
        return LibraryPartDescriptor(type: type, parameters: try parameters.map { key, domain, seed in
            let unit: String
            if key.hasSuffix("Hz") { unit = "Hz" }
            else if key.hasSuffix("Db") { unit = "dB" }
            else if key.hasSuffix("Seconds") { unit = "s" }
            else if key.hasSuffix("Percent") { unit = "%" }
            else { unit = "" }
            return LibraryParameterDescriptor(key: try ParameterKey(key), domain: domain, seed: seed, unit: unit,
                discrete: key == "factoryPreset" || key == "roomPreset")
        })
    }
    func authoredCatalog(_ profile: String) throws -> [PartDescriptor] {
        try (Self.authoringKinds + (profile == Self.quickMenu ? ["sizedReverb"] : [])).map {
            let descriptor = try descriptor(profile, type: $0)
            return PartDescriptor(type: $0, parameters: descriptor.parameters.map(\.key))
        }
    }
}

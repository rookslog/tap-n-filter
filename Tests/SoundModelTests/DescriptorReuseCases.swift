import Foundation
@testable import SoundModel

private struct DescriptorFacts: Equatable {
    let type: String
    let keys: [ParameterKey]
    let domains: [[UInt64]]
    let seeds: [UInt64]
    let units: [String]
    let discrete: [Bool]
    let minimumInputs: [UInt64]
    init(_ descriptor: LibraryPartDescriptor) {
        type = descriptor.type
        keys = descriptor.parameters.map(\.key)
        domains = descriptor.parameters.map {
            switch $0.domain {
            case .linear(let a, let b): return [0, a.bitPattern, b.bitPattern]
            case .logarithmic(let a, let b): return [1, a.bitPattern, b.bitPattern]
            }
        }
        seeds = descriptor.parameters.map { $0.seed.bitPattern }
        units = descriptor.parameters.map(\.unit)
        discrete = descriptor.parameters.map(\.discrete)
        minimumInputs = descriptor.parameters.map { $0.specification.minimumInput.bitPattern }
    }
}

struct DescriptorReuseCases {
    // Freeze 51137c6's numeric facts independently of the generated recipe consumers.
    // Filters historically read seeds back through domain.value(domain.position(seed)).
    private func original(_ profiles: LibraryProfiles, _ profile: String, type: String) throws -> LibraryPartDescriptor {
        _ = try profiles.recipe(profile)
        let kinds = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"]
        guard kinds.contains(type) || (profile == LibraryProfiles.quickMenu && type == "sizedReverb") else {
            throw LibraryError.unsupportedEdit
        }
        let frequency = ParameterDomain.logarithmic(20, 20_000)
        let everyday: [String: [(String, ParameterDomain, Double)]] = [
            "deviceEQ": [("highPassHz", frequency, 20), ("lowPassHz", frequency, 20_000)],
            "deviceColour": [("wetPercent", .linear(0, 100), 0), ("preGainDb", .linear(-80, 20), 0),
                ("factoryPreset", .linear(1, 2), 1)],
            "placeEQ": [("lowPassHz", frequency, 20_000)],
            "reverb": [("wetPercent", .linear(0, 100), 0), ("roomPreset", .linear(1, 3), 1)],
            "dynamics": [("thresholdDb", .linear(-40, 20), 20), ("headroomDb", .linear(0.1, 40), 40),
                ("expansionRatio", .linear(1, 50), 1), ("expansionThresholdDb", .linear(-120, 0), -120),
                ("attackSeconds", .linear(0.0001, 0.2), 0.001), ("releaseSeconds", .linear(0.01, 3), 0.180),
                ("makeupDb", .linear(-40, 40), 0)],
            "gain": [("gainDb", .linear(-96, 6), 0)],
        ]
        let filters: [String: [(String, ParameterDomain, Double)]] = [
            "deviceEQ": everyday["deviceEQ"]!,
            "reverb": [("wetPercent", .linear(0, 100), 0), ("roomPreset", .linear(1, 3), 2)],
            "dynamics": [("thresholdDb", .linear(-40, 20), 20), ("headroomDb", .linear(0.1, 40), 40),
                ("expansionRatio", .linear(1, 50), 1), ("expansionThresholdDb", .linear(-120, 0), -120),
                ("attackSeconds", .linear(0.001, 0.2), 0.080), ("releaseSeconds", .linear(0.01, 3), 0.650),
                ("makeupDb", .linear(-40, 40), 0)],
            "gain": [("gainDb", .linear(-24, 6), 0)],
        ]
        let parameters: [(String, ParameterDomain, Double)]
        if type == "sizedReverb" {
            parameters = [("wetPercent", .linear(0, 100), 0), ("roomPreset", .linear(1, 3), 1), ("roomSize", .linear(0, 1), 0.5)]
        } else if profile == LibraryProfiles.filters, let original = filters[type] {
            parameters = try original.map { key, domain, seed in
                (key, domain, domain.value(try domain.position(seed)))
            }
        } else {
            parameters = everyday[type]!
        }
        return LibraryPartDescriptor(type: type, parameters: try parameters.map { key, domain, seed in
            let unit: String
            if key.hasSuffix("Hz") { unit = "Hz" }
            else if key.hasSuffix("Db") { unit = "dB" }
            else if key.hasSuffix("Seconds") { unit = "s" }
            else if key.hasSuffix("Percent") { unit = "%" }
            else { unit = "" }
            let lower: Double
            switch domain {
            case .linear(let value, _), .logarithmic(let value, _): lower = value
            }
            return LibraryParameterDescriptor(key: try ParameterKey(key), domain: domain, seed: seed, unit: unit,
                discrete: key == "factoryPreset" || key == "roomPreset",
                nativeLower: key == "attackSeconds" ? max(lower, 0.001) : lower)
        })
    }

    func test_exact_legacy_descriptor_facts() throws {
        let profiles = try LibraryProfiles()
        let kinds = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"]
        for profile in [LibraryProfiles.everyday, LibraryProfiles.legacyEveryday, LibraryProfiles.filters, LibraryProfiles.quickMenu] {
            let supported = kinds + (profile == LibraryProfiles.quickMenu ? ["sizedReverb"] : [])
            let catalog = try profiles.authoredCatalog(profile)
            try requireEqual(catalog.map(\.type), supported, "exact profile/kind order")
            for (index, kind) in supported.enumerated() {
                let expected = try original(profiles, profile, type: kind)
                for _ in 0..<3 {
                    let actual = try profiles.descriptor(profile, type: kind)
                    try requireEqual(DescriptorFacts(actual), DescriptorFacts(expected), "exact descriptor domain/seed bits, units, discrete and order: \(profile)/\(kind)")
                    try requireEqual(catalog[index].parameters, expected.parameters.map(\.key), "catalog parameter order")
                }
            }
            for kind in ["", "unknown", "sizedReverb"] where !supported.contains(kind) {
                try requireThrows(profiles.descriptor(profile, type: kind)) { error in
                    try requireEqual(error as? LibraryError, .unsupportedEdit)
                }
            }
        }
        for profile in ["", "tnf.unknown", "tnf.native.everyday.v999"] {
            for kind in kinds + ["sizedReverb", "unknown"] {
                try requireThrows(profiles.descriptor(profile, type: kind)) { error in
                    try requireEqual(error as? LibraryError, .unknownProfile(profile), "profile refusal precedes unsupported kind")
                }
            }
            try requireThrows(profiles.authoredCatalog(profile)) { error in
                try requireEqual(error as? LibraryError, .unknownProfile(profile))
            }
        }
    }
}

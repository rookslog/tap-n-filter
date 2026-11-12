import Foundation
@testable import SoundModel

private struct DescriptorFacts: Equatable {
    let type: String
    let keys: [ParameterKey]
    let domains: [[UInt64]]
    let seeds: [UInt64]
    let units: [String]
    let discrete: [Bool]
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
    }
}

struct DescriptorReuseCases {
    // Frozen pre-reuse descriptor behavior is the parity oracle, not a timing test.
    private func original(_ profiles: LibraryProfiles, _ profile: String, type: String) throws -> LibraryPartDescriptor {
        _ = try profiles.recipe(profile)
        let kinds = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"]
        guard kinds.contains(type) || (profile == LibraryProfiles.quickMenu && type == "sizedReverb") else {
            throw LibraryError.unsupportedEdit
        }
        let parameters: [(String, ParameterDomain, Double)]
        if type == "sizedReverb" {
            parameters = [("wetPercent", .linear(0, 100), 0), ("roomPreset", .linear(1, 3), 1), ("roomSize", .linear(0, 1), 0.5)]
        } else if profile == LibraryProfiles.filters, ["deviceEQ", "reverb", "dynamics", "gain"].contains(type) {
            parameters = try Filters().authoringParameters(type: type)
        } else {
            parameters = try Everyday().authoringParameters(type: type)
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

import Foundation
@testable import SoundModel

enum CompatibilityWitnessFailure: Error { case mismatch(String) }

enum CompatibilityWitnessChecks {
    static func run(_ fixture: URL) throws {
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixture))
        let profiles = try LibraryProfiles()
        let limits = try LibraryLimits(maximumBytes: 8_000_000, maximumRevisions: 1024,
            expansion: LibraryExpansionLimits(maximumDepth: 24, maximumOccurrences: 256, maximumParts: 1024))
        var witnesses: [String: String] = [:]
        for recipe in profiles.recipes.all {
            let profile = try profiles.profile(for: recipe.definition)
            let presentation = try profiles.presentation(for: recipe.definition)
            for version in 1...4 {
                let block = version == 4 ? try recipe.definition.content.promoted() : recipe.definition.content
                let payload = LibraryPayload(profile: profile, block: block, presentation: presentation, canonicalVersion: version)
                let context = LibraryCompileContext(profiles: profiles, revisions: [:], limits: limits.expansion)
                let root = RootUseID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
                let sound = try CompiledSound(payload: payload, root: root, reference: nil, context: context, listening: UseListeningState(positions: [:]))
                let key = "\(profile)-v\(version)"
                witnesses[key + "-canonical"] = try payload.canonicalData.base64EncodedString()
                witnesses[key + "-native"] = try profiles.native(sound).map { part in
                    part.id.uuidString + ":" + part.path.map(\.uuidString).joined(separator: "/") + ":" + part.type + ":" + part.parameters.map { $0.key + "=" + String($0.value) }.joined(separator: ",")
                }.joined(separator: "|")
            }
        }
        guard expected.count == 16, Set(witnesses.keys) == Set(expected.keys) else {
            throw CompatibilityWitnessFailure.mismatch("witness key set")
        }
        for key in expected.keys.sorted() {
            guard witnesses[key] == expected[key] else {
                throw CompatibilityWitnessFailure.mismatch(key)
            }
            print("PASS frozen compatibility \(key)")
        }
    }
}

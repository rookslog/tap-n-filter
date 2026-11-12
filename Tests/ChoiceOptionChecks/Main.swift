import Foundation
import SoundModel
import SessionStore

#if !SWIFT_PACKAGE
@main
#endif
struct ChoiceOptionChecks {
    @MainActor static func main() async {
        do {
            try await run(URL(fileURLWithPath:CommandLine.arguments[1]))
        }catch{print("FAIL \(error)");exit(1)}
    }
    @MainActor static func run(_ root: URL) async throws {
        try await localCases(root.appendingPathComponent("local"))
        try await mappingCases(root.appendingPathComponent("mapping"))
        try await publicationCases(root.appendingPathComponent("publication"))
        try await heldPublicationCases(root.appendingPathComponent("held"))
        try await persistenceCases(root.appendingPathComponent("persistence"))
        try await boundsAndHistoryCases(root.appendingPathComponent("bounds"))
        try await qualifiedCases(root.appendingPathComponent("qualified"))
        try await nestedPublicationCases(root.appendingPathComponent("nested-publication"))
        try await publicationCapacityCases(root.appendingPathComponent("capacity"))
        try await legacyAndBrokenCases(root.appendingPathComponent("legacy-broken"))
        try await dormantCases(root.appendingPathComponent("dormant"))
        try await newerReplacementCases(root.appendingPathComponent("newer-replacement"))
        try await historyCapacityCases(root.appendingPathComponent("history-capacity"))
        try await retainedIntentConflictCases(root.appendingPathComponent("retained-intent-conflict"))
        print("PASS choice option current public checks")
    }
}

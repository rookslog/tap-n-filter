import Foundation
import SoundModel
@main struct EditorOwnerChecks {
    @MainActor static func main() async {
        do {
            let root=URL(fileURLWithPath:CommandLine.arguments[1])
            switch CommandLine.arguments[2] {
            case "history": try await ownerHistoryCases(root)
            case "projection": try await ownerProjectionCases(root)
            case "adapter": try await ownerAdapterCases(root)
            case "publication": try await ownerPublicationCases(root)
            case "ports": try await ownerPortCases(root)
            default: throw Failure(message:"unknown group")
            }
            print("PASS real editor owner group complete")
        }catch {print("FAIL \(error)");exit(1)}
    }
}

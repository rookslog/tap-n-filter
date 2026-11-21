import Foundation
@main struct Main {
    static func main() async {
        do {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let witness = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/quick-menu-v5.json")
        try await EngineCatalogChecks.run(directory, witness: witness)
        } catch {
            FileHandle.standardError.write(Data("FAIL engine catalog checks: \(error)\n".utf8))
            exit(1)
        }
    }
}

import Foundation
import SessionStoreCheckCore

@main struct Main {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-session-check-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await SessionStoreChecks.run(directory)
    }
}

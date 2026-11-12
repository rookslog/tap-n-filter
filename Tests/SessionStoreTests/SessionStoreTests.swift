import Foundation
import SessionStoreCheckCore
import XCTest

final class SessionStoreTests: XCTestCase {
    func test_public_commands_save_reopen_late_write_and_bootstrap() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-store-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await SessionStoreChecks.run(directory)
    }
}

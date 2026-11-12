import Foundation
import XCTest

final class ChoiceOptionChecksTests: XCTestCase {
    func test_public_owner_commands_and_owned_store() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-choiceoptionchecks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ChoiceOptionChecks.run(directory)
    }
}

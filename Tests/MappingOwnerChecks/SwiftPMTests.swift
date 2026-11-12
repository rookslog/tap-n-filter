import Foundation
import XCTest

final class MappingOwnerChecksTests: XCTestCase {
    func test_public_owner_commands_and_owned_store() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-mappingownerchecks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MappingOwnerChecks.run(directory)
    }
}

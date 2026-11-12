import Foundation
import XCTest

final class OptionControlTests: XCTestCase {
    func test_real_owner_store_projection_and_native_contracts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tnf-option-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await OptionControlChecks.run(directory)
    }
}

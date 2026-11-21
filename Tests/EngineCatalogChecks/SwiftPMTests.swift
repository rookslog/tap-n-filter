import Foundation
import XCTest
final class EngineCatalogTests: XCTestCase {
    func test_generated_contract_and_owned_saved_history() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tnf-engine-catalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let witness = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/quick-menu-v5.json")
        try await EngineCatalogChecks.run(directory, witness: witness)
    }
}

import Foundation
import XCTest

final class MenuPerformanceTests: XCTestCase {
    func test_real_adapter_drag_save_release_reopen_and_drain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-menu-store-tests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MenuPerformanceChecks.run(directory)
    }
}

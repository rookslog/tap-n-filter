import Foundation
import XCTest

final class PerfHarnessTests: XCTestCase {
    func test_fresh_off_harness_ownership_and_real_final_save() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-off-harness-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await PerfHarnessChecks.run(directory)
    }
}

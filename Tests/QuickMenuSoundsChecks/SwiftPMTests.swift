import Foundation
import XCTest

final class QuickMenuSoundsTests: XCTestCase {
    func test_three_quick_menu_sounds_against_their_spec() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tnf-quick-menu-sounds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let report = await QuickMenuSoundsChecks.run(root: root, scratch: directory)
        for failure in report.failures { XCTFail("[\(failure.group)] \(failure.message)") }
    }
}

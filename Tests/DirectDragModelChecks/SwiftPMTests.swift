import XCTest

final class DirectDragModelChecksTests: XCTestCase {
    func test_real_model_and_policy_differential() async throws {
        try await DirectDragModelChecks.run()
    }
}

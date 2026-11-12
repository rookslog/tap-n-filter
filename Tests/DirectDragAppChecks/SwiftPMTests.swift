import XCTest

final class DirectDragAppChecksTests: XCTestCase {
    func test_real_model_and_policy_differential() async throws {
        try await DirectDragAppChecks.run()
    }
}

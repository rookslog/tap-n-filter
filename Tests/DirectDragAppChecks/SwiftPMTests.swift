import XCTest

final class DirectDragAppChecksTests: XCTestCase {
    func test_real_model_and_policy_differential() async throws {
        try await DirectDragAppChecks.run()
    }

    func test_launch_data_path_and_one_copy_policy() throws {
        try LaunchChecks.run()
    }
}

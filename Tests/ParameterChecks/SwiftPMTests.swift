import XCTest

final class ParameterModelChecksTests: XCTestCase {
    func test_real_model_and_policy_differential() async throws {
        try await ParameterModelChecks.run()
    }
}

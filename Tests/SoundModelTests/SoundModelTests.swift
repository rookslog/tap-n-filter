import XCTest

final class SoundModelTests: XCTestCase {
    func test_shared_model_contracts() async throws {
        for contract in ModelContract.all {
            do { try await contract.run() } catch { XCTFail("\(contract.name): \(error)") }
        }
    }
}

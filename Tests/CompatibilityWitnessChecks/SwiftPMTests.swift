import Foundation
import XCTest

final class CompatibilityWitnessTests: XCTestCase {
    func test_frozen_canonical_bytes_and_native_mapping() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "canonical-native-v1-v4", withExtension: "json", subdirectory: "Fixtures"))
        try CompatibilityWitnessChecks.run(fixture)
    }
}

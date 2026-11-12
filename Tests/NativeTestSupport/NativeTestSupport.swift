import Foundation
import XCTest

public func requireNativeTests() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["TNF_RUN_NATIVE_TESTS"] != "1",
                  "Native engine/window qualification is opt-in. Set TNF_RUN_NATIVE_TESTS=1 to run.")
}

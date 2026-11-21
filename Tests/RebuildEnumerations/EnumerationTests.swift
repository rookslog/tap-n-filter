import Foundation
import XCTest

/// Long enumerations, skipped unless TNF_ENUM is set, so the ordinary `swift test` run does not play them.
/// TNF_ENUM holds one or more shard specs separated by ";", each "SUITE LENGTH HOLD FROM COUNT"
/// (see Runner.swift and README.md). Every spec prints one ENUM-SUMMARY line and must be clean:
/// the enumeration has its pinned size, every sequence in the range ran, and all of them are green.
final class MenuEnumerationTests: XCTestCase {
    @MainActor func test_enumeration_shard() async throws {
        let text = ProcessInfo.processInfo.environment["TNF_ENUM"] ?? ""
        try XCTSkipIf(text.isEmpty, "Long enumeration; set TNF_ENUM to a shard spec to run it")
        setvbuf(stdout, nil, _IOLBF, 0)
        let specs = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for item in specs {
            guard let spec = ShardSpec(item) else { XCTFail("unreadable shard spec \"\(item)\""); continue }
            let result = await runShard(spec)
            print(result.summary)
            for sequence in result.redSequences { print("ENUM-RED suite=\(spec.suite) [\(sequence)]") }
            if let pinned = pinnedTotals["\(spec.suite) \(spec.length)"] {
                XCTAssertEqual(result.total, pinned, "\(spec): the enumeration has \(result.total) sequences, pinned \(pinned)")
                XCTAssertEqual(result.count, max(0, min(spec.count, pinned - spec.from)), "\(spec): ran \(result.count) sequences")
            } else {
                print("ENUM-NOTE \(spec): no pinned total for this suite and length")
            }
            XCTAssertNil(result.setupFailure, "\(spec): \(result.setupFailure ?? "")")
            XCTAssertGreaterThan(result.count, 0, "\(spec): the range holds no sequences")
            XCTAssertEqual(result.red, 0, "\(spec): \(result.red) red")
            XCTAssertEqual(result.unsupported, 0, "\(spec): \(result.unsupported) unsupported")
            XCTAssertEqual(result.green, result.count, "\(spec): \(result.green) of \(result.count) green")
        }
    }
}

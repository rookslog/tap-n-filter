import Effects
import Foundation
import Graph
import Presets
import XCTest

final class PresetDecodeFidelityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-decode-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func data(unknownFields: Bool = false) throws -> Data {
        let preset = GraphPreset(name: "In-memory", outputGain: 1, nodes: [
            EffectState(typeIdentifier: "tnf.gain", id: UUID(), displayName: "Gain", bypass: false,
                        wetDryMix: 1, parameters: ["gain": -6], extras: [:]),
        ])
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any]
        )
        if unknownFields {
            object["private-root-key"] = "private-root-value"
            var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
            nodes[0]["private-node-key"] = "private-node-value"
            object["nodes"] = nodes
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func test_load_result_reports_sanitized_unknown_root_and_node_occurrences_without_rewriting() throws {
        let source = directory.appendingPathComponent("import.tnf")
        let bytes = try data(unknownFields: true)
        try bytes.write(to: source)

        let result = try PresetStore.loadResult(from: source)

        XCTAssertEqual(result.diagnostics.map { $0.path }, ["$.unknownFields[0]", "$.nodes[0].unknownFields[0]"])
        XCTAssertFalse(String(describing: result.diagnostics).contains("private-"))
        XCTAssertEqual(result.preset.name, "In-memory")
        XCTAssertEqual(try PresetStore.load(from: source), result.preset)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func test_decode_result_uses_supplied_bytes_not_source_file_contents() throws {
        let source = directory.appendingPathComponent("different.tnf")
        let onDisk = Data("not the supplied JSON".utf8)
        try onDisk.write(to: source)
        let bytes = try data(unknownFields: true)

        let result = try PresetStore.decodeResult(bytes, source: source)

        XCTAssertEqual(result.preset.name, "In-memory")
        XCTAssertEqual(result.diagnostics.count, 2)
        XCTAssertEqual(try PresetStore.decode(bytes, source: source), result.preset)
        XCTAssertEqual(try Data(contentsOf: source), onDisk)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try PresetStore.decodeResult(bytes, source: source).diagnostics, result.diagnostics)
    }

    func test_supported_V1_keys_have_no_decode_diagnostics() throws {
        let result = try PresetStore.decodeResult(data(), source: directory.appendingPathComponent("clean.tnf"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func test_unknown_values_need_not_be_materialized_to_report_their_field_occurrences() throws {
        let json = String(decoding: try data(unknownFields: true), as: UTF8.self)
            .replacingOccurrences(of: "\"private-root-value\"", with: "1e9999")
        let source = directory.appendingPathComponent("opaque-unknown-value.tnf")
        let result = try PresetStore.decodeResult(Data(json.utf8), source: source)
        XCTAssertEqual(result.preset.name, "In-memory")
        XCTAssertEqual(result.diagnostics.count, 2)
    }

    func test_unknown_fields_are_reported_per_node_occurrence_even_with_duplicate_IDs() throws {
        let source = directory.appendingPathComponent("duplicates.tnf")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        let node = try XCTUnwrap((object["nodes"] as? [[String: Any]])?.first)
        var second = node
        second["private-key-a"] = 42
        second["private-key-b"] = ["private-value"]
        object["nodes"] = [node, second]

        let result = try PresetStore.decodeResult(JSONSerialization.data(withJSONObject: object), source: source)

        XCTAssertEqual(result.diagnostics.map { $0.path },
                       ["$.nodes[1].unknownFields[0]", "$.nodes[1].unknownFields[1]"])
    }

    func test_result_APIs_keep_existing_missing_invalid_and_future_error_mapping() throws {
        let source = directory.appendingPathComponent("missing.tnf")
        XCTAssertThrowsError(try PresetStore.loadResult(from: source)) { error in
            guard case PresetStoreError.fileNotFound(let url) = error else {
                return XCTFail("Expected fileNotFound, got \(error)")
            }
            XCTAssertEqual(url, source)
        }
        XCTAssertThrowsError(try PresetStore.decodeResult(Data("invalid".utf8), source: source)) { error in
            guard case PresetStoreError.invalidJSON(let url, _) = error else {
                return XCTFail("Expected invalidJSON, got \(error)")
            }
            XCTAssertEqual(url, source)
        }
        let future = GraphPreset(formatVersion: 999, name: "Future", outputGain: 1, nodes: [])
        XCTAssertThrowsError(try PresetStore.decodeResult(JSONEncoder().encode(future), source: source)) { error in
            guard case PresetStoreError.unsupportedFormatVersion(999) = error else {
                return XCTFail("Expected unsupportedFormatVersion, got \(error)")
            }
        }
    }
}

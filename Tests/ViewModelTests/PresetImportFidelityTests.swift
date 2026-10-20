import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

@MainActor
final class PresetImportFidelityTests: XCTestCase {
    private var fixture: PresetContinuityFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try PresetContinuityFixture()
    }

    override func tearDown() async throws {
        try fixture.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    private func write(
        _ preset: GraphPreset? = nil,
        modify: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> URL {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(preset ?? fixture.preset())
        ) as? [String: Any])
        try modify(&object)
        let url = fixture.url("Imported.tnf")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        return url
    }

    private func editNode(
        _ index: Int, in object: inout [String: Any], edit: (inout [String: Any]) -> Void
    ) throws {
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        edit(&nodes[index])
        object["nodes"] = nodes
    }

    @discardableResult
    private func assertFidelityRecovery(
        _ url: URL, skipped: Int = 0, context: String = "unspecified fidelity fixture"
    ) throws -> AppViewModel {
        let original = try Data(contentsOf: url)
        let model = fixture.makeModel()
        model.loadPreset(from: url)
        let snapshotImmediatelyAfterLoad = model.graph.snapshot()
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.presetName, "Imported")
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)
        XCTAssertEqual(model.presetWarnings.count, skipped)
        let snapshotBeforeComparison = model.graph.snapshot()
        XCTAssertFalse(model.isPresetModified,
                       "Loss is provenance, not a fabricated graph edit; case=\(context); "
                       + "afterLoad=\(snapshotDiagnostic(snapshotImmediatelyAfterLoad)); "
                       + "beforeComparison=\(snapshotDiagnostic(snapshotBeforeComparison)); "
                       + "afterComparison=\(snapshotDiagnostic(model.graph.snapshot()))")
        let notice = try XCTUnwrap(model.presetRecoveryNotice)
        XCTAssertTrue(notice.contains("unsupported or adjusted"))
        XCTAssertEqual(notice.contains("skipped"), skipped > 0)
        XCTAssertEqual(try Data(contentsOf: url), original)
        return model
    }

    private func snapshotDiagnostic(_ snapshot: GraphPreset) -> String {
        func scalar(_ value: Float) -> String { "\(value)[0x\(String(value.bitPattern, radix: 16))]" }
        let nodes = snapshot.nodes.enumerated().map { index, node in
            let parameters = node.parameters.keys.sorted().map { key in
                "\(key)=\(scalar(node.parameters[key]!))"
            }.joined(separator: ",")
            return "\(index):\(node.typeIdentifier)/\(node.id) bypass=\(node.bypass) "
                + "wetDry=\(scalar(node.wetDryMix)) parameters={\(parameters)} extras=\(node.extras)"
        }.joined(separator: "; ")
        return "gain=\(scalar(snapshot.outputGain)); nodes=[\(nodes)]"
    }

    func test_unknown_raw_root_field_withholds_direct_save_without_claiming_skipped_effects() throws {
        let url = try write { $0["future-private-field"] = ["sensitive": "not for diagnostics"] }
        try assertFidelityRecovery(url)
    }

    func test_unknown_raw_node_field_withholds_direct_save_without_claiming_skipped_effects() throws {
        let url = try write { object in
            try editNode(1, in: &object) { $0["future-private-field"] = "not for diagnostics" }
        }
        try assertFidelityRecovery(url)
    }

    func test_unknown_known_node_parameter_and_extras_are_loss_even_without_graph_warnings() throws {
        for key in ["parameters", "extras"] {
            let url = try write { object in
                try editNode(0, in: &object) { node in
                    var fields = node[key] as? [String: Any] ?? [:]
                    fields["future.setting"] = 0.25
                    node[key] = fields
                }
            }
            try assertFidelityRecovery(url, context: "unknown node[0].\(key).future.setting=0.25")
        }
    }

    func test_output_gain_clamps_require_save_as_but_keep_canonical_clean_baseline() throws {
        for value: Float in [-0.1, 2.1] {
            let model = try assertFidelityRecovery(write { $0["outputGain"] = value })
            XCTAssertEqual(model.graph.outputGain, min(max(value, 0), 2))
        }
    }

    func test_wet_dry_clamps_on_supported_nodes_require_save_as() throws {
        for value: Float in [-0.1, 1.1] {
            let url = try write { object in
                try editNode(1, in: &object) { $0["wetDryMix"] = value }
            }
            let model = try assertFidelityRecovery(url)
            XCTAssertEqual(model.graph.nodes[1].wetDryMix, min(max(value, 0), 1))
        }
    }

    func test_supported_parameter_ranges_detect_gain_frequency_and_unrepaired_Q_clamps() throws {
        for (index, key, value) in [(0, "gain", Float(99)), (0, "gain", Float(-99)),
                                    (2, "hp.frequency", Float(900)), (2, "hp.Q", Float(5))] {
            let url = try write { object in
                try editNode(index, in: &object) { node in
                    var parameters = node["parameters"] as? [String: Any] ?? [:]
                    parameters[key] = value
                    node["parameters"] = parameters
                }
            }
            try assertFidelityRecovery(
                url, context: "node[\(index)] \(key)=\(value) bits=0x\(String(value.bitPattern, radix: 16))"
            )
        }
    }

    func test_skipped_nodes_and_fidelity_loss_produce_truthful_combined_notice() throws {
        let url = try write(fixture.partialPreset()) { $0["future-root"] = true }
        let model = try assertFidelityRecovery(url, skipped: 2)
        XCTAssertTrue(try XCTUnwrap(model.presetRecoveryNotice).contains("2 effects were skipped"))
    }

    func test_partial_session_init_retains_restored_session_label_warnings_and_truthful_notice() throws {
        fixture.defaults.set(try JSONEncoder().encode(fixture.partialPreset()), forKey: AppViewModelDefaultsKey.graph)

        let model = fixture.makeModel()

        XCTAssertEqual(model.presetName, "Restored Session")
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)
        XCTAssertEqual(model.presetWarnings, model.graph.lastLoadWarnings)
        XCTAssertEqual(model.presetWarnings.count, 2)
        let notice = try XCTUnwrap(model.presetRecoveryNotice)
        XCTAssertTrue(notice.contains("2 effects were skipped"))
        XCTAssertFalse(notice.contains("unsupported or adjusted"))
        XCTAssertFalse(model.isPresetModified)
    }

    func test_supported_import_rounding_repaired_Q_and_legacy_reverb_keep_safe_target() throws {
        for legacy in [false, true] {
            let url = try write(fixture.preset(legacyReverb: legacy)) { object in
                if legacy {
                    try editNode(2, in: &object) { node in
                        var parameters = node["parameters"] as? [String: Any] ?? [:]
                        parameters["hp.Q"] = 14426.951
                        node["parameters"] = parameters
                    }
                }
            }
            let original = try Data(contentsOf: url)
            let model = fixture.makeModel()
            model.loadPreset(from: url)

            XCTAssertEqual(model.presetOrigin, .file)
            XCTAssertEqual(model.presetFileURL, url)
            XCTAssertNil(model.presetRecoveryNotice)
            XCTAssertTrue(model.presetWarnings.isEmpty)
            XCTAssertFalse(model.isPresetModified)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    /// FILE imports must reject ambiguous runtime identities before replacing
    /// the graph or invalidating accepted intent, not merely require Save As.
    private func assertDuplicateImportRejected(_ url: URL) throws {
        let importedBytes = try Data(contentsOf: url)
        for recovered in [false, true] {
            let previousPreset = recovered ? fixture.partialPreset() : GraphPreset(
                name: "Previous", outputGain: 0.75, nodes: Array(fixture.preset().nodes.prefix(1))
            )
            let previousURL = try fixture.write(previousPreset, filename: "Previous.tnf")
            let previousBytes = try Data(contentsOf: previousURL)
            let model = fixture.makeModel()
            model.loadPreset(from: previousURL)
            XCTAssertNil(model.lastError)
            XCTAssertEqual(model.presetOrigin, recovered ? .recovered : .file)
            XCTAssertFalse(model.isPresetModified)
            let graph = model.graph
            let node = try XCTUnwrap(graph.nodes.first)
            let baselineGain = try XCTUnwrap(node.parameterValue("gain"))
            let identities = graph.nodes.map { ObjectIdentifier($0) }
            let name = model.presetName
            let origin = model.presetOrigin
            let fileURL = model.presetFileURL
            let suggestedFilename = model.suggestedPresetFilename
            let warnings = model.presetWarnings
            let notice = model.presetRecoveryNotice
            let loadWarnings = graph.lastLoadWarnings
            model.updateParameter(nodeID: node.id, paramID: "gain", value: -9)
            XCTAssertTrue(model.isPresetModified)
            let beforeImport = graph.snapshot()
            let handle = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "gain"))
            XCTAssertTrue(model.acceptParameterValue(-12, for: handle, intentRevision: 1))
            XCTAssertEqual(model.pendingParameterValue(for: handle), -12)
            XCTAssertEqual(node.parameterValue("gain"), -9, "Accepted input is still pending")

            model.loadPreset(from: url)

            if case .preset(let message)? = model.lastError {
                XCTAssertTrue(message.hasPrefix("Load failed:"))
            } else {
                XCTFail("Duplicate UUID FILE imports must use the existing load-error surface")
            }
            XCTAssertTrue(model.graph === graph)
            XCTAssertEqual(model.graph.nodes.map { ObjectIdentifier($0) }, identities)
            XCTAssertEqual(model.graph.snapshot(), beforeImport)
            XCTAssertEqual(model.graph.lastLoadWarnings, loadWarnings)
            XCTAssertEqual(model.presetName, name)
            XCTAssertEqual(model.presetOrigin, origin)
            XCTAssertEqual(model.presetFileURL, fileURL)
            XCTAssertEqual(model.suggestedPresetFilename, suggestedFilename)
            XCTAssertEqual(model.presetWarnings, warnings)
            XCTAssertEqual(model.presetRecoveryNotice, notice)
            XCTAssertTrue(model.isPresetModified)
            XCTAssertEqual(model.pendingParameterValue(for: handle), -12,
                           "Rejection must precede generation invalidation")
            XCTAssertEqual(node.parameterValue("gain"), -9, "Rejection must not flush pending input")
            XCTAssertEqual(try Data(contentsOf: previousURL), previousBytes)
            XCTAssertEqual(try Data(contentsOf: url), importedBytes)

            XCTAssertTrue(model.finishParameterEditing(handle))
            XCTAssertEqual(node.parameterValue("gain"), -12)
            XCTAssertEqual(model.graph.nodes.first?.parameterValue("gain"), -12)
            XCTAssertNil(model.pendingParameterValue(for: handle))
            model.updateParameter(nodeID: node.id, paramID: "gain", value: baselineGain)
            XCTAssertFalse(model.isPresetModified, "Rejected import must not replace the previous baseline")
            model.retireParameterEditHandle(handle)
            XCTAssertEqual(try Data(contentsOf: previousURL), previousBytes)
            XCTAssertEqual(try Data(contentsOf: url), importedBytes)
        }
    }

    func test_duplicate_IDs_across_types_are_rejected_preserving_previous_graph_receipt_and_pending_edit() throws {
        let base = fixture.preset()
        let id = base.nodes[0].id
        let nodes = base.nodes.map {
            EffectState(typeIdentifier: $0.typeIdentifier, id: id, displayName: $0.displayName,
                        bypass: $0.bypass, wetDryMix: $0.wetDryMix, parameters: $0.parameters, extras: $0.extras)
        }
        let url = try write(GraphPreset(name: base.name, outputGain: base.outputGain, nodes: nodes))
        try assertDuplicateImportRejected(url)
    }

    func test_duplicate_same_type_ID_with_skipped_occurrence_is_rejected_before_install() throws {
        let id = UUID()
        let states = ["not-a-reverb", "largeHall"].map {
            EffectState(typeIdentifier: "tnf.reverb", id: id, displayName: "Reverb", bypass: false,
                        wetDryMix: 0.7, parameters: [:], extras: ["preset": .string($0)])
        }
        let url = try write(GraphPreset(name: "Ambiguous", outputGain: 1, nodes: states))
        try assertDuplicateImportRejected(url)
    }

    func test_duplicate_same_type_IDs_without_skips_are_rejected_preserving_previous_state() throws {
        let id = UUID()
        let states = [Float(-6), Float(-9)].map {
            EffectState(typeIdentifier: "tnf.gain", id: id, displayName: "Gain", bypass: false,
                        wetDryMix: 1, parameters: ["gain": $0], extras: [:])
        }
        let url = try write(GraphPreset(name: "Repeated ID", outputGain: 1, nodes: states))
        try assertDuplicateImportRejected(url)
    }

    func test_failed_actions_preserve_fidelity_receipt_and_baseline_until_explicit_save_as_succeeds() throws {
        let original = try write { $0["future-root"] = "private" }
        let bytes = try Data(contentsOf: original)
        let model = try assertFidelityRecovery(original)
        let notice = model.presetRecoveryNotice
        let id = model.graph.nodes[0].id
        model.updateParameter(nodeID: id, paramID: "gain", value: -9)
        model.savePreset(to: try fixture.makeDirectoryTarget())
        model.loadPreset(from: fixture.url("missing.tnf"))
        model.clearError()

        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertEqual(model.presetName, "Imported")
        XCTAssertEqual(model.suggestedPresetFilename, "Imported.tnf")
        XCTAssertNil(model.presetFileURL)
        XCTAssertEqual(model.presetRecoveryNotice, notice)
        XCTAssertTrue(model.isPresetModified)
        model.updateParameter(nodeID: id, paramID: "gain", value: -6)
        XCTAssertFalse(model.isPresetModified)
        let target = fixture.url("Supported Copy.tnf")
        model.savePreset(to: target)

        XCTAssertEqual(try PresetStore.load(from: target), model.graph.snapshot(name: "Supported Copy"))
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}

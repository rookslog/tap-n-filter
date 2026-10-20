import AVFoundation
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

    func test_missing_gain_catalog_parameter_recovers_without_skipping_and_requires_explicit_different_save_as() throws {
        let base = fixture.preset()
        let singleGain = GraphPreset(name: base.name, outputGain: base.outputGain,
                                    nodes: Array(base.nodes.prefix(1)))
        let original = try write(singleGain) { object in
            try editNode(0, in: &object) { $0["parameters"] = [String: Any]() }
        }
        let bytes = try Data(contentsOf: original)
        let model = try assertFidelityRecovery(original, context: "single Gain parameters={}")
        XCTAssertEqual(model.graph.nodes.count, 1)
        let gain = try XCTUnwrap(model.graph.nodes.first as? GainNode)
        XCTAssertEqual(gain.id, singleGain.nodes[0].id)
        let catalogGain = try XCTUnwrap(gain.parameters.first { $0.identifier == "gain" })
        XCTAssertEqual(gain.parameterValue("gain"), catalogGain.defaultValue)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        let target = fixture.url("Recovered Gain Copy.tnf")
        XCTAssertNotEqual(target, original)

        // This URL is an explicit Save As choice, never a simulated Cmd-S.
        model.savePreset(to: target)

        XCTAssertNil(model.lastError)
        let exported = try PresetStore.load(from: target)
        XCTAssertEqual(exported, model.graph.snapshot(name: "Recovered Gain Copy"))
        XCTAssertEqual(exported.nodes.first?.parameters["gain"], catalogGain.defaultValue)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func test_missing_EQ_catalog_parameter_recovers_without_skipping_and_explicit_save_as_persists_restored_key() throws {
        let base = fixture.preset()
        let original = try write(base) { object in
            try editNode(2, in: &object) { node in
                var parameters = node["parameters"] as? [String: Any] ?? [:]
                parameters.removeValue(forKey: "hp.frequency")
                node["parameters"] = parameters
            }
        }
        let bytes = try Data(contentsOf: original)
        let input = try PresetStore.load(from: original)
        var supplied = base.nodes[2].parameters
        supplied.removeValue(forKey: "hp.frequency")
        XCTAssertEqual(input.nodes[2].parameters, supplied, "All other supplied EQ keys remain unchanged")
        let model = try assertFidelityRecovery(original, context: "EQ missing hp.frequency only")
        XCTAssertEqual(model.graph.nodes.count, base.nodes.count)
        XCTAssertEqual(model.graph.nodes.map { $0.id }, base.nodes.map { $0.id })
        XCTAssertTrue(model.graph.nodes[2] is EQNode)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        let restored = model.graph.snapshot()
        XCTAssertNotNil(restored.nodes[2].parameters["hp.frequency"])
        let target = fixture.url("Recovered EQ Copy.tnf")
        XCTAssertNotEqual(target, original)

        // Persist the actual restored snapshot, not an assumed native scalar.
        model.savePreset(to: target)

        XCTAssertNil(model.lastError)
        let exported = try PresetStore.load(from: target)
        XCTAssertNotNil(exported.nodes[2].parameters["hp.frequency"])
        XCTAssertEqual(exported, model.graph.snapshot(name: "Recovered EQ Copy"))
        XCTAssertEqual(exported.nodes[2].parameters, restored.nodes[2].parameters)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}

extension PresetImportFidelityTests {
    /// Fake-only classification/file-protection witnesses, not a reproduction of
    /// U-015's native cause or a real menu/panel interaction.
    func test_pure_fake_HP_frequency_restore_loss_withholds_direct_save_and_preserves_original_file() throws {
        try assertR7FrequencyLoss(R7HighPassFrequencyNode.self, identifier: "hp.frequency", restoredValue: 20)
    }

    func test_pure_fake_LP_frequency_restore_loss_withholds_direct_save_and_preserves_original_file() throws {
        try assertR7FrequencyLoss(R7LowPassFrequencyNode.self, identifier: "lp.frequency", restoredValue: 200)
    }

    func test_pure_fake_matching_HP_and_LP_frequencies_retain_file_origin_and_direct_save() throws {
        try assertR7MatchingFrequencies(R7HighPassFrequencyNode.self)
        try assertR7MatchingFrequencies(R7LowPassFrequencyNode.self)
    }

    private func r7FrequencyPreset(highPass: Float = 100, lowPass: Float = 1_200) -> GraphPreset {
        GraphPreset(name: "Frequency witness", outputGain: 0.75, nodes: [
            EffectState(typeIdentifier: "tnf.eq", id: UUID(), displayName: "Stored filter name",
                        bypass: true, wetDryMix: 0.4,
                        parameters: ["hp.frequency": highPass, "hp.Q": 1,
                                     "lp.frequency": lowPass, "lp.Q": 1.5], extras: [:]),
        ])
    }

    private func makeR7FrequencyModel<Node: R7FrequencyNode>(
        _ nodeType: Node.Type, initial: GraphPreset
    ) throws -> (model: AppViewModel, capture: MockCaptureController, engine: AVAudioEngine) {
        let registry = EffectNodeRegistry()
        registry.register(nodeType)
        // Seed the same local fake route for session initialization, avoiding
        // construction of any native EQ through the bundled fallback preset.
        fixture.defaults.set(try JSONEncoder().encode(initial), forKey: AppViewModelDefaultsKey.graph)
        let capture = MockCaptureController()
        let engine = AVAudioEngine()
        let model = AppViewModel(capture: capture, engine: engine, registry: registry, defaults: fixture.defaults)
        return (model, capture, engine)
    }

    private func assertR7FrequencyLoss<Node: R7FrequencyNode>(
        _ nodeType: Node.Type, identifier: String, restoredValue: Float
    ) throws {
        let input = r7FrequencyPreset()
        let originalState = try XCTUnwrap(input.nodes.first)
        let requested = try XCTUnwrap(originalState.parameters[identifier])
        let parameter = try XCTUnwrap(EQNode.parameterCatalog.first { $0.identifier == identifier })
        XCTAssertTrue(parameter.range.contains(requested))
        XCTAssertTrue(parameter.range.contains(restoredValue))
        XCTAssertNotEqual(requested, restoredValue)
        XCTAssertEqual(Set(originalState.parameters.keys), Set(EQNode.parameterCatalog.map { $0.identifier }))
        for catalogParameter in EQNode.parameterCatalog {
            let value = try XCTUnwrap(originalState.parameters[catalogParameter.identifier])
            XCTAssertTrue(catalogParameter.range.contains(value), "Every requested catalog value is valid")
        }
        XCTAssertEqual(PresetMigrator.migrate(input), input, "No migration loss can explain recovery")
        let original = try write(input)
        let bytes = try Data(contentsOf: original)
        let decoded = try PresetStore.loadResult(from: original)
        XCTAssertEqual(decoded.preset, input)
        XCTAssertTrue(decoded.diagnostics.isEmpty, "No unknown raw fields can explain recovery")
        let (model, capture, engine) = try makeR7FrequencyModel(nodeType, initial: input)

        model.loadPreset(from: original)

        XCTAssertNil(model.lastError, "Nonthrowing frequency loss must not reject the import")
        let fake = try XCTUnwrap(model.graph.nodes.first as? Node)
        XCTAssertEqual(model.graph.nodes.count, 1)
        XCTAssertEqual(fake.parameters.map { $0.identifier }, EQNode.parameterCatalog.map { $0.identifier })
        XCTAssertEqual(fake.parameterValue(identifier), restoredValue)
        var expectedParameters = originalState.parameters
        expectedParameters[identifier] = restoredValue
        let expectedState = EffectState(
            typeIdentifier: originalState.typeIdentifier, id: originalState.id,
            displayName: originalState.displayName, bypass: originalState.bypass,
            wetDryMix: originalState.wetDryMix, parameters: expectedParameters, extras: originalState.extras
        )
        let restored = model.graph.snapshot()
        XCTAssertEqual(restored, GraphPreset(name: "snapshot", outputGain: input.outputGain, nodes: [expectedState]),
                       "Only one frequency differs; all other input state and catalog keys survive")
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertTrue(model.presetWarnings.isEmpty, "Nothing was skipped")
        XCTAssertEqual(model.presetName, "Imported")
        XCTAssertEqual(model.suggestedPresetFilename, "Imported.tnf")
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)
        // Nonthrowing assertions keep the Save/file-protection oracle reachable on baseline.
        XCTAssertNotNil(model.presetRecoveryNotice)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("unsupported or adjusted"), true)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("Save As"), true)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("skipped"), false)
        XCTAssertFalse(model.isPresetModified, "Canonical restored values are the clean baseline")
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        // The existing PresetMenu Save selection, without invoking GUI/panels.
        // A nil target takes the unaccepted Save As path and therefore writes nothing.
        if let target = model.presetFileURL { model.savePreset(to: target) }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(try Data(contentsOf: original), bytes, "Menu Save must not replace the requested frequency")
        XCTAssertEqual(try PresetStore.load(from: original), input)
        XCTAssertEqual(try PresetStore.load(from: original).nodes.first?.parameters[identifier], requested)
        XCTAssertEqual(model.graph.snapshot(), restored)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)

        // Explicit different-path Save As remains allowed and exports actual restored state.
        let target = fixture.url("Recovered \(identifier) Copy.tnf")
        XCTAssertNotEqual(target, original)
        model.savePreset(to: target)

        XCTAssertNil(model.lastError)
        let exported = try PresetStore.load(from: target)
        XCTAssertEqual(exported, model.graph.snapshot(name: target.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(exported.nodes, restored.nodes)
        XCTAssertEqual(exported.nodes.first?.parameters[identifier], restoredValue)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try PresetStore.load(from: original).nodes.first?.parameters[identifier], requested)
        XCTAssertTrue(capture.startCalls.isEmpty)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(fake.attachmentAttempts, 0)
    }

    private func assertR7MatchingFrequencies<Node: R7FrequencyNode>(_ nodeType: Node.Type) throws {
        // Same fake implementations and registry path, but neither deterministic
        // loss trigger is requested. Both frequencies must remain directly saveable.
        let input = r7FrequencyPreset(highPass: 80, lowPass: 800)
        let original = try write(input)
        let bytes = try Data(contentsOf: original)
        let (model, capture, engine) = try makeR7FrequencyModel(nodeType, initial: input)

        model.loadPreset(from: original)

        XCTAssertNil(model.lastError)
        let fake = try XCTUnwrap(model.graph.nodes.first as? Node)
        XCTAssertEqual(model.graph.nodes.count, 1)
        XCTAssertEqual(Set(fake.parameters.map { $0.identifier }), Set(input.nodes[0].parameters.keys))
        XCTAssertEqual(model.graph.snapshot().nodes, input.nodes)
        XCTAssertEqual(fake.parameterValue("hp.frequency"), 80)
        XCTAssertEqual(fake.parameterValue("lp.frequency"), 800)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        model.updateParameter(nodeID: fake.id, paramID: "hp.Q", value: 2)
        XCTAssertTrue(model.isPresetModified)

        if let target = model.presetFileURL { model.savePreset(to: target) }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(try PresetStore.load(from: original), model.graph.snapshot(name: "Imported"))
        XCTAssertEqual(try PresetStore.load(from: original).nodes.first?.parameters["hp.Q"], 2)
        XCTAssertNotEqual(try Data(contentsOf: original), bytes, "Matching import retains real direct-Save authority")
        XCTAssertEqual(fake.parameterValue("hp.frequency"), 80)
        XCTAssertEqual(fake.parameterValue("lp.frequency"), 800)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertTrue(capture.startCalls.isEmpty)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(fake.attachmentAttempts, 0)
    }
}

/// Stores pure value state; the mixers satisfy the protocol only. No native EQ
/// instance, parameter hook, global mutable mode, or audio attachment is used.
private class R7FrequencyNode: DefaultConstructibleEffectNode {
    static let typeIdentifier = "tnf.eq"
    static let showsWetDryByDefault = false
    var id = UUID()
    var displayName = "Pure frequency fixture"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    var parameters: [EffectParameter] { EQNode.parameterCatalog }
    private var values = Dictionary(uniqueKeysWithValues: EQNode.parameterCatalog.map {
        ($0.identifier, $0.defaultValue)
    })
    private var extras: [String: AnyCodableValue] = [:]
    private(set) var attachmentAttempts = 0
    var frequencyReplacement: (identifier: String, requested: Float, restored: Float)? { nil }

    required init() {}

    required convenience init(from decoder: Decoder) throws {
        self.init()
        try restore(from: EffectState(from: decoder))
    }

    func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = parameters.first(where: { $0.identifier == identifier }) else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard value.isFinite, parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(identifier: identifier, value: value, range: parameter.range)
        }
        values[identifier] = value
    }

    func parameterValue(_ identifier: String) -> Float? { values[identifier] }

    func snapshot() -> EffectState {
        EffectState(typeIdentifier: Self.typeIdentifier, id: id, displayName: displayName,
                    bypass: bypass, wetDryMix: wetDryMix, parameters: values, extras: extras)
    }

    func restore(from state: EffectState) {
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        values = state.parameters
        extras = state.extras
        if let replacement = frequencyReplacement,
           values[replacement.identifier] == replacement.requested {
            values[replacement.identifier] = replacement.restored
        }
    }

    func attach(to engine: AVAudioEngine) throws {
        attachmentAttempts += 1
        XCTFail("Pure frequency fixtures must never attach to an engine")
        throw R7FrequencyFixtureError.audioLifecycle
    }

    func detach() {}
}

private final class R7HighPassFrequencyNode: R7FrequencyNode {
    override var frequencyReplacement: (identifier: String, requested: Float, restored: Float)? {
        ("hp.frequency", 100, 20)
    }
}

private final class R7LowPassFrequencyNode: R7FrequencyNode {
    override var frequencyReplacement: (identifier: String, requested: Float, restored: Float)? {
        ("lp.frequency", 1_200, 200)
    }
}

private enum R7FrequencyFixtureError: Error { case audioLifecycle }

import AVFoundation
import Capture
import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

/// Stage A structural red: these minimal UI-facing observables are new API.
/// presetOrigin cases: factory, session, file, recovered.
/// presetFileURL is a SAFE direct-Save target; recovered originals have none.
/// presetWarnings remains visible independently of the dismissible lastError.
/// No receipt container, persistence store, or engine lifecycle design is prescribed.
@MainActor
final class PresetContinuityReceiptTests: XCTestCase {
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

    private func loadedModel() throws -> AppViewModel {
        let model = fixture.makeModel()
        model.loadPreset(from: try fixture.write(fixture.preset()))
        XCTAssertNil(model.lastError)
        return model
    }

    func test_loaded_file_uses_basename_and_canonical_graph_baseline_not_raw_Q_or_title() throws {
        let model = try loadedModel()

        XCTAssertEqual(model.presetName, "Studio Mix")
        XCTAssertEqual(model.suggestedPresetFilename, "Studio Mix.tnf")
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, fixture.url("Studio Mix.tnf"))
        XCTAssertFalse(model.isPresetModified, "Use the actual restored Q/bandwidth/Q snapshot")
        XCTAssertTrue(model.presetWarnings.isEmpty)
    }

    func test_parameter_change_and_return_to_baseline_clears_modified() throws {
        let model = try loadedModel()
        let node = model.graph.nodes[0]
        model.updateParameter(nodeID: node.id, paramID: "gain", value: -9)
        XCTAssertTrue(model.isPresetModified)
        model.updateParameter(nodeID: node.id, paramID: "gain", value: -6)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_bypass_change_and_return_to_baseline_clears_modified() throws {
        let model = try loadedModel()
        let id = model.graph.nodes[0].id
        model.setBypass(nodeID: id, bypass: true)
        XCTAssertTrue(model.isPresetModified)
        model.setBypass(nodeID: id, bypass: false)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_wet_dry_change_and_return_to_baseline_clears_modified() throws {
        let model = try loadedModel()
        let id = model.graph.nodes[1].id
        model.updateWetDryMix(nodeID: id, value: 0.25)
        XCTAssertTrue(model.isPresetModified)
        model.updateWetDryMix(nodeID: id, value: 0.7)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_output_gain_change_and_return_to_baseline_clears_modified() throws {
        let model = try loadedModel()
        model.graph.outputGain = 0.5
        XCTAssertTrue(model.isPresetModified)
        model.graph.outputGain = 0.75
        XCTAssertFalse(model.isPresetModified)
    }

    func test_order_and_membership_are_meaningful_graph_edits() throws {
        let model = try loadedModel()
        model.moveEffect(from: 0, to: 3)
        XCTAssertTrue(model.isPresetModified)
        model.moveEffect(from: 2, to: 0)
        XCTAssertFalse(model.isPresetModified)
        model.addEffect(of: "tnf.gain")
        XCTAssertTrue(model.isPresetModified)
        model.removeEffect(at: model.graph.nodes.count - 1)
        XCTAssertFalse(model.isPresetModified)
        model.removeEffect(at: 0)
        XCTAssertTrue(model.isPresetModified)
    }

    func test_reverb_extras_are_meaningful_graph_edits() throws {
        let model = try loadedModel()
        let node = try XCTUnwrap(model.graph.nodes[1] as? ReverbNode)
        node.preset = .smallRoom
        XCTAssertTrue(model.isPresetModified)
        node.preset = .largeHall
        XCTAssertFalse(model.isPresetModified)
    }

    func test_rejected_edits_source_and_diagnostic_drawers_do_not_dirty_graph() throws {
        let model = try loadedModel()
        let baseline = model.graph.snapshot()
        let nodeID = model.graph.nodes[0].id
        model.updateParameter(nodeID: nodeID, paramID: "gain", value: 100)
        XCTAssertNotNil(model.lastError)
        model.clearError()
        model.updateParameter(nodeID: UUID(), paramID: "gain", value: -9)
        model.updateWetDryMix(nodeID: UUID(), value: 0.25)
        model.setBypass(nodeID: UUID(), bypass: true)
        model.moveEffect(from: -1, to: 0)
        model.removeEffect(at: -1)
        model.addEffect(of: "not.registered")
        model.setSource(CaptureSource(pid: 1234, audioProcessID: 42,
                                     bundleIdentifier: "com.example.fixture", displayName: "Fixture"))
        model.toggleDebugPanel()
        model.toggleSettings()
        model.expandedEffectID = nodeID
        model.clearError()

        XCTAssertEqual(model.graph.snapshot(), baseline)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(model.presetFileURL, fixture.url("Studio Mix.tnf"))
    }

    func test_save_as_establishes_new_receipt_and_baseline_after_file_is_written() throws {
        let model = try loadedModel()
        let originalBytes = try Data(contentsOf: fixture.url("Studio Mix.tnf"))
        model.updateParameter(nodeID: model.graph.nodes[0].id, paramID: "gain", value: -9)
        let target = fixture.url("My Mix.v2.tnf")
        model.savePreset(to: target)

        XCTAssertEqual(try PresetStore.load(from: target), model.graph.snapshot(name: "My Mix.v2"))
        XCTAssertEqual(model.presetName, "My Mix.v2")
        XCTAssertEqual(model.suggestedPresetFilename, "My Mix.v2.tnf")
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: fixture.url("Studio Mix.tnf")), originalBytes)

        // The menu's known-file Save can reuse the existing savePreset(to:) API.
        model.updateParameter(nodeID: model.graph.nodes[0].id, paramID: "gain", value: -12)
        model.savePreset(to: try XCTUnwrap(model.presetFileURL))
        XCTAssertEqual(try PresetStore.load(from: target).nodes[0].parameters["gain"], -12)
        XCTAssertFalse(model.isPresetModified)
        model.updateParameter(nodeID: model.graph.nodes[0].id, paramID: "gain", value: -9)
        XCTAssertTrue(model.isPresetModified, "A successful Save advances the baseline")
    }

    func test_failed_save_as_preserves_prior_receipt_and_baseline() throws {
        let model = try loadedModel()
        let original = try XCTUnwrap(model.presetFileURL)
        let originalBytes = try Data(contentsOf: original)
        let id = model.graph.nodes[0].id
        model.updateParameter(nodeID: id, paramID: "gain", value: -9)

        model.savePreset(to: try fixture.makeDirectoryTarget())

        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertEqual(model.presetName, "Studio Mix")
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertTrue(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        model.updateParameter(nodeID: id, paramID: "gain", value: -6)
        XCTAssertFalse(model.isPresetModified, "The rejected write must not advance the baseline")
    }

    func test_failed_load_preserves_receipt_dirty_graph_and_baseline() throws {
        let model = try loadedModel()
        let graph = model.graph
        let id = graph.nodes[0].id
        model.updateParameter(nodeID: id, paramID: "gain", value: -9)
        model.loadPreset(from: fixture.url("missing.tnf"))

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.graph === graph)
        XCTAssertEqual(model.presetName, "Studio Mix")
        XCTAssertEqual(model.presetFileURL, fixture.url("Studio Mix.tnf"))
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertTrue(model.isPresetModified)
        model.updateParameter(nodeID: id, paramID: "gain", value: -6)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_factory_and_restored_session_are_clean_but_have_no_known_file_target() throws {
        let model = fixture.makeModel()
        XCTAssertEqual(model.presetOrigin, .factory)
        XCTAssertEqual(model.presetName, "Distant Engines")
        XCTAssertNil(model.presetFileURL)
        XCTAssertFalse(model.isPresetModified)
        model.loadFactoryPreset(named: "dry")
        XCTAssertEqual(model.presetOrigin, .factory)
        XCTAssertEqual(model.presetName, "Dry")
        XCTAssertNil(model.presetFileURL)
        XCTAssertFalse(model.isPresetModified)

        fixture.defaults.set(try JSONEncoder().encode(fixture.preset()), forKey: AppViewModelDefaultsKey.graph)
        let restored = fixture.makeModel()
        XCTAssertEqual(restored.presetOrigin, .session)
        XCTAssertEqual(restored.presetName, "Restored Session")
        XCTAssertNil(restored.presetFileURL)
        XCTAssertFalse(restored.isPresetModified)
    }

    func test_factory_load_replaces_export_identity_and_dirty_baseline() throws {
        let model = try loadedModel()
        model.graph.outputGain = 0.5
        XCTAssertTrue(model.isPresetModified)
        model.loadFactoryPreset(named: "dry")
        XCTAssertEqual(model.presetOrigin, .factory)
        XCTAssertEqual(model.presetName, "Dry")
        XCTAssertNil(model.presetFileURL)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_autosaved_session_never_restores_export_URL_or_bookmark() async throws {
        let model = try loadedModel()
        let target = fixture.url("Exported.tnf")
        model.savePreset(to: target)
        // Trigger the existing debounced session write without starting audio.
        model.updateParameter(nodeID: model.graph.nodes[0].id, paramID: "gain", value: -9)
        for _ in 0..<100 {
            if fixture.defaults.data(forKey: AppViewModelDefaultsKey.graph) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(fixture.defaults.data(forKey: AppViewModelDefaultsKey.graph))
        let stored = fixture.defaults.persistentDomain(forName: fixture.suiteName) ?? [:]
        XCTAssertEqual(Set(stored.keys), Set([AppViewModelDefaultsKey.graph]),
                       "No file URL, bookmark, or file receipt belongs in last-session defaults")
        let restored = fixture.makeModel()
        XCTAssertEqual(restored.presetOrigin, .session)
        XCTAssertEqual(restored.presetName, "Restored Session")
        XCTAssertNil(restored.presetFileURL)
        XCTAssertEqual(restored.graph.nodes[0].parameterValue("gain"), -9)
        XCTAssertFalse(restored.isPresetModified)
    }

    func test_partial_recovery_retains_name_and_visible_warnings_but_is_not_a_direct_save_target() throws {
        let model = try loadedModel()
        let url = try fixture.write(fixture.partialPreset(), filename: "Recovered Mix.tnf")
        let originalBytes = try Data(contentsOf: url)
        model.loadPreset(from: url)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.presetName, "Recovered Mix")
        XCTAssertEqual(model.suggestedPresetFilename, "Recovered Mix.tnf")
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL, "Save must route to Save As, not overwrite the recovered original")
        XCTAssertEqual(model.presetWarnings, model.graph.lastLoadWarnings)
        XCTAssertEqual(model.presetWarnings.count, 2)
        model.clearError()
        model.toggleDebugPanel()
        XCTAssertEqual(model.presetWarnings.count, 2, "Recovery must remain visible outside Diagnostics")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func test_recovery_context_survives_failures_until_successful_explicit_save_as() throws {
        let model = fixture.makeModel()
        let original = try fixture.write(fixture.partialPreset(), filename: "Recovered Mix.tnf")
        let originalBytes = try Data(contentsOf: original)
        model.loadPreset(from: original)
        let warnings = model.presetWarnings

        model.savePreset(to: try fixture.makeDirectoryTarget())
        model.loadPreset(from: fixture.url("missing.tnf"))
        model.clearError()
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertEqual(model.presetName, "Recovered Mix")
        XCTAssertEqual(model.suggestedPresetFilename, "Recovered Mix.tnf")
        XCTAssertNil(model.presetFileURL)
        XCTAssertEqual(model.presetWarnings, warnings)

        let target = fixture.url("Recovered Copy.tnf")
        model.savePreset(to: target)
        XCTAssertEqual(try PresetStore.load(from: target), model.graph.snapshot(name: "Recovered Copy"))
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetName, "Recovered Copy")
        XCTAssertEqual(model.presetFileURL, target)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func test_explicit_save_as_may_choose_the_recovered_original_after_panel_confirmation() throws {
        let model = fixture.makeModel()
        let original = try fixture.write(fixture.partialPreset())
        model.loadPreset(from: original)
        XCTAssertNil(model.presetFileURL)

        // The caller has explicitly supplied the panel's accepted URL. This
        // exercises the post-confirmation VM path without presenting AppKit.
        model.savePreset(to: original)

        XCTAssertEqual(try PresetStore.load(from: original).nodes.count, 1)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertFalse(model.isPresetModified)
        XCTAssertTrue(model.presetWarnings.isEmpty)
    }
}

import AVFoundation
import Capture
import Effects
import Foundation
import Graph
import Presets
import XCTest
@testable import ViewModel

/// Only isolated suite fixtures are read or written. Engines are constructed,
/// never started; capture/source enumeration is supplied by the existing mock.
/// Future-session fixtures exercise recoverable fallback and byte preservation.
@MainActor
final class AppViewModelSessionRecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var models: [AppViewModel] = []

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "tnf.session-recovery.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        // Release models/cancel pending autosaves before removing the suite.
        models.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeModel(capture: MockCaptureController = MockCaptureController()) -> AppViewModel {
        let model = AppViewModel(
            capture: capture, engine: AVAudioEngine(), registry: EffectNodeRegistry(), defaults: defaults
        )
        models.append(model)
        return model
    }

    private func source(_ index: Int = 1) -> CaptureSource {
        CaptureSource(
            pid: pid_t(index), audioProcessID: 42,
            bundleIdentifier: "com.example.session-recovery.\(index)", displayName: "Fixture \(index)"
        )
    }

    private func seedFutureSession() throws -> Data {
        // Formatting and an unknown field catch decode/re-encode replacements,
        // even if they happen to preserve the fields this build understands.
        let raw = Data("""
          { "nodes": [], "formatVersion": \(PresetMigrator.currentFormatVersion + 1),
            "name": "future fixture", "outputGain": 0.25,
            "futureOnly": { "mustSurvive": true } }

        """.utf8)
        let decoded = try JSONDecoder().decode(GraphPreset.self, from: raw)
        XCTAssertGreaterThan(decoded.formatVersion, PresetMigrator.currentFormatVersion)
        defaults.set(raw, forKey: AppViewModelDefaultsKey.graph)
        return raw
    }

    private func waitForAutosave() async throws {
        // Existing debounce is 200 ms. Yield the main actor beyond its window;
        // source-key assertions below also check that persistence actually ran.
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func writePresetFixture(_ preset: GraphPreset) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-session-recovery-\(UUID().uuidString).tnf")
        try JSONEncoder().encode(preset).write(to: url, options: .atomic)
        return url
    }

    private func assertSourceOnlyWritePreserves(
        _ raw: Data, model: AppViewModel, sourceIndex: Int = 1,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let selected = source(sourceIndex)
        model.setSource(selected)
        try await waitForAutosave()
        XCTAssertEqual(
            defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID), selected.bundleIdentifier,
            "Source persistence must remain enabled", file: file, line: line
        )
        XCTAssertEqual(defaults.data(forKey: AppViewModelDefaultsKey.graph), raw, file: file, line: line)
    }

    func test_future_session_falls_back_without_starting_capture_or_rewriting_bytes() async throws {
        let raw = try seedFutureSession()
        let capture = MockCaptureController()
        let model = makeModel(capture: capture)
        let fallback = try FactoryPresets.load(named: "distant-engines")
        let actual = model.graph.snapshot()
        XCTAssertEqual(actual.nodes.map(\.typeIdentifier), fallback.nodes.map(\.typeIdentifier))
        XCTAssertEqual(actual.outputGain, fallback.outputGain)
        XCTAssertEqual(actual.nodes.last?.extras, fallback.nodes.last?.extras)
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertTrue(capture.startCalls.isEmpty)
        guard case .persistence(let message) = model.lastError else {
            XCTFail("Fallback must surface a recoverable session warning in lastError")
            return
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(
            message.contains(String(PresetMigrator.currentFormatVersion + 1)),
            "Warning must identify the unsupported format version"
        )
        try await waitForAutosave()
        XCTAssertEqual(defaults.data(forKey: AppViewModelDefaultsKey.graph), raw)
    }

    func test_future_header_with_missing_current_schema_preserves_bytes_and_warns() async throws {
        let version = PresetMigrator.currentFormatVersion + 1
        let raw = Data("""
          { "formatVersion": \(version),
            "futureGraph": { "routing": ["future-only"], "mustSurvive": true } }

        """.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, version)
        XCTAssertThrowsError(try JSONDecoder().decode(GraphPreset.self, from: raw))
        defaults.set(raw, forKey: AppViewModelDefaultsKey.graph)

        let capture = MockCaptureController()
        let model = makeModel(capture: capture)
        let fallback = try FactoryPresets.load(named: "distant-engines")
        XCTAssertEqual(model.graph.snapshot().nodes.map(\.typeIdentifier), fallback.nodes.map(\.typeIdentifier))
        XCTAssertEqual(model.graph.outputGain, fallback.outputGain)
        XCTAssertEqual(model.captureState, .idle)
        XCTAssertTrue(capture.startCalls.isEmpty)
        if case .persistence(let message) = model.lastError {
            XCTAssertTrue(message.contains(String(version)), "Warning must identify the future version")
        } else {
            XCTFail("A readable future header must warn even when the current schema cannot decode")
        }
        try await waitForAutosave()
        XCTAssertEqual(defaults.data(forKey: AppViewModelDefaultsKey.graph), raw)
        try await assertSourceOnlyWritePreserves(raw, model: model)
        model.clearError()
        try await assertSourceOnlyWritePreserves(raw, model: model, sourceIndex: 2)
        model.setSource(nil)
        try await waitForAutosave()
        XCTAssertNil(defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID))
        XCTAssertEqual(defaults.data(forKey: AppViewModelDefaultsKey.graph), raw)
        try await assertSourceOnlyWritePreserves(raw, model: makeModel(), sourceIndex: 3)
    }

    func test_source_selection_and_clearing_preserve_exact_future_session_bytes() async throws {
        let raw = try seedFutureSession()
        let model = makeModel()
        model.clearError() // Dismissing the warning does not authorize replacement.
        try await assertSourceOnlyWritePreserves(raw, model: model)
        model.setSource(nil)
        try await waitForAutosave()
        XCTAssertNil(defaults.string(forKey: AppViewModelDefaultsKey.sourceBundleID))
        XCTAssertEqual(defaults.data(forKey: AppViewModelDefaultsKey.graph), raw)
        // Protection must survive another launch, not merely one model instance.
        try await assertSourceOnlyWritePreserves(raw, model: makeModel(), sourceIndex: 2)
    }

    func test_failed_explicit_edits_do_not_authorize_future_session_replacement() async throws {
        let raw = try seedFutureSession()
        let model = makeModel()
        let eq = try XCTUnwrap(model.graph.nodes.first)
        let futureFile = try writePresetFixture(JSONDecoder().decode(GraphPreset.self, from: raw))
        defer { try? FileManager.default.removeItem(at: futureFile) }
        let edits: [(AppViewModel) -> Void] = [
            { $0.addEffect(of: "tnf.fixture.missing") },
            { $0.removeEffect(at: -1) },
            { $0.moveEffect(from: 0, to: $0.graph.nodes.count + 1) },
            { $0.updateParameter(nodeID: eq.id, paramID: "fixture.missing", value: 1) },
            { $0.updateParameter(nodeID: eq.id, paramID: "hp.Q", value: -1) },
            { $0.updateParameter(nodeID: UUID(), paramID: "hp.Q", value: 1) },
            { $0.updateWetDryMix(nodeID: UUID(), value: 0.5) },
            { $0.setBypass(nodeID: UUID(), bypass: true) },
            { $0.loadFactoryPreset(named: "fixture-missing") },
            { $0.loadPreset(from: futureFile) },
        ]
        for (index, edit) in edits.enumerated() {
            model.clearError()
            let before = model.graph.snapshot()
            edit(model)
            XCTAssertNotNil(model.lastError, "Fixture edit \(index) must actually fail")
            XCTAssertEqual(model.graph.snapshot(), before)
            try await assertSourceOnlyWritePreserves(raw, model: model, sourceIndex: index + 1)
        }
    }

    func test_successful_no_op_edits_do_not_authorize_future_session_replacement() async throws {
        let raw = try seedFutureSession()
        let model = makeModel()
        let eq = try XCTUnwrap(model.graph.nodes.first)
        let frequency = try XCTUnwrap(eq.parameterValue("hp.frequency"))
        let samePresetFile = try writePresetFixture(FactoryPresets.load(named: "distant-engines"))
        defer { try? FileManager.default.removeItem(at: samePresetFile) }
        let edits: [(AppViewModel) -> Void] = [
            { $0.moveEffect(from: 0, to: 0) },
            { $0.updateParameter(nodeID: eq.id, paramID: "hp.frequency", value: frequency) },
            { $0.updateWetDryMix(nodeID: eq.id, value: eq.wetDryMix) },
            { $0.setBypass(nodeID: eq.id, bypass: eq.bypass) },
            { $0.updateWetDryMix(nodeID: eq.id, value: 2) }, // Clamps to the EQ's existing 1.0.
            { $0.loadFactoryPreset(named: "distant-engines") },
            { $0.loadPreset(from: samePresetFile) },
        ]
        for (index, edit) in edits.enumerated() {
            model.clearError()
            let before = model.graph.snapshot()
            edit(model)
            XCTAssertNil(model.lastError, "Fixture edit \(index) must be a successful no-op")
            XCTAssertEqual(model.graph.snapshot(), before)
            try await assertSourceOnlyWritePreserves(raw, model: model, sourceIndex: index + 1)
        }
    }

    func test_meaningful_successful_graph_edits_supersede_future_bytes_and_resume_autosave() async throws {
        let dryFile = try writePresetFixture(FactoryPresets.load(named: "dry"))
        defer { try? FileManager.default.removeItem(at: dryFile) }
        let edits: [(AppViewModel) -> Void] = [
            { $0.addEffect(of: "tnf.eq") },
            { $0.removeEffect(at: 0) },
            { $0.moveEffect(from: 0, to: $0.graph.nodes.count) },
            { $0.updateParameter(nodeID: $0.graph.nodes[0].id, paramID: "hp.Q", value: 2.5) },
            { $0.updateWetDryMix(nodeID: $0.graph.nodes[0].id, value: 0.5) },
            { $0.setBypass(nodeID: $0.graph.nodes[0].id, bypass: true) },
            { $0.loadFactoryPreset(named: "dry") },
            { $0.loadPreset(from: dryFile) },
        ]
        for (index, edit) in edits.enumerated() {
            let raw = try seedFutureSession()
            let model = makeModel()
            model.clearError()
            let before = model.graph.snapshot()
            edit(model)
            XCTAssertNil(model.lastError, "Fixture edit \(index) must succeed")
            XCTAssertNotEqual(model.graph.snapshot(), before, "Fixture edit must be meaningful")
            try await waitForAutosave()
            let saved = try XCTUnwrap(defaults.data(forKey: AppViewModelDefaultsKey.graph))
            XCTAssertNotEqual(saved, raw)
            let decoded = try JSONDecoder().decode(GraphPreset.self, from: saved)
            XCTAssertEqual(decoded.formatVersion, PresetMigrator.currentFormatVersion)
            XCTAssertEqual(decoded, model.graph.snapshot(name: "lastSession"))
            // Source-only autosaves after the explicit replacement use the new graph.
            try await assertSourceOnlyWritePreserves(saved, model: model, sourceIndex: index + 1)
            // The guard must not remain latched after the first replacement:
            // a subsequent graph edit must also reach persistence.
            model.addEffect(of: "tnf.reverb")
            XCTAssertNil(model.lastError)
            try await waitForAutosave()
            let nextSaved = try XCTUnwrap(defaults.data(forKey: AppViewModelDefaultsKey.graph))
            XCTAssertNotEqual(nextSaved, saved)
            let nextDecoded = try JSONDecoder().decode(GraphPreset.self, from: nextSaved)
            XCTAssertEqual(nextDecoded, model.graph.snapshot(name: "lastSession"))
            let restored = makeModel()
            XCTAssertEqual(restored.graph.nodes.count, nextDecoded.nodes.count)
            XCTAssertEqual(restored.graph.nodes.map(\.id), nextDecoded.nodes.map(\.id))
            XCTAssertEqual(
                restored.graph.nodes.map { type(of: $0).typeIdentifier }, nextDecoded.nodes.map(\.typeIdentifier)
            )
            XCTAssertEqual(restored.graph.outputGain, nextDecoded.outputGain)
            for (node, state) in zip(restored.graph.nodes, nextDecoded.nodes) {
                XCTAssertEqual(node.bypass, state.bypass)
                XCTAssertEqual(node.wetDryMix, state.wetDryMix)
                XCTAssertEqual(node.snapshot().extras, state.extras)
                for (identifier, value) in state.parameters {
                    XCTAssertEqual(try XCTUnwrap(node.parameterValue(identifier)), value, accuracy: 0.01)
                }
            }
        }
    }

    func test_supported_session_repairs_corrupt_Q_and_round_trips_legal_Q_and_reverb_extras() async throws {
        let bundled = try FactoryPresets.load(named: "distant-engines")
        let eq = try XCTUnwrap(bundled.nodes.first)
        var parameters = eq.parameters
        parameters["hp.Q"] = 14_426.951
        parameters["lp.Q"] = 4
        let corruptEQ = EffectState(
            typeIdentifier: eq.typeIdentifier, id: eq.id, displayName: eq.displayName,
            bypass: eq.bypass, wetDryMix: eq.wetDryMix, parameters: parameters, extras: eq.extras
        )
        for version in [0, PresetMigrator.currentFormatVersion] {
            let preset = GraphPreset(
                formatVersion: version, name: "supported fixture", outputGain: 0.4,
                nodes: [corruptEQ] + Array(bundled.nodes.dropFirst())
            )
            defaults.set(try JSONEncoder().encode(preset), forKey: AppViewModelDefaultsKey.graph)
            let model = makeModel()
            XCTAssertNil(model.lastError)
            XCTAssertEqual(model.graph.nodes[0].parameterValue("hp.Q") ?? 0, 0.707, accuracy: 0.01)
            XCTAssertEqual(model.graph.nodes[0].parameterValue("lp.Q") ?? 0, 4, accuracy: 0.01)
            XCTAssertEqual(model.graph.nodes.last?.snapshot().extras, bundled.nodes.last?.extras)
            model.setSource(source(version + 1))
            try await waitForAutosave()
            let saved = try XCTUnwrap(defaults.data(forKey: AppViewModelDefaultsKey.graph))
            XCTAssertEqual(
                try JSONDecoder().decode(GraphPreset.self, from: saved),
                model.graph.snapshot(name: "lastSession")
            )
            let restored = makeModel()
            XCTAssertEqual(restored.graph.nodes[0].parameterValue("hp.Q") ?? 0, 0.707, accuracy: 0.01)
            XCTAssertEqual(restored.graph.nodes[0].parameterValue("lp.Q") ?? 0, 4, accuracy: 0.01)
            XCTAssertEqual(restored.graph.nodes.last?.snapshot().extras, bundled.nodes.last?.extras)
        }
    }
}

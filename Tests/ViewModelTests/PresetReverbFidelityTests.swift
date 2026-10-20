import AVFoundation
import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

@MainActor
final class PresetReverbFidelityTests: XCTestCase {
    func test_missing_reverb_preset_withholds_menu_save_and_preserves_file_until_different_save_as() throws {
        let fixture = try R8ReverbFixture()
        defer { fixture.finish() }
        let input = fixture.reverbPreset(extras: [:])
        let original = try fixture.write(input)
        let bytes = try Data(contentsOf: original)
        let decoded = try PresetStore.loadResult(from: original)
        XCTAssertEqual(decoded.preset, input)
        XCTAssertTrue(decoded.diagnostics.isEmpty)
        XCTAssertEqual(PresetMigrator.migrate(input), input)
        let model = fixture.model

        model.loadPreset(from: original)

        XCTAssertNil(model.lastError)
        let fake = try XCTUnwrap(model.graph.nodes.first as? R8ReverbNode)
        XCTAssertEqual(model.graph.nodes.count, 1)
        XCTAssertTrue(fake.parameters.isEmpty)
        var expectedExtras = input.nodes[0].extras
        expectedExtras["preset"] = .string("largeHall")
        let expected = EffectState(
            typeIdentifier: input.nodes[0].typeIdentifier, id: input.nodes[0].id,
            displayName: input.nodes[0].displayName, bypass: input.nodes[0].bypass,
            wetDryMix: input.nodes[0].wetDryMix, parameters: [:], extras: expectedExtras
        )
        let restored = model.graph.snapshot()
        XCTAssertEqual(restored, GraphPreset(name: "snapshot", outputGain: input.outputGain, nodes: [expected]))
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertTrue(model.presetWarnings.isEmpty, "No effect was skipped")
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)
        XCTAssertEqual(model.presetName, "Imported")
        // Nonthrowing: the original-file oracle must remain reachable on the bad baseline.
        XCTAssertNotNil(model.presetRecoveryNotice)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("unsupported or adjusted"), true)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("Save As"), true)
        XCTAssertEqual(model.presetRecoveryNotice?.contains("skipped"), false)
        XCTAssertFalse(model.isPresetModified, "Actual default restoration is the clean baseline")
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        // Existing PresetMenu Save selection only; nil does not accept a Save As panel.
        if let target = model.presetFileURL { model.savePreset(to: target) }

        XCTAssertNil(model.lastError)
        XCTAssertEqual(try Data(contentsOf: original), bytes, "Menu Save must preserve omitted preset")
        XCTAssertEqual(try PresetStore.load(from: original), input)
        XCTAssertNil(try PresetStore.load(from: original).nodes.first?.extras["preset"])
        XCTAssertEqual(model.graph.snapshot(), restored)
        XCTAssertEqual(model.presetOrigin, .recovered)
        XCTAssertNil(model.presetFileURL)
        XCTAssertFalse(model.isPresetModified)

        let target = fixture.url("Recovered Reverb Copy.tnf")
        XCTAssertNotEqual(target, original)
        model.savePreset(to: target)

        XCTAssertNil(model.lastError)
        let exported = try PresetStore.load(from: target)
        XCTAssertEqual(exported, model.graph.snapshot(name: "Recovered Reverb Copy"))
        XCTAssertEqual(exported.nodes, restored.nodes)
        XCTAssertEqual(exported.nodes.first?.extras["preset"], .string("largeHall"))
        assertFileReceipt(model, url: target)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertNil(try PresetStore.load(from: original).nodes.first?.extras["preset"])
    }

    func test_present_string_reverb_retains_direct_save_and_exports_real_bypass_edit() throws {
        let fixture = try R8ReverbFixture()
        defer { fixture.finish() }
        let input = fixture.reverbPreset(extras: ["preset": .string("plate")])
        let original = try fixture.write(input)
        let bytes = try Data(contentsOf: original)
        let model = fixture.model

        model.loadPreset(from: original)

        _ = try XCTUnwrap(model.graph.nodes.first as? R8ReverbNode)
        XCTAssertEqual(model.graph.snapshot().nodes, input.nodes)
        assertFileReceipt(model, url: original)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        model.setBypass(nodeID: input.nodes[0].id, bypass: !input.nodes[0].bypass)
        XCTAssertTrue(model.isPresetModified)

        if let target = model.presetFileURL { model.savePreset(to: target) }

        let exported = try PresetStore.load(from: original)
        XCTAssertEqual(exported, model.graph.snapshot(name: "Imported"))
        XCTAssertEqual(exported.nodes.first?.extras["preset"], .string("plate"))
        XCTAssertEqual(exported.nodes.first?.bypass, !input.nodes[0].bypass)
        XCTAssertNotEqual(try Data(contentsOf: original), bytes)
        assertFileReceipt(model, url: original)
    }

    func test_legacy_integer_reverb_retains_direct_save_and_canonicalizes_to_named_preset() throws {
        let fixture = try R8ReverbFixture()
        defer { fixture.finish() }
        let input = fixture.reverbPreset(extras: ["preset": .int(AVAudioUnitReverbPreset.plate.rawValue)])
        let original = try fixture.write(input)
        let bytes = try Data(contentsOf: original)
        let decoded = try PresetStore.loadResult(from: original)
        XCTAssertTrue(decoded.diagnostics.isEmpty)
        XCTAssertEqual(decoded.preset, input)
        XCTAssertEqual(PresetMigrator.migrate(input), input)
        let model = fixture.model

        model.loadPreset(from: original)

        _ = try XCTUnwrap(model.graph.nodes.first as? R8ReverbNode)
        let restored = model.graph.snapshot()
        let state = input.nodes[0]
        XCTAssertEqual(restored, GraphPreset(name: "snapshot", outputGain: input.outputGain, nodes: [
            EffectState(typeIdentifier: state.typeIdentifier, id: state.id, displayName: state.displayName,
                        bypass: state.bypass, wetDryMix: state.wetDryMix, parameters: state.parameters,
                        extras: ["preset": .string("plate")]),
        ]))
        assertFileReceipt(model, url: original)
        XCTAssertEqual(try Data(contentsOf: original), bytes)

        if let target = model.presetFileURL { model.savePreset(to: target) }

        let exported = try PresetStore.load(from: original)
        XCTAssertEqual(exported, model.graph.snapshot(name: "Imported"))
        XCTAssertEqual(exported.nodes, restored.nodes)
        XCTAssertEqual(exported.nodes.first?.extras["preset"], .string("plate"))
        XCTAssertNotEqual(try Data(contentsOf: original), bytes)
        assertFileReceipt(model, url: original)
    }

    func test_complete_gain_and_EQ_catalogs_with_empty_extras_retain_file_authority() throws {
        for identifier in ["tnf.gain", "tnf.eq"] {
            let fixture = try R8ReverbFixture()
            defer { fixture.finish() }
            let catalog = identifier == "tnf.eq" ? EQNode.parameterCatalog : GainNode.parameterCatalog
            let values: [String: Float] = identifier == "tnf.eq"
                ? ["hp.frequency": 100, "hp.Q": 1, "lp.frequency": 1_200, "lp.Q": 1.5]
                : ["gain": -6]
            XCTAssertEqual(Set(values.keys), Set(catalog.map { $0.identifier }), identifier)
            for parameter in catalog {
                let value = try XCTUnwrap(values[parameter.identifier])
                XCTAssertTrue(value.isFinite && parameter.range.contains(value), identifier)
            }
            let input = GraphPreset(name: "Complete control", outputGain: 0.75, nodes: [
                EffectState(typeIdentifier: identifier, id: UUID(), displayName: "Stored control",
                            bypass: true, wetDryMix: 0.4, parameters: values, extras: [:]),
            ])
            XCTAssertEqual(PresetMigrator.migrate(input), input)
            let original = try fixture.write(input)
            let bytes = try Data(contentsOf: original)
            XCTAssertTrue(try PresetStore.loadResult(from: original).diagnostics.isEmpty)
            let model = fixture.model

            model.loadPreset(from: original)

            let fake = try XCTUnwrap(model.graph.nodes.first as? R8ValueNode)
            XCTAssertEqual(type(of: fake).typeIdentifier, identifier)
            XCTAssertEqual(fake.parameters, catalog)
            XCTAssertEqual(model.graph.snapshot().nodes, input.nodes, identifier)
            XCTAssertEqual(model.graph.snapshot().outputGain, input.outputGain, identifier)
            assertFileReceipt(model, url: original)
            XCTAssertEqual(try Data(contentsOf: original), bytes)

            if let target = model.presetFileURL { model.savePreset(to: target) }

            XCTAssertEqual(try PresetStore.load(from: original), model.graph.snapshot(name: "Imported"))
            XCTAssertEqual(try PresetStore.load(from: original).nodes, input.nodes, identifier)
            assertFileReceipt(model, url: original)
        }
    }

    private func assertFileReceipt(_ model: AppViewModel, url: URL) {
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, url)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
    }
}

/// Private per-model state; the complete session seed prevents native factory fallback.
@MainActor
private final class R8ReverbFixture {
    let suiteName = "tnf.tests.reverb-fidelity.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let registry = EffectNodeRegistry()
    let capture = MockCaptureController()
    let engine = AVAudioEngine()
    let model: AppViewModel
    private let sessionNodes: [R8ValueNode]

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-reverb-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry.register(R8ReverbNode.self)
        registry.register(R8GainNode.self)
        registry.register(R8EQNode.self)
        let seed = GraphPreset(name: "Finite canonical session", outputGain: 0.75, nodes: [
            EffectState(typeIdentifier: "tnf.reverb", id: UUID(), displayName: "Session Reverb",
                        bypass: false, wetDryMix: 0.5, parameters: [:], extras: ["preset": .string("largeHall")]),
            EffectState(typeIdentifier: "tnf.gain", id: UUID(), displayName: "Session Gain",
                        bypass: false, wetDryMix: 1,
                        parameters: Dictionary(uniqueKeysWithValues: GainNode.parameterCatalog.map {
                            ($0.identifier, $0.defaultValue)
                        }), extras: [:]),
            EffectState(typeIdentifier: "tnf.eq", id: UUID(), displayName: "Session EQ",
                        bypass: false, wetDryMix: 1,
                        parameters: Dictionary(uniqueKeysWithValues: EQNode.parameterCatalog.map {
                            ($0.identifier, $0.defaultValue)
                        }), extras: [:]),
        ])
        defaults.set(try JSONEncoder().encode(seed), forKey: AppViewModelDefaultsKey.graph)
        let initializedModel = AppViewModel(capture: capture, engine: engine, registry: registry, defaults: defaults)
        model = initializedModel
        sessionNodes = initializedModel.graph.nodes.compactMap { $0 as? R8ValueNode }
        XCTAssertEqual(sessionNodes.count, 3)
        XCTAssertEqual(model.presetOrigin, .session)
        XCTAssertEqual(model.graph.snapshot().nodes, seed.nodes)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertFalse(model.isPresetModified)
    }

    func reverbPreset(extras: [String: AnyCodableValue]) -> GraphPreset {
        GraphPreset(name: "Stored Reverb", outputGain: 0.75, nodes: [
            EffectState(typeIdentifier: "tnf.reverb", id: UUID(), displayName: "Stored Reverb name",
                        bypass: false, wetDryMix: 0.7, parameters: [:], extras: extras),
        ])
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func write(_ preset: GraphPreset) throws -> URL {
        let target = url("Imported.tnf")
        try PresetStore.save(preset, to: target)
        return target
    }

    func finish() {
        XCTAssertTrue(capture.startCalls.isEmpty)
        XCTAssertNil(capture.captureSourceNode)
        XCTAssertFalse(engine.isRunning)
        let currentNodes = model.graph.nodes.compactMap { $0 as? R8ValueNode }
        XCTAssertEqual(currentNodes.count, model.graph.nodes.count)
        for node in sessionNodes + currentNodes {
            XCTAssertEqual(node.attachmentAttempts, 0)
        }
        defaults.removePersistentDomain(forName: suiteName)
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Reverb fixture cleanup failed: \(error)") }
    }
}

/// Value storage only. Mixers satisfy protocol buses and are never attached.
private class R8ValueNode: DefaultConstructibleEffectNode {
    class var typeIdentifier: String { "tnf.reverb" }
    var id = UUID()
    var displayName = "Pure value fixture"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    var parameters: [EffectParameter] { [] }
    private var values: [String: Float] = [:]
    private var extras: [String: AnyCodableValue] = [:]
    private(set) var attachmentAttempts = 0

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

    func restore(from state: EffectState) throws {
        guard state.typeIdentifier == Self.typeIdentifier else {
            throw EffectRestoreError.typeIdentifierMismatch(expected: Self.typeIdentifier, actual: state.typeIdentifier)
        }
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        values = state.parameters
        extras = state.extras
    }

    func attach(to engine: AVAudioEngine) throws {
        attachmentAttempts += 1
        XCTFail("Pure value Reverb fidelity fixture must never attach")
        throw R8FixtureError.audioLifecycle
    }

    func detach() {}
}

private final class R8ReverbNode: R8ValueNode {
    private var preset = ReverbNode.defaultPreset

    override func restore(from state: EffectState) throws {
        try super.restore(from: state)
        if let extra = state.extras["preset"] {
            switch extra {
            case .string(let name):
                guard let resolved = ReverbNode.preset(forName: name) else { throw R8FixtureError.invalidPreset }
                preset = resolved
            case .int(let raw):
                guard let resolved = AVAudioUnitReverbPreset(rawValue: raw) else { throw R8FixtureError.invalidPreset }
                preset = resolved
            default: throw R8FixtureError.invalidPreset
            }
        }
    }

    override func snapshot() -> EffectState {
        EffectState(typeIdentifier: Self.typeIdentifier, id: id, displayName: displayName,
                    bypass: bypass, wetDryMix: wetDryMix, parameters: [:],
                    extras: ["preset": .string(ReverbNode.name(for: preset))])
    }
}

private final class R8GainNode: R8ValueNode {
    override class var typeIdentifier: String { "tnf.gain" }
    override var parameters: [EffectParameter] { GainNode.parameterCatalog }
}

private final class R8EQNode: R8ValueNode {
    override class var typeIdentifier: String { "tnf.eq" }
    override var parameters: [EffectParameter] { EQNode.parameterCatalog }
}

private enum R8FixtureError: Error { case audioLifecycle, invalidPreset }

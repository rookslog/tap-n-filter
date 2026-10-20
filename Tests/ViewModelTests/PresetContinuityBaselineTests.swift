import AVFoundation
import Capture
import Combine
import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

/// Regression coverage for preset I/O preservation and VM observation.
@MainActor
final class PresetContinuityBaselineTests: XCTestCase {
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

    func test_load_restores_effect_order_identity_gain_and_reverb_extras() throws {
        let model = fixture.makeModel()
        let preset = fixture.preset()
        let url = try fixture.write(preset)

        model.loadPreset(from: url)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.graph.nodes.map { $0.id }, preset.nodes.map { $0.id })
        XCTAssertEqual(model.graph.nodes.map { type(of: $0).typeIdentifier },
                       ["tnf.gain", "tnf.reverb", "tnf.eq"])
        XCTAssertEqual(model.graph.outputGain, 0.75)
        let reverb = try XCTUnwrap(model.graph.nodes[1] as? ReverbNode)
        XCTAssertEqual(reverb.preset, .largeHall)
    }

    func test_parameter_edits_notify_observing_preset_surface_in_both_directions() throws {
        let model = fixture.makeModel()
        model.loadPreset(from: try fixture.write(fixture.preset()))
        var notifications = 0
        let observation = model.objectWillChange.sink { notifications += 1 }
        defer { observation.cancel() }
        let id = model.graph.nodes[0].id

        model.updateParameter(nodeID: id, paramID: "gain", value: -9)
        XCTAssertEqual(model.graph.nodes[0].parameterValue("gain"), -9)
        XCTAssertGreaterThan(notifications, 0, "The Modified surface observes the VM, not reference-type nodes")
        notifications = 0
        model.updateParameter(nodeID: id, paramID: "gain", value: -6)
        XCTAssertEqual(model.graph.nodes[0].parameterValue("gain"), -6)
        XCTAssertGreaterThan(notifications, 0, "Returning to baseline must also refresh the surface")
    }

    func test_failed_loads_leave_previous_graph_untouched() throws {
        let model = fixture.makeModel()
        model.loadPreset(from: try fixture.write(fixture.preset()))
        let graph = model.graph
        let snapshot = graph.snapshot()
        let corrupt = fixture.url("corrupt.tnf")
        try Data("not JSON".utf8).write(to: corrupt)
        let future = try fixture.write(
            GraphPreset(formatVersion: 999, name: "Future", outputGain: 1, nodes: []),
            filename: "future.tnf"
        )

        for url in [fixture.url("missing.tnf"), corrupt, future] {
            model.clearError()
            model.loadPreset(from: url)
            XCTAssertNotNil(model.lastError, url.lastPathComponent)
            XCTAssertTrue(model.graph === graph)
            XCTAssertEqual(model.graph.snapshot(), snapshot)
        }
    }

    func test_explicit_save_preserves_schema_and_legacy_reverb_preset() throws {
        let model = fixture.makeModel()
        model.loadPreset(from: try fixture.write(fixture.preset(legacyReverb: true)))
        let expected = model.graph.snapshot(name: "My Mix.v2")
        let target = fixture.url("My Mix.v2.tnf")

        model.savePreset(to: target)

        XCTAssertNil(model.lastError)
        XCTAssertEqual(try PresetStore.load(from: target), expected)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), Set(["formatVersion", "name", "outputGain", "nodes"]))
        XCTAssertEqual(expected.nodes[1].extras["preset"], .string("largeHall"))
    }

    func test_known_url_save_updates_bytes_and_failed_write_preserves_graph_and_prior_file() throws {
        let model = fixture.makeModel()
        let original = try fixture.write(fixture.preset())
        model.loadPreset(from: original)
        model.updateParameter(nodeID: model.graph.nodes[0].id, paramID: "gain", value: -9)
        let expected = model.graph.snapshot(name: original.deletingPathExtension().lastPathComponent)

        model.savePreset(to: original)
        XCTAssertEqual(try PresetStore.load(from: original), expected)
        let savedBytes = try Data(contentsOf: original)
        let graph = model.graph
        // A directory at the target path is a deterministic write rejection,
        // unlike permission bits, which can behave differently under CI users.
        let directoryTarget = try fixture.makeDirectoryTarget()
        model.savePreset(to: directoryTarget)

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.graph === graph)
        XCTAssertEqual(model.graph.snapshot(name: expected.name), expected)
        XCTAssertEqual(try Data(contentsOf: original), savedBytes)
    }

    func test_partial_load_recovers_known_nodes_without_failure_or_file_write() throws {
        let model = fixture.makeModel()
        let url = try fixture.write(fixture.partialPreset())
        let originalBytes = try Data(contentsOf: url)

        model.loadPreset(from: url)

        XCTAssertNil(model.lastError, "Recovery is a nonblocking warning, not outright load failure")
        XCTAssertEqual(model.graph.nodes.count, 1)
        XCTAssertEqual(model.graph.nodes.first?.parameterValue("gain"), -6)
        XCTAssertEqual(model.graph.lastLoadWarnings.count, 2)
        XCTAssertTrue(model.graph.lastLoadWarnings.contains(.unknownEffect(typeIdentifier: "future.effect")))
        XCTAssertTrue(model.graph.lastLoadWarnings.contains {
            if case .nodeRestoreFailed(typeIdentifier: "tnf.reverb", reason: _) = $0 { return true }
            return false
        })
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func test_failed_load_after_recovery_preserves_graph_and_recovery_warnings() throws {
        let model = fixture.makeModel()
        model.loadPreset(from: try fixture.write(fixture.partialPreset()))
        let graph = model.graph
        let warnings = graph.lastLoadWarnings

        model.loadPreset(from: fixture.url("missing.tnf"))

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.graph === graph)
        XCTAssertEqual(model.graph.lastLoadWarnings, warnings)
    }
}

/// Fresh defaults and temporary fixture files only. No test calls powerOn,
/// starts the mock controller, opens panels, or attaches an engine to hardware.
@MainActor
final class PresetContinuityFixture {
    let suiteName = "tnf.tests.preset-continuity.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-preset-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: directory)
    }

    func makeModel() -> AppViewModel {
        AppViewModel(
            capture: MockCaptureController(),
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
    }

    func url(_ filename: String) -> URL { directory.appendingPathComponent(filename) }

    func write(_ preset: GraphPreset, filename: String = "Studio Mix.tnf") throws -> URL {
        let target = url(filename)
        try PresetStore.save(preset, to: target)
        return target
    }

    func makeDirectoryTarget() throws -> URL {
        let target = url("cannot-overwrite-directory.tnf")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        return target
    }

    func preset(legacyReverb: Bool = false) -> GraphPreset {
        GraphPreset(name: "Internal snapshot title", outputGain: 0.75, nodes: [
            state("tnf.gain", parameters: ["gain": -6]),
            state("tnf.reverb", wetDryMix: 0.7, extras: [
                "preset": legacyReverb ? .int(AVAudioUnitReverbPreset.largeHall.rawValue) : .string("largeHall"),
            ]),
            state("tnf.eq", parameters: [
                "hp.frequency": 80, "hp.Q": 0.707, "lp.frequency": 800, "lp.Q": 1.2,
            ]),
        ])
    }

    func partialPreset() -> GraphPreset {
        GraphPreset(name: "Original full chain", outputGain: 0.75, nodes: [
            state("tnf.gain", parameters: ["gain": -6]),
            state("future.effect"),
            state("tnf.reverb", extras: ["preset": .string("not-a-known-reverb")]),
        ])
    }

    private func state(
        _ type: String,
        wetDryMix: Float = 1,
        parameters: [String: Float] = [:],
        extras: [String: AnyCodableValue] = [:]
    ) -> EffectState {
        EffectState(typeIdentifier: type, id: UUID(), displayName: type, bypass: false,
                    wetDryMix: wetDryMix, parameters: parameters, extras: extras)
    }
}

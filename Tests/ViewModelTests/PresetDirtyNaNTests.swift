import AVFoundation
import Effects
import Foundation
import Graph
import Presets
@testable import ViewModel
import XCTest

/// Synthetic diagnostic-state witnesses, NOT native EQ NaN reproduction.
/// All file/session inputs are finite; only the private fake's readback changes.
@MainActor
final class PresetDirtyNaNTests: XCTestCase {
    func test_finite_import_retains_actual_NaN_baseline_and_repeated_reads_are_clean() throws {
        try withLoaded(mode: "floatNaN", count: 2) { model, nodes, _, _ in
            let actual = model.graph.snapshot()
            for state in actual.nodes {
                let q = try XCTUnwrap(state.parameters["hp.Q"])
                XCTAssertTrue(q.isNaN)
                XCTAssertEqual(q.bitPattern, DirtyNaNNode.floatBits)
                XCTAssertEqual(state.parameters["hp.frequency"], 80)
                XCTAssertEqual(state.parameters["lp.frequency"], 800)
            }
            // Measure deltas only after setup/diagnostic snapshots. No extra
            // snapshots between these counters and the dirty getter.
            for _ in 0..<3 {
                let before = nodes.map { $0.snapshotCount }
                XCTAssertFalse(model.isPresetModified, "Identical retained quiet-NaN bits are unchanged")
                XCTAssertEqual(zip(nodes, before).map { $0.0.snapshotCount - $0.1 }, [1, 1])
            }
        }
    }

    func test_Float_NaN_baseline_distinguishes_finite_payload_and_sign_then_reverts() throws {
        try withLoaded(mode: "floatNaN") { model, nodes, _, _ in
            let node = nodes[0]
            for value in [Float(1), Float(bitPattern: 0x7fc0_0043), Float(bitPattern: 0xffc0_0042)] {
                assertChange(model, label: "Float bits \(value.bitPattern)", change: {
                    node.qReadback = value
                }, undo: {
                    node.qReadback = Float(bitPattern: DirtyNaNNode.floatBits)
                })
            }
        }
    }

    func test_separate_finite_baseline_becomes_dirty_for_Float_NaN() throws {
        try withLoaded(mode: "finite") { model, nodes, _, _ in
            let node = nodes[0]
            XCTAssertEqual(node.parameterValue("hp.Q"), 1)
            assertChange(model, label: "finite to NaN", change: {
                node.qReadback = Float(bitPattern: DirtyNaNNode.floatBits)
            }, undo: {
                node.qReadback = nil
            })
        }
    }

    func test_matching_NaN_does_not_hide_other_node_fields_or_dictionary_edits() throws {
        try withLoaded(mode: "floatNaN") { model, nodes, input, _ in
            let node = nodes[0]
            let edits: [(String, () -> Void)] = [
                ("finite parameter", { node.values["lp.Q"] = 2 }),
                ("bypass", { node.bypass.toggle() }),
                ("wet/dry", { node.wetDryMix = 0.25 }),
                ("UUID", { node.id = UUID() }),
                ("display name", { node.displayName = "Renamed" }),
                ("reported type", { node.snapshotType = "fixture.other" }),
                ("parameter addition", { node.values["future.parameter"] = 3 }),
                ("parameter removal", { node.values.removeValue(forKey: "lp.Q") }),
                ("extra addition", { node.extraValues["future.extra"] = .bool(true) }),
                ("extra removal", { node.extraValues.removeValue(forKey: "label") }),
                ("extra string value", { node.extraValues["label"] = .string("changed") }),
                ("extra int value", { node.extraValues["number"] = .int(2) }),
                ("extra bool value", { node.extraValues["enabled"] = .bool(false) }),
                ("extra Double value", { node.extraValues["diagnostic"] = .double(2.5) }),
                ("extra case int/Double", { node.extraValues["number"] = .double(1) }),
                ("extra case int/bool", { node.extraValues["number"] = .bool(true) }),
                ("extra case int/string", { node.extraValues["number"] = .string("1") }),
            ]
            for (label, edit) in edits {
                assertChange(model, label: label, change: edit, undo: { node.restore(from: input.nodes[0]) })
            }
        }
    }

    func test_matching_NaN_does_not_hide_order_membership_or_output_gain() throws {
        try withLoaded(mode: "floatNaN", count: 2) { model, nodes, _, _ in
            XCTAssertNotEqual(nodes[0].id, nodes[1].id)
            XCTAssertFalse(model.isPresetModified)
            try model.graph.move(from: 0, to: 2)
            XCTAssertTrue(model.isPresetModified, "Ordered identities matter")
            try model.graph.move(from: 1, to: 0)
            XCTAssertFalse(model.isPresetModified)
            try model.graph.remove(at: 1)
            XCTAssertTrue(model.isPresetModified, "Node membership matters")
            try model.graph.add(nodes[1])
            XCTAssertFalse(model.isPresetModified)
            assertChange(model, label: "output gain", change: {
                model.graph.outputGain = 0.5
            }, undo: {
                model.graph.outputGain = 0.75
            })
        }
    }

    func test_Double_extra_NaN_uses_exact_bits_and_preserves_cases_keys_and_values() throws {
        try withLoaded(mode: "doubleNaN") { model, nodes, _, _ in
            let node = nodes[0]
            let state = node.snapshot()
            guard case .double(let actual)? = state.extras["diagnostic"] else {
                return XCTFail("Synthetic readback must be a Double")
            }
            XCTAssertTrue(actual.isNaN)
            XCTAssertEqual(actual.bitPattern, DirtyNaNNode.doubleBits)
            XCTAssertFalse(model.isPresetModified)
            XCTAssertFalse(model.isPresetModified)
            let alternatives: [AnyCodableValue] = [
                .double(1.25), .double(Double(bitPattern: 0x7ff8_0000_0000_0043)),
                .double(Double(bitPattern: 0xfff8_0000_0000_0042)),
                .int(1), .bool(true), .string("NaN"),
            ]
            for value in alternatives {
                assertChange(model, label: "Double extra replacement \(value)", change: {
                    node.diagnosticReadback = value
                }, undo: {
                    node.diagnosticReadback = .double(Double(bitPattern: DirtyNaNNode.doubleBits))
                })
            }
            assertChange(model, label: "Double key removal", change: {
                node.diagnosticReadback = nil
                node.extraValues.removeValue(forKey: "diagnostic")
            }, undo: {
                node.extraValues["diagnostic"] = .double(1.25)
                node.diagnosticReadback = .double(Double(bitPattern: DirtyNaNNode.doubleBits))
            })
            assertChange(model, label: "Double key addition", change: {
                node.extraValues["newDouble"] = .double(2.5)
            }, undo: {
                node.extraValues.removeValue(forKey: "newDouble")
            })
        }
        try withLoaded(mode: "finite") { model, nodes, _, _ in
            assertChange(model, label: "finite Double to NaN", change: {
                nodes[0].diagnosticReadback = .double(Double(bitPattern: DirtyNaNNode.doubleBits))
            }, undo: {
                nodes[0].diagnosticReadback = nil
            })
        }
    }

    func test_infinity_and_signed_zero_keep_existing_scalar_equality_without_nonfinite_JSON() throws {
        try withLoaded(mode: "infinity") { model, nodes, _, _ in
            let node = nodes[0]
            XCTAssertEqual(node.parameterValue("hp.Q"), .infinity)
            XCTAssertEqual(node.snapshot().extras["diagnostic"], .double(.infinity))
            XCTAssertFalse(model.isPresetModified)
            assertChange(model, label: "Float infinity sign", change: {
                node.qReadback = -.infinity
            }, undo: { node.qReadback = .infinity })
            assertChange(model, label: "Double infinity sign", change: {
                node.diagnosticReadback = .double(-.infinity)
            }, undo: { node.diagnosticReadback = .double(.infinity) })
        }
        try withLoaded(mode: "zero") { model, nodes, _, _ in
            let node = nodes[0]
            XCTAssertEqual(try XCTUnwrap(node.parameterValue("hp.Q")).bitPattern, Float(-0.0).bitPattern)
            guard case .double(let zero)? = node.snapshot().extras["diagnostic"] else {
                return XCTFail("Expected Double negative zero")
            }
            XCTAssertEqual(zero.bitPattern, Double(-0.0).bitPattern)
            XCTAssertFalse(model.isPresetModified)
            node.qReadback = 0.0
            node.diagnosticReadback = .double(0.0)
            XCTAssertFalse(model.isPresetModified, "Signed zeros keep == semantics")
            assertChange(model, label: "zero to nonzero Float", change: {
                node.qReadback = 1
            }, undo: { node.qReadback = -0.0 })
            assertChange(model, label: "zero to nonzero Double", change: {
                node.diagnosticReadback = .double(1)
            }, undo: { node.diagnosticReadback = .double(-0.0) })
        }
    }

    private func assertChange(
        _ model: AppViewModel, label: String, change: () -> Void, undo: () -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(model.isPresetModified, "Clean before \(label)", file: file, line: line)
        change()
        XCTAssertTrue(model.isPresetModified, "Dirty after \(label)", file: file, line: line)
        undo()
        XCTAssertFalse(model.isPresetModified, "Clean after reverting \(label)", file: file, line: line)
    }

    /// Each invocation owns its registry/defaults/files, including finite-baseline
    /// controls. A finite session seed prevents native-EQ factory fallback.
    private func withLoaded(
        mode: String, count: Int = 1,
        body: (AppViewModel, [DirtyNaNNode], GraphPreset, URL) throws -> Void
    ) throws {
        let suite = "PresetDirtyNaNTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let input = GraphPreset(name: "Input title differs from snapshot", outputGain: 0.75, nodes: (0..<count).map {
            EffectState(typeIdentifier: "tnf.eq", id: UUID(), displayName: "Fake \($0)", bypass: false,
                        wetDryMix: 0.75,
                        parameters: ["hp.frequency": 80, "hp.Q": 1, "lp.frequency": 800, "lp.Q": 1.5],
                        extras: ["fixture.mode": .string(mode), "diagnostic": .double(1.25),
                                 "label": .string("original"), "number": .int(1), "enabled": .bool(true)])
        })
        for state in input.nodes {
            XCTAssertEqual(Set(state.parameters.keys), Set(EQNode.parameterCatalog.map { $0.identifier }))
            for parameter in EQNode.parameterCatalog {
                let value = try XCTUnwrap(state.parameters[parameter.identifier])
                XCTAssertTrue(value.isFinite && parameter.range.contains(value))
            }
        }
        let url = directory.appendingPathComponent("Finite Import.tnf")
        try PresetStore.save(input, to: url)
        let bytes = try Data(contentsOf: url)
        _ = try JSONSerialization.jsonObject(with: bytes)
        let decoded = try PresetStore.loadResult(from: url)
        XCTAssertTrue(decoded.diagnostics.isEmpty)
        XCTAssertEqual(decoded.preset, input)
        defaults.set(try JSONEncoder().encode(input), forKey: AppViewModelDefaultsKey.graph)
        let registry = EffectNodeRegistry()
        registry.register(DirtyNaNNode.self)
        let capture = MockCaptureController()
        let engine = AVAudioEngine()
        let model = AppViewModel(capture: capture, engine: engine, registry: registry, defaults: defaults)
        defer {
            XCTAssertTrue(capture.startCalls.isEmpty)
            XCTAssertFalse(engine.isRunning)
            XCTAssertEqual(try? Data(contentsOf: url), bytes, "Import never changes original finite bytes")
        }
        model.loadPreset(from: url)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.graph.lastLoadWarnings.isEmpty)
        XCTAssertTrue(model.presetWarnings.isEmpty)
        XCTAssertNil(model.presetRecoveryNotice)
        XCTAssertEqual(model.presetOrigin, .file)
        XCTAssertEqual(model.presetFileURL, url)
        XCTAssertEqual(model.graph.nodes.map { $0.id }, input.nodes.map { $0.id })
        let nodes = try model.graph.nodes.map { try XCTUnwrap($0 as? DirtyNaNNode) }
        XCTAssertEqual(nodes.count, count)
        defer { for node in nodes { XCTAssertEqual(node.attachmentAttempts, 0) } }
        try body(model, nodes, input, url)
    }
}

/// No shared mutable factory flags, native EQ instance, or comparator algorithm.
/// Finite imported values are stored separately from synthetic scalar readback.
private final class DirtyNaNNode: DefaultConstructibleEffectNode {
    static let typeIdentifier = "tnf.eq"
    static let floatBits: UInt32 = 0x7fc0_0042
    static let doubleBits: UInt64 = 0x7ff8_0000_0000_0042
    var id = UUID()
    var displayName = "Synthetic diagnostic fixture"
    var bypass = false
    var wetDryMix: Float = 1
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    var parameters: [EffectParameter] { EQNode.parameterCatalog }
    var values: [String: Float] = [:]
    var extraValues: [String: AnyCodableValue] = [:]
    var qReadback: Float?
    var diagnosticReadback: AnyCodableValue?
    var snapshotType = DirtyNaNNode.typeIdentifier
    private(set) var snapshotCount = 0
    private(set) var attachmentAttempts = 0

    required init() {}

    required convenience init(from decoder: Decoder) throws {
        self.init()
        restore(from: try EffectState(from: decoder))
    }

    func restore(from state: EffectState) {
        id = state.id
        displayName = state.displayName
        bypass = state.bypass
        wetDryMix = state.wetDryMix
        snapshotType = state.typeIdentifier
        values = state.parameters
        extraValues = state.extras
        qReadback = nil
        diagnosticReadback = nil
        switch state.extras["fixture.mode"] {
        case .string("floatNaN")?: qReadback = Float(bitPattern: Self.floatBits)
        case .string("doubleNaN")?: diagnosticReadback = .double(Double(bitPattern: Self.doubleBits))
        case .string("infinity")?:
            qReadback = .infinity
            diagnosticReadback = .double(.infinity)
        case .string("zero")?:
            qReadback = -0.0
            diagnosticReadback = .double(-0.0)
        default: break
        }
    }

    func setParameter(_ identifier: String, value: Float) throws {
        guard let parameter = parameters.first(where: { $0.identifier == identifier }) else {
            throw EffectParameterError.unknownParameter(identifier: identifier)
        }
        guard value.isFinite, parameter.range.contains(value) else {
            throw EffectParameterError.valueOutOfRange(identifier: identifier, value: value, range: parameter.range)
        }
        values[identifier] = value
        if identifier == "hp.Q" { qReadback = nil }
    }

    func parameterValue(_ identifier: String) -> Float? {
        if identifier == "hp.Q", let qReadback { return qReadback }
        return values[identifier]
    }

    func snapshot() -> EffectState {
        snapshotCount += 1
        // Fresh allocations on EVERY call: no stored NaN dictionary identity
        // can shortcut the equality being exercised by AppViewModel.
        var freshParameters: [String: Float] = [:]
        for (key, value) in values { freshParameters[key] = value }
        if let qReadback { freshParameters["hp.Q"] = qReadback }
        var freshExtras: [String: AnyCodableValue] = [:]
        for (key, value) in extraValues { freshExtras[key] = value }
        if let diagnosticReadback { freshExtras["diagnostic"] = diagnosticReadback }
        return EffectState(typeIdentifier: snapshotType, id: id, displayName: displayName,
                           bypass: bypass, wetDryMix: wetDryMix, parameters: freshParameters, extras: freshExtras)
    }

    func attach(to engine: AVAudioEngine) throws {
        attachmentAttempts += 1
        XCTFail("Diagnostic fake must never attach")
        throw DirtyNaNFixtureError.unexpectedAttachment
    }

    func detach() {}
}

private enum DirtyNaNFixtureError: Error { case unexpectedAttachment }

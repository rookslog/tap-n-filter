import AVFoundation
import Effects
import Foundation
import Graph
@testable import ViewModel
import XCTest

/// Exercises the existing slider/bypass APIs through a counting EffectNode witness.
/// No capture, graph attachment, or engine start is performed by these tests.
@MainActor
final class DiagnosticsRestraintTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "tnf.diagnostics-tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func test_wet_dry_updates_skip_expensive_snapshots_when_diagnostics_are_off() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: false)

        for value: Float in [-0.5, 0.4, 2] {
            model.updateWetDryMix(nodeID: node.id, value: value)
            XCTAssertEqual(node.wetDryMix, min(max(value, 0), 1))
        }

        XCTAssertEqual(node.diagnosticSnapshots.count, 0, "Filtering output alone still builds the message")
        XCTAssertFalse(model.debugLog.entries.contains { $0.message.contains("[EXP-031.wetDryMix.") })
        XCTAssertNil(model.lastError)
    }

    func test_wet_dry_updates_keep_before_and_after_evidence_when_diagnostics_are_on() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: true)

        model.updateWetDryMix(nodeID: node.id, value: 0.75)

        XCTAssertEqual(node.diagnosticSnapshots, ["bypass=false wetDryMix=0.25", "bypass=false wetDryMix=0.75"])
        assertEvidence(model, tag: "wetDryMix.before", state: "bypass=false wetDryMix=0.25")
        assertEvidence(model, tag: "wetDryMix.after", state: "bypass=false wetDryMix=0.75")
        XCTAssertEqual(node.wetDryMix, 0.75)
    }

    func test_bypass_skips_expensive_snapshots_when_diagnostics_are_off() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: false)

        model.setBypass(nodeID: node.id, bypass: true)

        XCTAssertTrue(node.bypass)
        XCTAssertTrue(node.diagnosticSnapshots.isEmpty)
        XCTAssertFalse(model.debugLog.entries.contains { $0.message.contains("[EXP-031.setBypass.") })
    }

    func test_bypass_keeps_before_and_after_evidence_when_diagnostics_are_on() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: true)

        model.setBypass(nodeID: node.id, bypass: true)

        XCTAssertEqual(node.diagnosticSnapshots, ["bypass=false wetDryMix=0.25", "bypass=true wetDryMix=0.25"])
        assertEvidence(model, tag: "setBypass.before", state: "bypass=false wetDryMix=0.25")
        assertEvidence(model, tag: "setBypass.after", state: "bypass=true wetDryMix=0.25")
        XCTAssertTrue(node.bypass)
    }

    func test_diagnostics_toggle_changes_evaluation_immediately_without_clearing_history() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: false)

        model.updateWetDryMix(nodeID: node.id, value: 0.5)
        XCTAssertTrue(node.diagnosticSnapshots.isEmpty)
        model.toggleDebugPanel()
        XCTAssertTrue(model.showDebugPanel)
        model.updateWetDryMix(nodeID: node.id, value: 0.75)
        XCTAssertEqual(node.diagnosticSnapshots.count, 2)
        let evidenceIDs = Set(model.debugLog.entries.filter { $0.message.contains("[EXP-031.") }.map(\.id))
        XCTAssertFalse(evidenceIDs.isEmpty)

        model.toggleDebugPanel()
        XCTAssertFalse(model.showDebugPanel)
        model.updateWetDryMix(nodeID: node.id, value: 1)
        model.setBypass(nodeID: node.id, bypass: true)

        XCTAssertEqual(node.diagnosticSnapshots.count, 2)
        XCTAssertTrue(evidenceIDs.isSubset(of: Set(model.debugLog.entries.map(\.id))))
        XCTAssertEqual(node.wetDryMix, 1)
        XCTAssertTrue(node.bypass)
    }

    func test_settings_and_diagnostics_actions_remain_independent_and_preserve_preference() throws {
        let (model, _) = try makeFixture(diagnosticsEnabled: false)
        XCTAssertFalse(model.showSettings)
        XCTAssertFalse(model.showDebugPanel)

        model.toggleSettings()
        XCTAssertTrue(model.showSettings)
        XCTAssertFalse(model.showDebugPanel)
        model.toggleDebugPanel()
        XCTAssertTrue(model.showSettings)
        XCTAssertTrue(model.showDebugPanel)
        XCTAssertTrue(defaults.bool(forKey: AppViewModelDefaultsKey.debugPanel))
        model.toggleSettings()
        XCTAssertFalse(model.showSettings)
        XCTAssertTrue(model.showDebugPanel)

        let restored = makeModel()
        XCTAssertTrue(restored.showDebugPanel)
        XCTAssertFalse(restored.showSettings, "Settings visibility remains session-only")
        restored.toggleDebugPanel()
        XCTAssertFalse(defaults.bool(forKey: AppViewModelDefaultsKey.debugPanel))
        XCTAssertFalse(makeModel().showDebugPanel)
    }

    func test_unknown_slider_and_bypass_targets_retain_warnings_when_diagnostics_are_off() throws {
        let (model, _) = try makeFixture(diagnosticsEnabled: false)
        let missingID = UUID()

        let actions: [() -> Void] = [
            { model.updateWetDryMix(nodeID: missingID, value: 0.5) },
            { model.setBypass(nodeID: missingID, bypass: true) },
            { model.updateParameter(nodeID: missingID, paramID: "missing", value: 0.5) },
        ]
        for action in actions {
            model.debugLog.clear()
            action()
            XCTAssertEqual(model.lastError, .parameter("Unknown node \(missingID)."))
            XCTAssertTrue(model.debugLog.entries.contains {
                $0.level == .warning && $0.message.lowercased().contains("unknown node")
            })
        }
    }

    func test_parameter_failure_retains_error_detail_with_diagnostics_off_and_on() throws {
        let (model, node) = try makeFixture(diagnosticsEnabled: false)

        for enabled in [false, true] {
            if model.showDebugPanel != enabled { model.toggleDebugPanel() }
            model.debugLog.clear()
            model.updateParameter(nodeID: node.id, paramID: "failing", value: 0.5)

            XCTAssertEqual(model.lastError, .parameter("diagnostic-test parameter failure"))
            XCTAssertTrue(model.debugLog.entries.contains {
                $0.level == .error && $0.message.contains("diagnostic-test parameter failure")
            })
            XCTAssertTrue(node.diagnosticSnapshots.isEmpty)
        }
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(
            capture: MockCaptureController(),
            engine: AVAudioEngine(),
            registry: EffectNodeRegistry(),
            defaults: defaults
        )
    }

    private func makeFixture(diagnosticsEnabled: Bool) throws -> (AppViewModel, DiagnosticSpyNode) {
        defaults.set(diagnosticsEnabled, forKey: AppViewModelDefaultsKey.debugPanel)
        let model = makeModel()
        let node = DiagnosticSpyNode()
        try model.graph.add(node)
        model.debugLog.clear()
        return (model, node)
    }

    private func assertEvidence(_ model: AppViewModel, tag: String, state: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.debugLog.entries.contains {
            $0.message.contains("[EXP-031.\(tag)]") && $0.message.contains(state)
        }, "Missing opt-in diagnostic evidence for \(tag)", file: file, line: line)
    }
}

/// The dynamic protocol witness counts actual diagnostic evaluation, even if a
/// logger later discards the resulting string. Mixers remain unattached.
private final class DiagnosticSpyNode: EffectNode {
    static let typeIdentifier = "tnf.diagnostic-spy"
    let id = UUID()
    var displayName = "Diagnostic spy"
    var bypass = false
    var wetDryMix: Float = 0.25
    var parameters: [EffectParameter] { [] }
    let inputBus = AVAudioMixerNode()
    let outputBus = AVAudioMixerNode()
    private(set) var diagnosticSnapshots: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        throw ProbeError.parameterFailure
    }

    func setParameter(_ identifier: String, value: Float) throws {
        throw ProbeError.parameterFailure
    }

    func attach(to engine: AVAudioEngine) throws {
        XCTFail("Diagnostic tests must not attach an audio graph")
    }

    func detach() {}

    func debugStateDescription() -> String {
        let state = "bypass=\(bypass) wetDryMix=\(wetDryMix)"
        diagnosticSnapshots.append(state)
        return state
    }

    func snapshot() -> EffectState {
        EffectState(typeIdentifier: Self.typeIdentifier, id: id, displayName: displayName,
                    bypass: bypass, wetDryMix: wetDryMix, parameters: [:], extras: [:])
    }

    func restore(from state: EffectState) throws {
        bypass = state.bypass
        wetDryMix = state.wetDryMix
    }

    private enum ProbeError: LocalizedError {
        case parameterFailure
        var errorDescription: String? { "diagnostic-test parameter failure" }
    }
}

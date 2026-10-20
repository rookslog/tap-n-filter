import AVFoundation
import Capture
import Effects
import Foundation
import Graph
@testable import ViewModel
import XCTest

/// Shared, existing-API fixture for removal baselines and the new undo contract.
/// No test calls powerOn or starts an engine; capture states are publisher-driven.
@MainActor
class RemovalTestCase: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "tnf.removal-tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func makeModel(
        types: [String] = ["tnf.eq", "tnf.gain", "tnf.reverb"],
        capture: MockCaptureController = MockCaptureController(),
        registry: EffectNodeRegistry = EffectNodeRegistry()
    ) throws -> AppViewModel {
        let states = try types.map { try registry.makeNode(typeIdentifier: $0).snapshot() }
        let preset = GraphPreset(name: "removal-fixture", outputGain: 0.75, nodes: states)
        defaults.set(try JSONEncoder().encode(preset), forKey: AppViewModelDefaultsKey.graph)
        return makeRestoredModel(capture: capture, registry: registry)
    }

    func makeRestoredModel(
        capture: MockCaptureController = MockCaptureController(),
        registry: EffectNodeRegistry = EffectNodeRegistry()
    ) -> AppViewModel {
        AppViewModel(capture: capture, engine: AVAudioEngine(), registry: registry, defaults: defaults)
    }

    func persistGraphForNextSession(_ model: AppViewModel) throws {
        defaults.set(try JSONEncoder().encode(model.graph.snapshot()), forKey: AppViewModelDefaultsKey.graph)
    }

    func states(_ model: AppViewModel) -> [EffectState] {
        model.graph.nodes.map { $0.snapshot() }
    }

    func waitForState(_ expected: CaptureState, model: AppViewModel) async {
        for _ in 0 ..< 100 {
            if model.captureState == expected { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(model.captureState, expected, "Mock state was not delivered")
    }
}

/// Registry override to exercise reconstruction failure without changing Graph
/// or starting an engine. Normal EQ registration is restored before retry.
final class RejectingUndoEq: DefaultConstructibleEffectNode {
    static let typeIdentifier = EQNode.typeIdentifier
    private let node = EQNode()

    var id: UUID { node.id }
    var displayName: String {
        get { node.displayName }
        set { node.displayName = newValue }
    }
    var bypass: Bool {
        get { node.bypass }
        set { node.bypass = newValue }
    }
    var wetDryMix: Float {
        get { node.wetDryMix }
        set { node.wetDryMix = newValue }
    }
    var parameters: [EffectParameter] { node.parameters }
    var inputBus: AVAudioMixerNode { node.inputBus }
    var outputBus: AVAudioMixerNode { node.outputBus }

    init() {}

    func setParameter(_ identifier: String, value: Float) throws {
        try node.setParameter(identifier, value: value)
    }

    func attach(to engine: AVAudioEngine) throws { try node.attach(to: engine) }
    func detach() { node.detach() }
    func snapshot() -> EffectState { node.snapshot() }
    func restore(from state: EffectState) throws { throw RestoreFailure.rejected }

    private enum RestoreFailure: Error { case rejected }
}

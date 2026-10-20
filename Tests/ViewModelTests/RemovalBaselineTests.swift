import Effects
import Graph
@testable import ViewModel
import XCTest

/// Baselines for removal and indexed single-effect restoration through existing Graph APIs.
@MainActor
final class RemovalBaselineTests: RemovalTestCase {
    func test_remove_preserves_survivor_identity_order_state_and_output_gain() throws {
        let model = try makeModel()
        let before = states(model)

        model.removeEffect(at: 1)

        XCTAssertEqual(states(model), [before[0], before[2]])
        XCTAssertEqual(model.graph.outputGain, 0.75)
        XCTAssertNil(model.lastError)
    }

    func test_invalid_removal_leaves_graph_unchanged() throws {
        let model = try makeModel()
        let before = model.graph.snapshot()

        for index in [-1, model.graph.nodes.count] {
            model.clearError()
            model.removeEffect(at: index)
            XCTAssertEqual(model.graph.snapshot(), before)
            guard case .graph? = model.lastError else {
                XCTFail("Invalid removal must report a graph error")
                continue
            }
        }
    }

    func test_existing_graph_insertion_restores_one_effect_without_rolling_back_other_edits() throws {
        let model = try makeModel()
        let registry = EffectNodeRegistry()
        let removed = model.graph.nodes[0].snapshot()
        let survivor = model.graph.nodes[1]
        model.removeEffect(at: 0)
        model.updateParameter(nodeID: survivor.id, paramID: GainNode.gainParameterIdentifier, value: -9)
        let editedSurvivor = survivor.snapshot()

        let restored = try registry.makeNode(typeIdentifier: removed.typeIdentifier)
        try restored.restore(from: removed)
        try model.graph.add(restored, at: 0)

        XCTAssertEqual(model.graph.nodes[0].snapshot(), removed)
        XCTAssertEqual(model.graph.nodes[1].snapshot(), editedSurvivor)
        XCTAssertEqual(model.graph.nodes[1].parameterValue(GainNode.gainParameterIdentifier), -9)
        XCTAssertEqual(model.graph.outputGain, 0.75)
        XCTAssertNil(model.lastError)
    }
}

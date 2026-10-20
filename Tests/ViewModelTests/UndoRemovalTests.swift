import Capture
import Effects
import Graph
@testable import ViewModel
import XCTest

/// Stage A proposed view-model surface: canUndoRemoval, lastRemovedEffectName,
/// undoLastRemoval(). Missing members are structural red, not behavioral red.
@MainActor
final class UndoRemovalTests: RemovalTestCase {
    func test_undo_without_a_removal_is_unavailable_and_a_no_op() throws {
        let model = try makeModel()
        let before = model.graph.snapshot()

        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
        model.undoLastRemoval()

        XCTAssertEqual(model.graph.snapshot(), before)
        XCTAssertNil(model.lastError)
    }

    func test_undo_first_removal_restores_identity_state_and_index() throws {
        try assertRoundTrip(types: ["tnf.eq", "tnf.gain", "tnf.reverb"], index: 0)
    }

    func test_undo_middle_removal_restores_identity_state_and_index() throws {
        try assertRoundTrip(types: ["tnf.gain", "tnf.eq", "tnf.reverb"], index: 1)
    }

    func test_undo_last_removal_restores_identity_state_and_index() throws {
        try assertRoundTrip(types: ["tnf.gain", "tnf.reverb", "tnf.eq"], index: 2)
    }

    func test_undo_only_node_restores_identity_state_and_index() throws {
        try assertRoundTrip(types: ["tnf.eq"], index: 0)
    }

    func test_undo_preserves_reverb_type_specific_extras() throws {
        let model = try makeModel(types: ["tnf.reverb"])
        let node = try XCTUnwrap(model.graph.nodes[0] as? ReverbNode)
        node.preset = .cathedral
        node.displayName = "Long tail"
        model.setBypass(nodeID: node.id, bypass: true)
        model.updateWetDryMix(nodeID: node.id, value: 0.27)
        let before = states(model)

        model.removeEffect(at: 0)
        model.undoLastRemoval()

        XCTAssertEqual(states(model), before)
        XCTAssertFalse(model.canUndoRemoval)
    }

    func test_removed_effect_is_a_frozen_state_not_a_retained_mutable_node() throws {
        let model = try makeModel(types: ["tnf.eq"])
        let removedNode = model.graph.nodes[0]
        let before = states(model)
        model.removeEffect(at: 0)

        // An external reference must not alter the recovery snapshot.
        try removedNode.setParameter("hp.frequency", value: 950)
        removedNode.displayName = "Changed after removal"
        removedNode.bypass = true
        removedNode.wetDryMix = 0.11
        model.undoLastRemoval()

        XCTAssertEqual(states(model), before)
    }

    func test_failed_undo_reconstruction_keeps_record_and_allows_retry() throws {
        let registry = EffectNodeRegistry()
        let model = try makeModel(registry: registry)
        let before = states(model)
        model.removeEffect(at: 0)
        let afterRemoval = states(model)
        registry.register(RejectingUndoEq.self)

        model.undoLastRemoval()

        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(states(model), afterRemoval, "Failure must not insert a default or partial node")
        XCTAssertEqual(model.lastRemovedEffectName, before[0].displayName)

        registry.register(EQNode.self)
        model.clearError()
        XCTAssertTrue(model.canUndoRemoval, "An idle reconstruction failure must leave recovery retryable")
        model.undoLastRemoval()

        XCTAssertEqual(states(model), before)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
    }

    func test_undo_does_not_roll_back_survivor_parameter_mix_bypass_or_output_trim_edits() throws {
        let model = try makeModel()
        let removed = model.graph.nodes[1].snapshot()
        model.removeEffect(at: 1)
        let survivor = model.graph.nodes[0]
        model.updateParameter(nodeID: survivor.id, paramID: "hp.frequency", value: 240)
        model.setBypass(nodeID: survivor.id, bypass: true)
        model.updateWetDryMix(nodeID: survivor.id, value: 0.37)
        model.graph.outputGain = 0.42
        let editedSurvivors = states(model)

        XCTAssertTrue(model.canUndoRemoval)
        model.undoLastRemoval()

        XCTAssertEqual(states(model), [editedSurvivors[0], removed, editedSurvivors[1]])
        XCTAssertEqual(model.graph.outputGain, 0.42)
        XCTAssertNil(model.lastError)
    }

    func test_new_successful_remove_replaces_the_previous_one_level_record() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: 0)
        model.removeEffect(at: 1)

        XCTAssertEqual(model.lastRemovedEffectName, before[2].displayName)
        model.undoLastRemoval()
        XCTAssertEqual(states(model), [before[1], before[2]])
        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
        model.undoLastRemoval()
        XCTAssertEqual(states(model), [before[1], before[2]], "No second-level undo or duplicate insertion")
    }

    func test_failed_remove_does_not_create_a_record() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: -1)

        XCTAssertNotNil(model.lastError)
        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    func test_failed_remove_preserves_the_prior_valid_record() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: 1)
        model.removeEffect(at: model.graph.nodes.count)

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.canUndoRemoval)
        XCTAssertEqual(model.lastRemovedEffectName, before[1].displayName)
        model.clearError()
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    func test_successful_add_invalidates_stale_removal() throws {
        let model = try makeModel()
        model.removeEffect(at: 1)
        model.addEffect(of: "tnf.gain")
        XCTAssertNil(model.lastError)
        assertInvalidatedUndoDoesNotChangeGraph(model)
    }

    func test_successful_move_invalidates_stale_removal() throws {
        let model = try makeModel()
        model.removeEffect(at: 1)
        let orderBeforeMove = states(model)
        model.moveEffect(from: 0, to: 2)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(states(model), Array(orderBeforeMove.reversed()))
        assertInvalidatedUndoDoesNotChangeGraph(model)
    }

    func test_failed_add_does_not_consume_valid_removal() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: 1)
        model.addEffect(of: "tnf.unregistered-test-effect")

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.canUndoRemoval)
        model.clearError()
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    func test_failed_move_does_not_consume_valid_removal() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: 1)
        model.moveEffect(from: 0, to: 99)

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.canUndoRemoval)
        model.clearError()
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    func test_factory_preset_graph_replacement_invalidates_removal() throws {
        let model = try makeModel()
        model.removeEffect(at: 1)
        model.loadFactoryPreset(named: "dry")

        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.graph.nodes.isEmpty)
        assertInvalidatedUndoDoesNotChangeGraph(model)
    }

    func test_failed_preset_load_preserves_valid_removal_when_graph_was_not_replaced() throws {
        let model = try makeModel()
        let before = states(model)
        model.removeEffect(at: 1)
        model.loadFactoryPreset(named: "missing-test-preset")

        XCTAssertNotNil(model.lastError)
        XCTAssertTrue(model.canUndoRemoval)
        model.clearError()
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    func test_new_session_restores_graph_without_previous_session_removal() throws {
        let model = try makeModel()
        model.removeEffect(at: 1)
        XCTAssertTrue(model.canUndoRemoval)
        try persistGraphForNextSession(model)

        let restored = makeRestoredModel()

        XCTAssertEqual(states(restored), states(model))
        assertInvalidatedUndoDoesNotChangeGraph(restored)
    }

    func test_capture_transitions_disable_undo_without_consuming_the_record() async throws {
        let capture = MockCaptureController()
        let model = try makeModel(capture: capture)
        let before = states(model)
        model.removeEffect(at: 1)
        let afterRemoval = states(model)

        for transition in [CaptureState.starting, .stopping] {
            capture.simulateState(transition)
            await waitForState(transition, model: model)
            XCTAssertFalse(model.canUndoRemoval)
            XCTAssertEqual(model.lastRemovedEffectName, before[1].displayName)
            model.undoLastRemoval()
            XCTAssertEqual(states(model), afterRemoval)
        }

        capture.simulateState(.idle)
        await waitForState(.idle, model: model)
        XCTAssertTrue(model.canUndoRemoval)
        model.undoLastRemoval()
        XCTAssertEqual(states(model), before)
    }

    private func assertRoundTrip(types: [String], index: Int) throws {
        let model = try makeModel(types: types)
        let node = model.graph.nodes[index]
        node.displayName = "Custom filter"
        model.updateParameter(nodeID: node.id, paramID: "hp.frequency", value: 175)
        model.setBypass(nodeID: node.id, bypass: true)
        model.updateWetDryMix(nodeID: node.id, value: 0.23)
        let before = model.graph.snapshot()

        model.removeEffect(at: index)
        XCTAssertEqual(model.graph.nodes.count, types.count - 1)
        XCTAssertFalse(model.graph.nodes.contains { $0.id == node.id })
        XCTAssertTrue(model.canUndoRemoval)
        XCTAssertEqual(model.lastRemovedEffectName, "Custom filter")
        model.undoLastRemoval()

        XCTAssertEqual(model.graph.snapshot(), before, "UUID, type, parameters, mix, bypass and index must survive")
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
    }

    private func assertInvalidatedUndoDoesNotChangeGraph(_ model: AppViewModel) {
        let before = model.graph.snapshot()
        XCTAssertFalse(model.canUndoRemoval)
        XCTAssertNil(model.lastRemovedEffectName)
        model.undoLastRemoval()
        XCTAssertEqual(model.graph.snapshot(), before)
    }
}

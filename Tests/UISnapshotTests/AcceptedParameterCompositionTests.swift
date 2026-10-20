import Combine
import Foundation
import Presets
@testable import UI
@testable import ViewModel
import XCTest

/// Accepted-edit composition through the scoped VM queue/result seam.
/// ALL editors use the DEFAULT production factory. No scheduleDrag override.
@MainActor
final class AcceptedParameterCompositionTests: XCTestCase {
    private var fixture: AcceptedParameterFixture!
    private var scheduler: AcceptedParameterScheduler!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try AcceptedParameterFixture()
        scheduler = AcceptedParameterScheduler()
    }
    override func tearDown() async throws {
        try fixture.cleanUp()
        fixture = nil
        scheduler = nil
        try await super.tearDown()
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(capture: fixture.capture, engine: fixture.engine, registry: fixture.registry,
                     defaults: fixture.defaults, scheduleParameterEdit: scheduler.schedule)
    }

    func test_save_drains_latest_accepted_drag_and_obsolete_tick_cannot_drain_a_new_edit() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.4)
        editor.drag(to: 0.7)
        XCTAssertEqual(scheduler.count, 1, "Only the VM coalescer schedules native delivery")
        XCTAssertTrue(node.attempts.isEmpty)
        let obsolete = try scheduler.takeNext()

        model.savePreset(to: fixture.url("saved.tnf"))
        XCTAssertEqual(try fixture.exportedValue("saved.tnf"), 7)
        XCTAssertEqual(node.attempts, [7])
        XCTAssertFalse(model.isPresetModified)
        editor.drag(to: 0.9)
        obsolete()
        XCTAssertEqual(node.value, 7)
        XCTAssertEqual(node.attempts, [7])
        try scheduler.runNext()
        XCTAssertEqual(node.value, 9)
        XCTAssertTrue(model.isPresetModified)
        XCTAssertEqual(try fixture.exportedValue("saved.tnf"), 7)
        obsolete()
        XCTAssertEqual(node.attempts, [7, 9])
    }

    func test_unchanged_immediate_write_reconciles_the_editor_whose_pending_drag_it_supersedes() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        XCTAssertEqual(editor.value, 7)
        XCTAssertEqual(node.value, 2)

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 2)

        // Native 2→2 cannot produce a SwiftUI scalar onChange. Reconciliation
        // must arrive synchronously through the superseded session's result.
        XCTAssertEqual(node.value, 2)
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2")
        XCTAssertFalse(editor.isEditing)
        oldTick()
        model.savePreset(to: fixture.url("superseded-unchanged.tnf"))
        scheduler.runAll()
        XCTAssertEqual(try fixture.exportedValue("superseded-unchanged.tnf"), 2)
        XCTAssertEqual(node.attempts, [2])
        XCTAssertEqual(editor.value, 2)
    }

    func test_superseding_immediate_result_preserves_reentrantly_accepted_newer_drag() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.afterAttempt = { [weak node] _ in
            node?.afterAttempt = nil
            editor.drag(to: 0.9)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 2)

        XCTAssertEqual(node.value, 2)
        XCTAssertEqual(editor.value, 9)
        XCTAssertEqual(editor.text, "9")
        oldTick()
        XCTAssertEqual(node.attempts, [2])
        XCTAssertEqual(scheduler.count, 1)
        try scheduler.runNext()
        model.savePreset(to: fixture.url("newer-than-immediate.tnf"))
        XCTAssertEqual(try fixture.exportedValue("newer-than-immediate.tnf"), 9)
        XCTAssertEqual(node.attempts, [2, 9])
        XCTAssertEqual(editor.value, 9)
    }

    func test_rejected_immediate_write_keeps_pending_editor_intent_and_its_delivery() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.behavior = .rejected

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 2)

        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(node.value, 2)
        XCTAssertEqual(editor.value, 7)
        XCTAssertEqual(editor.text, "7")
        oldTick()
        XCTAssertEqual(node.attempts, [2])
        node.behavior = .exact
        scheduler.runAll()
        model.savePreset(to: fixture.url("rejected-immediate-pending.tnf"))
        XCTAssertEqual(try fixture.exportedValue("rejected-immediate-pending.tnf"), 7)
        XCTAssertEqual(node.attempts, [2, 7])
        XCTAssertEqual(editor.value, 7)
    }

    func test_vm_coalescing_finish_and_repeated_drag_deliver_each_latest_value_once() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.3)
        editor.drag(to: 0.5)
        XCTAssertTrue(node.attempts.isEmpty)
        try scheduler.runNext()
        XCTAssertEqual(node.attempts, [5])
        editor.drag(to: 0.7)
        editor.finishDragging()
        editor.finishDragging()
        XCTAssertEqual(node.attempts, [5, 7])
        editor.drag(to: 0.9)
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [5, 7, 9])
    }

    func test_explicit_return_and_reset_supersede_queued_drag_and_already_delivered_old_closures() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let old = try scheduler.takeNext()
        editor.beginEditing(locale: fixture.locale)
        editor.text = "4"
        XCTAssertTrue(editor.commit(locale: fixture.locale))
        XCTAssertEqual(node.value, 4)
        old()
        editor.drag(to: 0.8)
        editor.reset()
        scheduler.runAll()
        model.savePreset(to: fixture.url("reset.tnf"))
        XCTAssertEqual(try fixture.exportedValue("reset.tnf"), 2)
        XCTAssertEqual(node.attempts, [4, 2])
    }

    func test_begin_cancel_and_stop_do_not_discard_accepted_drag_or_submit_valid_draft() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        editor.cancel()
        model.savePreset(to: fixture.url("cancel.tnf"))
        XCTAssertEqual(try fixture.exportedValue("cancel.tnf"), 7)
        editor.drag(to: 0.8)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        editor.stop()
        model.savePreset(to: fixture.url("stop.tnf"))
        scheduler.runAll()
        XCTAssertEqual(try fixture.exportedValue("stop.tnf"), 8)
        XCTAssertEqual(node.attempts, [7, 8])
        XCTAssertFalse(editor.isEditing)
        editor.drag(to: 0.3)
        editor.finishDragging()
        scheduler.runAll()
        XCTAssertEqual(node.value, 8, "A retired control session cannot write again")
    }

    func test_save_ignores_unsubmitted_and_invalid_numeric_text_without_ending_the_draft() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        model.savePreset(to: fixture.url("unsubmitted.tnf"))
        XCTAssertEqual(try fixture.exportedValue("unsubmitted.tnf"), 2)
        XCTAssertEqual(editor.text, "9")
        XCTAssertTrue(editor.isEditing)
        editor.text = "not a number"
        XCTAssertFalse(editor.commit(locale: fixture.locale))
        let error = editor.errorMessage
        model.savePreset(to: fixture.url("invalid.tnf"))
        XCTAssertEqual(try fixture.exportedValue("invalid.tnf"), 2)
        XCTAssertTrue(node.attempts.isEmpty)
        XCTAssertEqual(editor.text, "not a number")
        XCTAssertEqual(editor.errorMessage, error)
        XCTAssertTrue(editor.isEditing)
    }

    func test_failed_disk_save_keeps_receipt_baseline_but_not_rollback_of_accepted_graph_edit() throws {
        let model = makeModel()
        let original = fixture.url("original.tnf")
        model.savePreset(to: original)
        let bytes = try Data(contentsOf: original)
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)

        model.savePreset(to: try fixture.rejectedDirectory())

        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(node.value, 7)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertEqual(model.presetName, "original")
        XCTAssertTrue(model.isPresetModified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [7])
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 2)
        XCTAssertFalse(model.isPresetModified, "Failed Save must not advance the baseline")
    }

    func test_same_uuid_replacement_invalidates_old_object_and_already_delivered_callback() throws {
        let model = makeModel()
        let replacementFile = fixture.url("replacement.tnf")
        model.savePreset(to: replacementFile)
        let oldNode = try fixture.node(in: model)
        let oldEditor = fixture.writer(oldNode, model).makeEditor()
        oldEditor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        let publication = model.$graph.dropFirst().sink { _ in
            // @Published sends before assignment. Only generation invalidation
            // BEFORE publishing replacement can make this old callback inert.
            oldTick()
        }
        defer { publication.cancel() }

        model.loadPreset(from: replacementFile)
        let replacement = try fixture.node(in: model)
        XCTAssertEqual(replacement.id, oldNode.id)
        XCTAssertNotEqual(ObjectIdentifier(replacement), ObjectIdentifier(oldNode))
        oldTick()
        oldEditor.finishDragging()
        oldEditor.drag(to: 0.9)
        oldEditor.stop()
        scheduler.runAll()
        model.savePreset(to: fixture.url("replacement-copy.tnf"))
        XCTAssertEqual(try fixture.exportedValue("replacement-copy.tnf"), 2)
        XCTAssertTrue(replacement.attempts.isEmpty)
        XCTAssertTrue(oldNode.attempts.isEmpty)
    }

    func test_failed_load_preserves_pending_current_edit_and_reorder_preserves_target_identity() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        model.loadPreset(from: fixture.url("missing.tnf"))
        XCTAssertNotNil(model.lastError)
        model.moveEffect(from: 0, to: 2)
        model.savePreset(to: fixture.url("reordered.tnf"))
        XCTAssertEqual(try fixture.exportedValue("reordered.tnf", at: 1), 7)
        XCTAssertEqual(node.attempts, [7])
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [7])
    }

    func test_removed_target_is_discarded_and_does_not_block_unrelated_save() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        model.removeEffect(at: 0)
        model.savePreset(to: fixture.url("remaining.tnf"))
        scheduler.runAll()
        editor.finishDragging()
        XCTAssertTrue(node.attempts.isEmpty)
        XCTAssertEqual(try fixture.exportedValue("remaining.tnf"), 2)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_unchanged_native_readback_reconciles_without_any_parent_on_change() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .unchanged
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        XCTAssertEqual(editor.value, 7)
        try scheduler.runNext()
        XCTAssertEqual(editor.value, 2, "Unchanged readback cannot produce a SwiftUI onChange")
        XCTAssertEqual(node.attempts, [7])
        model.savePreset(to: fixture.url("unchanged.tnf"))
        XCTAssertEqual(try fixture.exportedValue("unchanged.tnf"), 2)
        XCTAssertEqual(model.presetFileURL, fixture.url("unchanged.tnf"), "Nonthrowing alteration is not rejection")
    }

    func test_nil_application_readback_never_substitutes_default_for_accepted_value() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.readbackAvailable = false
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        try scheduler.runNext()
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 7)
        model.savePreset(to: fixture.url("nil-readback.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-readback.tnf"), 7)
        XCTAssertEqual(editor.value, 7)
    }

    func test_throwing_rejection_blocks_save_even_after_editor_disappears_until_new_edit_succeeds() throws {
        let model = makeModel()
        let original = fixture.url("original.tnf")
        model.savePreset(to: original)
        let node = try fixture.node(in: model)
        node.behavior = .rejected
        var editor: ParameterValueEditor? = fixture.writer(node, model).makeEditor()
        editor?.drag(to: 0.7)
        try scheduler.runNext()
        scheduler.runAll()
        XCTAssertEqual(scheduler.count, 0, "A rejected attempt must not create an automatic retry timer")
        XCTAssertEqual(node.attempts, [7])
        editor?.stop()
        editor = nil
        model.clearError()
        let blocked = fixture.url("blocked.tnf")
        model.savePreset(to: blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertEqual(node.attempts, [7], "No automatic retry on rejection")
        node.behavior = .exact
        let next = fixture.writer(node, model).makeEditor()
        next.drag(to: 0.8)
        model.savePreset(to: fixture.url("recovered.tnf"))
        XCTAssertEqual(try fixture.exportedValue("recovered.tnf"), 8)
        XCTAssertFalse(model.isPresetModified)
    }

    func test_save_flush_rejection_aborts_before_disk_or_receipt_changes_and_is_not_retried() throws {
        let model = makeModel()
        let original = fixture.url("before-rejection.tnf")
        model.savePreset(to: original)
        let bytes = try Data(contentsOf: original)
        let node = try fixture.node(in: model)
        node.behavior = .rejected
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let target = fixture.url("must-not-exist.tnf")

        model.savePreset(to: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(model.presetFileURL, original)
        XCTAssertEqual(model.presetName, "before-rejection")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(node.attempts, [7])
        XCTAssertEqual(editor.value, 2)
        XCTAssertFalse(model.isPresetModified)
        scheduler.runAll()
        model.savePreset(to: target)
        XCTAssertEqual(node.attempts, [7], "Attempted queue entries are consumed once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func test_rejected_target_removal_clears_only_its_save_block_and_stale_tick_stays_inert() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .rejected
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        oldTick()
        model.removeEffect(at: 0)
        model.savePreset(to: fixture.url("after-removal.tnf"))
        oldTick()
        XCTAssertEqual(try fixture.exportedValue("after-removal.tnf"), 2)
        XCTAssertEqual(node.attempts, [7])
        XCTAssertFalse(model.isPresetModified)
    }

    func test_ordinary_model_echo_prefers_accepted_pending_intent_before_delivery() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        // Exactly the entry point used by ParameterSlider's ordinary onChange.
        editor.receiveModelValue(node.value)
        XCTAssertEqual(editor.value, 7)
        model.savePreset(to: fixture.url("pending-echo.tnf"))
        XCTAssertEqual(try fixture.exportedValue("pending-echo.tnf"), 7)
    }

    func test_ordinary_default_fallback_echo_after_nil_readback_keeps_last_applied_value() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        XCTAssertEqual(node.value, 2)
        editor.drag(to: 0.4)
        editor.finishDragging()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 4)

        node.readbackAvailable = false
        editor.drag(to: 0.7)
        editor.finishDragging()
        XCTAssertEqual(node.value, 7)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 7)

        // EffectControlsView.currentValue changes the parent's initialValue
        // from 4 to the catalog default when optional readback becomes nil.
        let parentValue = node.parameterValue("amount") ?? node.parameters[0].defaultValue
        XCTAssertEqual(parentValue, 2)
        editor.receiveModelValue(parentValue)
        XCTAssertEqual(editor.value, 7, "Nil verification must not turn a fallback model event into actual data")

        model.savePreset(to: fixture.url("nil-adapter.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-adapter.tnf"), 7)
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [4, 7], "Neither the fallback echo nor obsolete ticks may write the default")
    }

    func test_ordinary_external_readback_matching_old_own_echo_remains_authoritative() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.4)
        editor.finishDragging()
        // Deliver only the latest model echo, as SwiftUI may coalesce updates.
        editor.drag(to: 0.7)
        editor.finishDragging()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 7)

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)
        let actual = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(actual, 4)
        editor.receiveModelValue(actual)
        XCTAssertEqual(editor.value, 4, "A real external change must not be swallowed as an older own echo")

        model.savePreset(to: fixture.url("external-adapter.tnf"))
        XCTAssertEqual(try fixture.exportedValue("external-adapter.tnf"), 4)
        scheduler.runAll()
        XCTAssertEqual(node.value, 4)
        XCTAssertEqual(node.attempts, [4, 7, 4], "Model echoes and obsolete ticks must not replay accepted writes")
    }

    func test_normalized_A_result_and_delayed_echo_do_not_cancel_newer_B_then_save_exports_actual_B() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .roundedDown
        let editor = fixture.writer(node, model).makeEditor()
        node.afterAttempt = { [weak editor, weak node] _ in
            node?.afterAttempt = nil
            editor?.drag(to: 0.75)
        }
        editor.drag(to: 0.55)
        try scheduler.runNext()
        XCTAssertEqual(node.value, 5)
        XCTAssertEqual(editor.value, 7.5)
        editor.receiveModelValue(5)
        XCTAssertEqual(editor.value, 7.5)
        model.savePreset(to: fixture.url("normalized-B.tnf"))
        XCTAssertEqual(try fixture.exportedValue("normalized-B.tnf"), 7)
        XCTAssertEqual(editor.value, 7)
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [5.5, 7.5])
    }

    func test_result_and_normalized_echo_preserve_draft_validation_and_cancel_restores_actual() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .roundedDown
        let editor = fixture.writer(node, model).makeEditor()
        let locale = fixture.locale
        node.afterAttempt = { [weak editor, weak node] _ in
            node?.afterAttempt = nil
            editor?.beginEditing(locale: locale)
            editor?.text = "invalid draft"
            XCTAssertFalse(editor?.commit(locale: locale) ?? true)
        }
        editor.drag(to: 0.55)
        try scheduler.runNext()
        let error = try XCTUnwrap(editor.errorMessage)
        editor.receiveModelValue(5)
        XCTAssertEqual(editor.text, "invalid draft")
        XCTAssertTrue(editor.isEditing, "Model-level focus intent survives; actual AppKit focus is manual")
        XCTAssertEqual(editor.errorMessage, error)
        model.savePreset(to: fixture.url("draft.tnf"))
        XCTAssertEqual(try fixture.exportedValue("draft.tnf"), 5)
        XCTAssertEqual(editor.text, "invalid draft")
        editor.cancel()
        XCTAssertEqual(editor.value, 5)
        XCTAssertEqual(node.attempts, [5.5])
    }

    func test_result_after_numeric_draft_start_preserves_unsubmitted_text_until_cancel() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .roundedDown
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.55)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        try scheduler.runNext()
        editor.receiveModelValue(5)
        XCTAssertEqual(editor.text, "6")
        XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        model.savePreset(to: fixture.url("unsubmitted-result.tnf"))
        XCTAssertEqual(try fixture.exportedValue("unsubmitted-result.tnf"), 5)
        XCTAssertEqual(editor.text, "6")
        editor.cancel()
        XCTAssertEqual(editor.value, 5)
        XCTAssertEqual(node.attempts, [5.5])
    }

    func test_changed_external_readback_equal_to_optimistic_value_replaces_stale_draft_before_return_and_save() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.behavior = .roundedDown
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.55)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        try scheduler.runNext()
        XCTAssertEqual(node.value, 5)
        XCTAssertEqual(editor.value, 5.5)
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.text, "6", "Our normalized result must preserve the newer numeric draft")
        XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(node.attempts, [5.5])

        node.behavior = .exact
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 5.5)
        let actual = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(actual, 5.5)
        editor.receiveModelValue(actual)

        XCTAssertEqual(editor.value, 5.5)
        XCTAssertEqual(editor.text, "5.5", "Changed authoritative state must reconcile text, even at equal scalar")
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(node.attempts, [5.5, 5.5], "Ordinary model reconciliation must not echo a write")
        XCTAssertTrue(editor.commit(locale: fixture.locale))
        XCTAssertEqual(node.value, 5.5, "Return must not restore the stale draft 6")
        XCTAssertEqual(node.attempts, [5.5, 5.5, 5.5])
        model.savePreset(to: fixture.url("external-equal-optimistic.tnf"))
        XCTAssertEqual(try fixture.exportedValue("external-equal-optimistic.tnf"), 5.5)
        scheduler.runAll()
        XCTAssertEqual(node.value, 5.5)
        XCTAssertEqual(node.attempts, [5.5, 5.5, 5.5], "Save and obsolete ticks cannot replay the stale draft")
    }

    func test_nan_own_result_echo_is_acknowledged_without_destroying_newer_draft() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.readbackOverride = .nan
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.5)
        try scheduler.runNext()
        XCTAssertTrue(editor.value.isNaN)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.receiveModelValue(.nan)
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.text, "6")
        XCTAssertEqual(node.attempts, [5])
    }

    func test_default_factory_callbacks_do_not_strongly_retain_vm_or_editor() throws {
        var model: AppViewModel? = makeModel()
        let node = try fixture.node(in: XCTUnwrap(model))
        var editor: ParameterValueEditor? = fixture.writer(node, try XCTUnwrap(model)).makeEditor()
        weak var weakEditor = editor
        weak var weakModel = model
        editor?.drag(to: 0.7)
        editor = nil
        XCTAssertNil(weakEditor, "The handle's application handler must capture the editor weakly")
        model = nil
        XCTAssertNil(weakModel, "Handles and scheduled closures must not retain the VM")
        scheduler.runAll()
        XCTAssertTrue(node.attempts.isEmpty)
    }
}

/// Captures callbacks even after delivery so tests can replay obsolete work.
/// This deliberately provides no cancellation-based guarantee to production.
@MainActor
final class AcceptedParameterScheduler {
    private var actions: [() -> Void] = []
    var count: Int { actions.count }
    func schedule(_ action: @escaping () -> Void) { actions.append(action) }
    func takeNext() throws -> () -> Void {
        guard !actions.isEmpty else { throw AcceptedParameterSchedulerError.noScheduledCallback }
        return actions.removeFirst()
    }
    func runNext() throws { try takeNext()() }
    func runAll() {
        let delivered = actions
        actions.removeAll()
        for action in delivered { action() }
    }
}

enum AcceptedParameterSchedulerError: Error { case noScheduledCallback }

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
        XCTAssertEqual(editor.text, "2.0")
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
        XCTAssertEqual(editor.text, "9.0")
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
        XCTAssertEqual(editor.text, "7.0")
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

    func test_save_batch_immediate_supersession_reconciles_unattempted_editor_and_invalidates_all_old_ticks() throws {
        // Bug: detaching B from pending before A's setter hides B's session
        // from immediate supersession. Falsifier: Save reconciles B to 2 with
        // only a B=2 attempt, even when A replays B's old tick before writing.
        let model = makeModel()
        let nodeA = try fixture.node(in: model)
        let nodeB = try fixture.node(in: model, at: 1)
        let editorA = fixture.writer(nodeA, model).makeEditor()
        let editorB = fixture.writer(nodeB, model).makeEditor()
        editorA.drag(to: 0.4)
        editorB.drag(to: 0.7)
        XCTAssertEqual(scheduler.count, 2)
        let oldA = try scheduler.takeNext()
        let oldB = try scheduler.takeNext()
        XCTAssertEqual(nodeB.value, 2)
        XCTAssertEqual(editorB.value, 7)
        var callbacks = 0
        nodeA.afterAttempt = { [weak nodeA] _ in
            nodeA?.afterAttempt = nil
            callbacks += 1
            oldA()
            oldB()
            XCTAssertTrue(nodeB.attempts.isEmpty, "All batch tickets must be inert before the first setter")
            model.updateParameter(nodeID: nodeB.id, paramID: "amount", value: 2)
        }

        model.savePreset(to: fixture.url("batch-superseded-unchanged.tnf"))

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(nodeA.value, 4)
        XCTAssertEqual(editorA.value, 4)
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(try fixture.exportedValue("batch-superseded-unchanged.tnf"), 4)
        XCTAssertEqual(nodeB.value, 2)
        XCTAssertEqual(editorB.value, 2, "Native 2→2 cannot supply a scalar model echo")
        XCTAssertEqual(editorB.text, "2.0")
        XCTAssertFalse(editorB.isEditing)
        XCTAssertEqual(try fixture.exportedValue("batch-superseded-unchanged.tnf", at: 1), 2)
        XCTAssertEqual(nodeB.attempts, [2])
        XCTAssertFalse(model.isPresetModified)
        oldA()
        oldB()
        scheduler.runAll()
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(nodeB.attempts, [2])
        XCTAssertEqual(editorB.value, 2, "Obsolete ticks cannot be needed to repair the editor")
    }

    func test_save_batch_superseding_result_preserves_newer_drag_accepted_inside_immediate_setter() throws {
        // Bug guard: acknowledging superseded B=7 must not overwrite a newer
        // B=9 revision. Falsifier: B remains 9 after B=2 returns, then Save
        // applies and exports 9 exactly once without replaying B=7.
        let model = makeModel()
        let nodeA = try fixture.node(in: model)
        let nodeB = try fixture.node(in: model, at: 1)
        let editorA = fixture.writer(nodeA, model).makeEditor()
        let editorB = fixture.writer(nodeB, model).makeEditor()
        editorA.drag(to: 0.4)
        editorB.drag(to: 0.7)
        let oldA = try scheduler.takeNext()
        let oldB = try scheduler.takeNext()
        var callbacks = 0
        nodeB.afterAttempt = { [weak nodeB] requested in
            nodeB?.afterAttempt = nil
            XCTAssertEqual(requested, 2)
            editorB.drag(to: 0.9)
        }
        nodeA.afterAttempt = { [weak nodeA] _ in
            nodeA?.afterAttempt = nil
            callbacks += 1
            oldB()
            XCTAssertTrue(nodeB.attempts.isEmpty)
            model.updateParameter(nodeID: nodeB.id, paramID: "amount", value: 2)
            XCTAssertEqual(nodeB.value, 2)
            XCTAssertEqual(nodeB.attempts, [2])
            XCTAssertEqual(editorB.value, 9, "The older cancellation acknowledgement must preserve newer input")
            XCTAssertEqual(editorB.text, "9.0")
            oldA()
            oldB()
            XCTAssertEqual(nodeB.attempts, [2], "Old tickets cannot deliver the newly accepted B=9")
        }

        model.savePreset(to: fixture.url("batch-newer-than-immediate.tnf"))

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try fixture.exportedValue("batch-newer-than-immediate.tnf"), 4)
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(try fixture.exportedValue("batch-newer-than-immediate.tnf", at: 1), 9)
        XCTAssertEqual(nodeB.value, 9)
        XCTAssertEqual(editorB.value, 9)
        XCTAssertEqual(editorB.text, "9.0")
        XCTAssertEqual(nodeB.attempts, [2, 9])
        XCTAssertFalse(model.isPresetModified)
        oldA()
        oldB()
        scheduler.runAll()
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(nodeB.attempts, [2, 9])
        XCTAssertEqual(editorB.value, 9)
    }

    func test_save_batch_rejected_immediate_preserves_unattempted_drag_until_accepted_delivery_clears_block() throws {
        // Bug guard: rejected B=2 must preserve accepted B=7, whose later
        // successful application must clear the target's Save block. Falsifier:
        // B stays optimistic 7 through rejection, then Save applies/exports 7.
        let model = makeModel()
        let nodeA = try fixture.node(in: model)
        let nodeB = try fixture.node(in: model, at: 1)
        let editorA = fixture.writer(nodeA, model).makeEditor()
        let editorB = fixture.writer(nodeB, model).makeEditor()
        let target = fixture.url("batch-rejected-immediate.tnf")
        editorA.drag(to: 0.4)
        editorB.drag(to: 0.7)
        let oldA = try scheduler.takeNext()
        let oldB = try scheduler.takeNext()
        var callbacks = 0
        nodeA.afterAttempt = { [weak nodeA] _ in
            nodeA?.afterAttempt = nil
            callbacks += 1
            oldB()
            XCTAssertTrue(nodeB.attempts.isEmpty)
            nodeB.behavior = .rejected
            model.updateParameter(nodeID: nodeB.id, paramID: "amount", value: 2)
            XCTAssertNotNil(model.lastError)
            XCTAssertEqual(nodeB.value, 2)
            XCTAssertEqual(nodeB.attempts, [2])
            XCTAssertEqual(editorB.value, 7)
            XCTAssertEqual(editorB.text, "7.0")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            nodeB.behavior = .exact
            oldA()
            oldB()
            XCTAssertEqual(nodeB.attempts, [2], "The accepted B=7 belongs to Save, not an obsolete tick")
        }
        nodeB.afterAttempt = { [weak nodeB] requested in
            nodeB?.afterAttempt = nil
            XCTAssertEqual(requested, 7, "Only accepted B=7 can recover the rejected target")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }

        model.savePreset(to: target)

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try fixture.exportedValue("batch-rejected-immediate.tnf"), 4)
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(try fixture.exportedValue("batch-rejected-immediate.tnf", at: 1), 7)
        XCTAssertEqual(model.presetFileURL, target, "Accepted B=7 must clear the target's Save block")
        XCTAssertEqual(nodeB.value, 7)
        XCTAssertEqual(editorB.value, 7)
        XCTAssertEqual(editorB.text, "7.0")
        XCTAssertEqual(nodeB.attempts, [2, 7])
        XCTAssertFalse(model.isPresetModified)
        oldA()
        oldB()
        scheduler.runAll()
        model.savePreset(to: fixture.url("batch-rejected-immediate-copy.tnf"))
        XCTAssertEqual(try fixture.exportedValue("batch-rejected-immediate-copy.tnf", at: 1), 7)
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(nodeB.attempts, [2, 7], "Save must not retry the rejected immediate request")
    }

    func test_save_batch_supersession_preserves_newer_numeric_draft_without_submitting_it() throws {
        // Bug guard: the older B=7 acknowledgement cannot erase a numeric
        // draft opened inside B=2. Falsifier: Save exports actual 2 while
        // retaining text/focus intent; cancelling restores 2 without a write.
        let model = makeModel()
        let nodeA = try fixture.node(in: model)
        let nodeB = try fixture.node(in: model, at: 1)
        let editorA = fixture.writer(nodeA, model).makeEditor()
        let editorB = fixture.writer(nodeB, model).makeEditor()
        let locale = fixture.locale
        editorA.drag(to: 0.4)
        editorB.drag(to: 0.7)
        let oldA = try scheduler.takeNext()
        let oldB = try scheduler.takeNext()
        var callbacks = 0
        nodeB.afterAttempt = { [weak nodeB] requested in
            nodeB?.afterAttempt = nil
            XCTAssertEqual(requested, 2)
            editorB.beginEditing(locale: locale)
            editorB.text = "9"
        }
        nodeA.afterAttempt = { [weak nodeA] _ in
            nodeA?.afterAttempt = nil
            callbacks += 1
            oldB()
            XCTAssertTrue(nodeB.attempts.isEmpty)
            model.updateParameter(nodeID: nodeB.id, paramID: "amount", value: 2)
            XCTAssertTrue(editorB.isEditing)
            XCTAssertEqual(editorB.text, "9")
        }

        model.savePreset(to: fixture.url("batch-superseded-draft.tnf"))

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(try fixture.exportedValue("batch-superseded-draft.tnf"), 4)
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(try fixture.exportedValue("batch-superseded-draft.tnf", at: 1), 2)
        XCTAssertEqual(nodeB.value, 2)
        XCTAssertEqual(nodeB.attempts, [2])
        XCTAssertTrue(editorB.isEditing, "Model-level focus intent only; native focus remains manual")
        XCTAssertEqual(editorB.text, "9", "Save never parses an unsubmitted draft")
        XCTAssertNil(editorB.errorMessage)
        oldA()
        oldB()
        scheduler.runAll()
        XCTAssertTrue(editorB.isEditing)
        XCTAssertEqual(editorB.text, "9")
        editorB.cancel()
        XCTAssertFalse(editorB.isEditing)
        XCTAssertEqual(editorB.value, 2)
        XCTAssertEqual(editorB.text, "2.0")
        XCTAssertEqual(nodeA.attempts, [4])
        XCTAssertEqual(nodeB.attempts, [2])
    }

    func test_nil_direct_supersession_replaces_cancelled_drag_not_with_stale_authoritative_actual() throws {
        // Falsifier: accepted 4 replaces cancelled 7, not the last observed 2,
        // before any model event, tick or Save can repair presentation.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 2)
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 4)
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(node.attempts, [4])
        oldTick()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(node.attempts, [4])
        model.savePreset(to: fixture.url("nil-direct-four.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-direct-four.tnf"), 4)
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertEqual(node.attempts, [4])
    }

    func test_nil_old_to_old_direct_supersession_reconciles_cancelled_drag_without_scalar_echo() throws {
        // Falsifier: native 2→2 still acknowledges cancelled 7 as accepted 2.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 2)

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 2)
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        oldTick()
        XCTAssertEqual(node.attempts, [2])
        XCTAssertEqual(editor.value, 2)
        model.savePreset(to: fixture.url("nil-direct-old-to-old.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-direct-old-to-old.tnf"), 2)
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertEqual(node.attempts, [2])
    }

    func test_nil_direct_result_repairs_backing_value_beneath_reentrant_invalid_draft_without_clearing_error() throws {
        // Falsifier: backing/Cancel become 4 while exact invalid text, editing
        // intent and the setter-time validation error survive result and Save.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        let locale = fixture.locale
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var validationError: String?
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            node?.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            editor.beginEditing(locale: locale)
            editor.text = "invalid draft"
            XCTAssertFalse(editor.commit(locale: locale))
            validationError = editor.errorMessage
            XCTAssertNotNil(validationError)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let error = try XCTUnwrap(validationError)
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4, "Draft protection must not retain cancelled backing 7")
        XCTAssertEqual(editor.text, "invalid draft")
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.errorMessage, error)
        oldTick()
        model.savePreset(to: fixture.url("nil-direct-invalid-draft.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-direct-invalid-draft.tnf"), 4)
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "invalid draft")
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.errorMessage, error)
        XCTAssertEqual(node.attempts, [4], "Save must not submit invalid text")
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(node.attempts, [4], "Cancel is not another setter")
    }

    func test_nil_older_direct_acknowledgement_preserves_reentrant_newer_drag_and_old_tick_cannot_deliver_it() throws {
        // Falsifier: older request 4 cannot replace newer pending 9, and only
        // Save (not the cancelled 7 ticket) delivers 9 once.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            node?.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            editor.drag(to: 0.9)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 4)
        XCTAssertEqual(editor.value, 9)
        XCTAssertEqual(editor.text, "9.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(scheduler.count, 1)
        oldTick()
        XCTAssertEqual(node.attempts, [4], "Old ticket cannot deliver pending 9 early")
        XCTAssertEqual(node.value, 4)
        XCTAssertEqual(editor.value, 9)
        model.savePreset(to: fixture.url("nil-direct-newer-drag.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-direct-newer-drag.tnf"), 9)
        XCTAssertEqual(node.attempts, [4, 9])
        XCTAssertEqual(editor.value, 9)
        XCTAssertEqual(editor.text, "9.0")
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [4, 9])
    }

    func test_nil_later_serial_outer_direct_result_cannot_overwrite_newer_nested_commit_or_cancel_backing() throws {
        // Falsifier: inner commit 8 wins even though outer request 4 receives
        // its acknowledgement later, with a higher application serial.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        let locale = fixture.locale
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            node?.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            editor.beginEditing(locale: locale)
            editor.text = "8"
            XCTAssertTrue(editor.commit(locale: locale))
            XCTAssertEqual(editor.value, 8)
            XCTAssertEqual(editor.text, "8.0")
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 8)
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(node.attempts, [4, 8])
        editor.beginEditing(locale: locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertFalse(editor.isEditing)
        oldTick()
        model.savePreset(to: fixture.url("nil-direct-nested-commit.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-direct-nested-commit.tnf"), 8)
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(node.attempts, [4, 8])
    }

    func test_nil_unchanged_setter_clears_old_authoritative_actual_so_restored_equal_readback_reconciles_draft() throws {
        // Falsifier: accepted presentation 4 is not native 2; restoring real
        // readback 2 must reconcile even though 2 was previously observed.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        node.behavior = .unchanged
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(node.value, 2, "Successful unchanged setter need not match accepted presentation")
        model.savePreset(to: fixture.url("nil-unchanged-actual-two.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-unchanged-actual-two.tnf"), 2)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        node.readbackAvailable = true
        let actual = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(actual, 2)
        editor.receiveModelValue(actual)
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0", "Nil acknowledgement must clear, not preserve, old actual 2")
        XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [4], "Ordinary readback must not write or substitute a default")
    }

    func test_nil_applied_request_is_not_fabricated_authoritative_actual_when_matching_real_readback_returns() throws {
        // Falsifier: actual 4 must replace draft text even when it equals the
        // optimistic request; caching request as authoritative would hide it.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        XCTAssertTrue(editor.isEditing)
        node.readbackAvailable = true
        let actual = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(actual, 4)
        editor.receiveModelValue(actual)
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0", "Accepted request must not suppress later measured actual 4")
        XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        model.savePreset(to: fixture.url("nil-restored-actual-four.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-restored-actual-four.tnf"), 4)
        oldTick()
        scheduler.runAll()
        XCTAssertEqual(node.attempts, [4], "Real readback and Save cannot echo another setter")
    }

    func test_nil_nested_public_direct_success_reconciles_latest_success_before_any_model_echo() throws {
        // Unlike a nested editor commit, public direct writes do not advance
        // this editor's submission revision. The newest successful write wins.
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        XCTAssertEqual(node.value, 2)
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            guard let node else { return XCTFail("The live target must remain available") }
            node.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            model.updateParameter(nodeID: node.id, paramID: "amount", value: 8)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 8)
        XCTAssertEqual(editor.value, 8, "Outer request 4 cannot overwrite newer direct success 8")
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(node.attempts, [4, 8])
        oldTick()
        XCTAssertEqual(node.attempts, [4, 8])
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(node.attempts, [4, 8], "Cancel must not write draft 6")
        model.savePreset(to: fixture.url("nil-nested-public-success.tnf"))
        XCTAssertEqual(try fixture.exportedValue("nil-nested-public-success.tnf"), 8)
        XCTAssertEqual(model.presetFileURL, fixture.url("nil-nested-public-success.tnf"))
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertEqual(node.attempts, [4, 8])
    }

    func test_nil_rejected_nested_public_direct_preserves_outer_success_presentation_and_target_save_block() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        XCTAssertEqual(node.value, 2)
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            guard let node else { return XCTFail("The live target must remain available") }
            node.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            node.behavior = .rejected
            model.updateParameter(nodeID: node.id, paramID: "amount", value: 8)
            node.behavior = .exact
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(node.value, 4)
        XCTAssertEqual(editor.value, 4, "Rejected 8 is not a newer successful application")
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(node.attempts, [4, 8])
        oldTick()
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(node.attempts, [4, 8])
        let blocked = fixture.url("nil-nested-public-blocked.tnf")
        model.savePreset(to: blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertNotNil(model.lastError, "Outer success returning later cannot clear the nested target failure")
        XCTAssertNil(model.presetFileURL)
        scheduler.runAll()
        oldTick()
        model.savePreset(to: blocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(node.attempts, [4, 8], "Save and obsolete tickets must not retry rejection")

        editor.drag(to: 0.9)
        oldTick()
        XCTAssertEqual(node.attempts, [4, 8], "Old ticket cannot deliver newly accepted 9")
        let recovered = fixture.url("nil-nested-public-recovered.tnf")
        model.savePreset(to: recovered)
        XCTAssertEqual(try fixture.exportedValue("nil-nested-public-recovered.tnf"), 9)
        XCTAssertEqual(model.presetFileURL, recovered, "A genuinely newer success clears the target block")
        XCTAssertEqual(editor.value, 9)
        XCTAssertEqual(editor.text, "9.0")
        XCTAssertFalse(model.isPresetModified)
        scheduler.runAll()
        oldTick()
        XCTAssertEqual(node.attempts, [4, 8, 9])
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.path))
    }

    func test_nil_rejected_numeric_commit_restores_observed_presentation_and_cancel_without_retry() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 2)
        node.readbackAvailable = false
        node.behavior = .rejected
        editor.beginEditing(locale: fixture.locale)
        editor.text = "8"

        XCTAssertTrue(editor.commit(locale: fixture.locale), "Valid text submits even when application rejects")

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 2, "Previous observation is fallback presentation, not current measured actual")
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [8], name: "r6-rejected-commit.tnf")
    }

    func test_nil_rejected_reset_restores_observed_four_not_failed_catalog_default() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 4)
        node.readbackAvailable = false
        node.behavior = .rejected

        editor.reset()

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0", "Rejected default 2 is not successful presentation")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [4, 2], name: "r6-rejected-reset.tnf")
    }

    func test_nil_rejected_scheduled_drag_keeps_pending_eight_then_restores_observed_two() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        node.readbackAvailable = false
        editor.drag(to: 0.8)
        let tick = try scheduler.takeNext()
        XCTAssertEqual(editor.value, 8)
        XCTAssertEqual(editor.text, "8.0")
        XCTAssertTrue(node.attempts.isEmpty)
        editor.receiveModelValue(2)
        XCTAssertEqual(editor.value, 8, "Pending input remains visible until actually attempted")
        node.behavior = .rejected

        tick()

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        tick()
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [8], name: "r6-rejected-delivery.tnf")
        tick()
        XCTAssertEqual(node.attempts, [8])
    }

    func test_nil_rejection_restores_prior_successful_explicit_request_not_older_observation() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        XCTAssertEqual(editor.value, 2)
        node.readbackAvailable = false
        editor.beginEditing(locale: fixture.locale)
        editor.text = "4"
        XCTAssertTrue(editor.commit(locale: fixture.locale))
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        node.behavior = .rejected
        editor.beginEditing(locale: fixture.locale)
        editor.text = "8"

        XCTAssertTrue(editor.commit(locale: fixture.locale))

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [4, 8], name: "r6-success-before-rejection.tnf")
    }

    func test_nil_initial_factory_seed_survives_rejection_without_claiming_current_actual() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        node.readbackAvailable = false
        let editor = fixture.writer(node, model).makeEditor()
        XCTAssertEqual(editor.value, 2, "Catalog seed is presentation only; no native observation exists")
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertTrue(node.attempts.isEmpty)
        node.behavior = .rejected
        editor.beginEditing(locale: fixture.locale)
        editor.text = "8"

        XCTAssertTrue(editor.commit(locale: fixture.locale))

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 2, "Neither failed 8 nor an invented actual may replace seed presentation")
        XCTAssertEqual(editor.text, "2.0")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [8], name: "r6-seed-rejection.tnf")
    }

    func test_nil_factory_initial_pending_is_not_success_history_after_new_editor_rejection() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let existing = try XCTUnwrap(model.makeParameterEditHandle(node: node, parameterID: "amount"))
        node.readbackAvailable = false
        XCTAssertTrue(model.acceptParameterValue(7, for: existing, intentRevision: 1))
        let oldTick = try scheduler.takeNext()
        let editor = fixture.writer(node, model).makeEditor()
        XCTAssertEqual(editor.value, 7)
        XCTAssertEqual(editor.text, "7.0")
        XCTAssertTrue(node.attempts.isEmpty)
        node.behavior = .rejected
        editor.beginEditing(locale: fixture.locale)
        editor.text = "8"

        XCTAssertTrue(editor.commit(locale: fixture.locale))

        XCTAssertNil(model.pendingParameterValue(for: existing))
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 2, "Unattempted initial 7 is not fallback success; use catalog seed only")
        XCTAssertEqual(editor.text, "2.0")
        oldTick()
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 2)
        XCTAssertEqual(editor.text, "2.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [8], name: "r6-initial-pending-rejection.tnf")
        oldTick()
        XCTAssertEqual(node.attempts, [8], "Cancelled 7 must never be delivered or retried")
    }

    func test_nil_newer_pending_drag_survives_outer_success_then_rejection_restores_that_success() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        var callbacks = 0
        node.afterAttempt = { [weak node] requested in
            node?.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            editor.drag(to: 0.9)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(editor.value, 9)
        XCTAssertEqual(editor.text, "9.0")
        XCTAssertEqual(node.attempts, [4])
        XCTAssertEqual(scheduler.count, 1)
        oldTick()
        XCTAssertEqual(node.attempts, [4], "Cancelled 7 ticket cannot drain newer 9 early")
        let newerTick = try scheduler.takeNext()
        node.behavior = .rejected
        newerTick()
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4, "Successful outer 4 must be retained beneath pending 9")
        XCTAssertEqual(editor.text, "4.0")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "6"
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        oldTick()
        newerTick()
        assertR6RejectedSave(model, node: node, attempts: [4, 9], name: "r6-newer-drag-rejection.tnf")
        oldTick()
        newerTick()
        XCTAssertEqual(node.attempts, [4, 9])
    }

    func test_nil_late_outer_success_repairs_fallback_beneath_settled_newer_rejection_and_invalid_draft() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        editor.drag(to: 0.7)
        let oldTick = try scheduler.takeNext()
        node.readbackAvailable = false
        let locale = fixture.locale
        var callbacks = 0
        var validationError: String?
        node.afterAttempt = { [weak node] requested in
            guard let node else { return XCTFail("The live target must remain available") }
            node.afterAttempt = nil
            callbacks += 1
            XCTAssertEqual(requested, 4)
            node.behavior = .rejected
            editor.beginEditing(locale: locale)
            editor.text = "8"
            XCTAssertTrue(editor.commit(locale: locale))
            node.behavior = .exact
            editor.beginEditing(locale: locale)
            editor.text = "invalid newer draft"
            XCTAssertFalse(editor.commit(locale: locale))
            validationError = editor.errorMessage
            XCTAssertNotNil(validationError)
        }

        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)

        let error = try XCTUnwrap(validationError)
        XCTAssertEqual(callbacks, 1)
        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 4, "Late successful basis repairs backing even after newer submission settled")
        XCTAssertEqual(editor.text, "invalid newer draft")
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.errorMessage, error)
        oldTick()
        assertR6RejectedSave(model, node: node, attempts: [4, 8], name: "r6-late-success-draft.tnf")
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "invalid newer draft", "Save never submits this draft")
        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(editor.errorMessage, error)
        editor.cancel()
        XCTAssertEqual(editor.value, 4)
        XCTAssertEqual(editor.text, "4.0")
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        oldTick()
        XCTAssertEqual(node.attempts, [4, 8])
    }

    func test_nil_rejection_preserves_fresher_external_observation_over_unnotified_public_success() throws {
        let model = makeModel()
        let node = try fixture.node(in: model)
        let editor = fixture.writer(node, model).makeEditor()
        editor.receiveModelValue(try XCTUnwrap(node.parameterValue("amount")))
        // No pending session: this public success has no editor result callback.
        model.updateParameter(nodeID: node.id, paramID: "amount", value: 4)
        XCTAssertEqual(editor.value, 2)
        // Intentional external node update, not a simulated nil acknowledgement.
        try node.setParameter("amount", value: 6)
        let observed = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(observed, 6)
        editor.receiveModelValue(observed)
        XCTAssertEqual(editor.value, 6)
        XCTAssertEqual(editor.text, "6.0")
        node.readbackAvailable = false
        node.behavior = .rejected
        editor.beginEditing(locale: fixture.locale)
        editor.text = "8"

        XCTAssertTrue(editor.commit(locale: fixture.locale))

        XCTAssertNil(node.parameterValue("amount"))
        XCTAssertEqual(editor.value, 6, "Old successful 4 must not overwrite more recent native observation 6")
        XCTAssertEqual(editor.text, "6.0")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        editor.cancel()
        XCTAssertEqual(editor.value, 6)
        XCTAssertEqual(editor.text, "6.0")
        XCTAssertFalse(editor.isEditing)
        assertR6RejectedSave(model, node: node, attempts: [4, 6, 8], name: "r6-observation-watermark.tnf")
        editor.beginEditing(locale: fixture.locale)
        editor.text = "9"
        node.readbackAvailable = true
        let restoredActual = try XCTUnwrap(node.parameterValue("amount"))
        XCTAssertEqual(restoredActual, 6)
        editor.receiveModelValue(restoredActual)
        XCTAssertEqual(editor.value, 6)
        XCTAssertEqual(editor.text, "6.0", "Fallback 6 must not masquerade as current actual and suppress reconciliation")
        XCTAssertTrue(editor.isEditing)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(node.attempts, [4, 6, 8], "Restored actual must reconcile without a setter")
        assertR6RejectedSave(model, node: node, attempts: [4, 6, 8], name: "r6-watermark-still-blocked.tnf")
    }

    private func assertR6RejectedSave(
        _ model: AppViewModel, node: AcceptedParameterNode, attempts: [Float], name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let target = fixture.url(name)
        XCTAssertEqual(node.attempts, attempts, file: file, line: line)
        model.savePreset(to: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), file: file, line: line)
        XCTAssertNotNil(model.lastError, file: file, line: line)
        XCTAssertNil(model.presetFileURL, file: file, line: line)
        scheduler.runAll()
        XCTAssertEqual(scheduler.count, 0, "No automatic retry scheduled", file: file, line: line)
        model.clearError()
        model.savePreset(to: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), file: file, line: line)
        XCTAssertNotNil(model.lastError, "Clearing the banner cannot clear target failure", file: file, line: line)
        XCTAssertNil(model.presetFileURL, file: file, line: line)
        XCTAssertEqual(node.attempts, attempts, "Save/ticks must never retry a consumed rejection", file: file, line: line)
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

import Combine
import Effects
import Foundation
@testable import UI
import XCTest

/// Drive queued callbacks explicitly, including obsolete callbacks that a
/// cancellation-only implementation might still deliver. No sleeps or audio.
@MainActor
final class ParameterValueSchedulingTests: XCTestCase {

    func test_drag_tick_coalesces_to_the_latest_native_value() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.2)
        editor.drag(to: 0.4)
        editor.drag(to: 0.8)
        let latest = editor.value
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(queued.count, 1)

        queued[0]()

        XCTAssertEqual(writes, [latest])
    }

    func test_obsolete_drag_tick_cannot_overwrite_a_typed_commit_or_drain_a_new_drag() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.2)
        editor.beginEditing(locale: posix)
        editor.text = "1234.567"
        XCTAssertTrue(editor.commit(locale: posix))
        editor.drag(to: 0.8)
        let newDrag = editor.value
        XCTAssertEqual(queued.count, 2)

        queued[0]()
        XCTAssertEqual(writes, [Float(1_234.567)])
        queued[1]()
        XCTAssertEqual(writes, [Float(1_234.567), newDrag])
    }

    func test_reset_invalidates_an_already_queued_drag() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.8)

        editor.reset()
        queued[0]()

        XCTAssertEqual(writes, [800])
        XCTAssertEqual(editor.value, 800)
    }

    func test_external_resync_invalidates_a_queued_drag_without_echo_writing() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.8)

        editor.resync(value: 5_678.25)
        queued[0]()

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(editor.value, 5_678.25)
    }

    func test_disappearing_control_invalidates_queued_work() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.8)

        editor.stop()
        queued[0]()

        XCTAssertTrue(writes.isEmpty)
    }

    func test_final_drag_is_written_immediately_and_queued_tick_does_not_duplicate_it() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.2)
        editor.drag(to: 0.8)
        let finalValue = editor.value

        editor.finishDragging()
        XCTAssertEqual(writes, [finalValue])
        queued[0]()
        XCTAssertEqual(writes, [finalValue])
    }

    func test_own_write_acknowledgement_does_not_cancel_a_newer_pending_drag() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.2)
        queued[0]()
        let firstWrite = writes[0]
        editor.drag(to: 0.8)
        let latest = editor.value

        editor.receiveModelValue(firstWrite)
        queued[1]()

        XCTAssertEqual(writes, [firstWrite, latest])
        XCTAssertEqual(editor.value, latest)
    }

    func test_different_model_readback_remains_authoritative_and_cancels_a_pending_drag() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { queued.append($0) })
        editor.drag(to: 0.2)
        queued[0]()
        let firstWrite = writes[0]
        editor.drag(to: 0.8)

        editor.receiveModelValue(19_000)
        queued[1]()

        XCTAssertEqual(writes, [firstWrite])
        XCTAssertEqual(editor.value, 19_000)
        XCTAssertTrue(editor.presentation.displayValue(editor.value).contains("out of range"))
    }

    func test_post_write_au_readback_is_retained_even_when_the_unit_refuses_a_valid_typed_value() {
        var writes: [Float] = []
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: 800, onCommit: { writes.append($0) }, readValue: { 800 }
        )
        editor.beginEditing(locale: posix)
        editor.text = "1234.5"

        XCTAssertTrue(editor.commit(locale: posix))

        XCTAssertEqual(writes, [1_234.5])
        XCTAssertEqual(editor.value, 800, "Show actual readback even when initialValue never changes")
    }

    func test_post_write_out_of_range_au_readback_is_diagnosed_without_clamping() {
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: 800, onCommit: { _ in }, readValue: { 19_000 }
        )
        editor.reset()

        XCTAssertEqual(editor.value, 19_000)
        XCTAssertTrue(editor.presentation.displayValue(editor.value).contains("out of range"))
    }

    func test_repeated_identical_invalid_resync_does_not_republish_diagnostic_state() {
        for readback: Float in [.nan, .infinity, -.infinity, 19_000] {
            var writes: [Float] = []
            let editor = makeEditor(onCommit: { writes.append($0) }, schedule: { _ in })
            editor.resync(value: readback)
            var changes = 0
            var values = 0
            var texts = 0
            let subscriptions = [
                editor.objectWillChange.sink { _ in changes += 1 },
                editor.$value.dropFirst().sink { _ in values += 1 },
                editor.$text.dropFirst().sink { _ in texts += 1 },
            ]

            for _ in 0 ..< 3 {
                editor.resync(value: readback)
                editor.receiveModelValue(readback)
            }

            XCTAssertEqual(changes, 0, "Repeated diagnostic readback must not schedule another view update")
            XCTAssertEqual(values, 0)
            XCTAssertEqual(texts, 0)
            XCTAssertTrue(writes.isEmpty)
            withExtendedLifetime(subscriptions) {}
        }
    }

    func test_edit_then_cancel_restores_actual_readback_after_a_pending_keyboard_drag() {
        var queued: [() -> Void] = []
        var writes: [Float] = []
        var actual: Float = 800
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: actual, onCommit: { writes.append($0) }, readValue: { actual },
            scheduleDrag: { queued.append($0) }
        )
        editor.drag(to: 0.8)
        XCTAssertNotEqual(editor.value, actual)

        editor.beginEditing(locale: posix)
        XCTAssertEqual(editor.value, actual)
        editor.text = "1500"
        actual = 900
        editor.cancel()
        queued[0]()

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(editor.value, actual)
        XCTAssertEqual(Float(editor.text), actual)
    }

    func test_submit_and_reset_are_not_replaced_by_pre_write_cancel_readback() {
        var actual: Float = 1_500
        var writes: [Float] = []
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: actual, onCommit: { actual = $0; writes.append($0) }, readValue: { actual }
        )
        editor.beginEditing(locale: posix)
        editor.text = "1234.5"
        XCTAssertTrue(editor.commit(locale: posix))
        XCTAssertEqual(editor.value, 1_234.5)
        XCTAssertEqual(actual, 1_234.5)

        editor.reset()

        XCTAssertEqual(writes, [1_234.5, 800])
        XCTAssertEqual(editor.value, 800)
        XCTAssertEqual(actual, 800)
    }

    func test_slider_takes_over_text_editing_and_retains_the_new_queued_drag() {
        var queued: [() -> Void] = []
        var actual: Float = 800
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: actual, onCommit: { actual = $0 }, readValue: { actual },
            scheduleDrag: { queued.append($0) }
        )
        editor.beginEditing(locale: posix)
        editor.text = "invalid draft"
        editor.drag(to: 0.8)
        let target = editor.value

        // The helper reports that text editing ended before the next focus
        // notification. Actual SwiftUI focus delivery is a separate manual gate.
        XCTAssertFalse(editor.isEditing)
        queued[0]()

        XCTAssertEqual(actual, target)
        XCTAssertEqual(editor.value, target)
    }

    func test_repeated_nan_readback_does_not_destroy_a_correctable_numeric_draft() {
        var writes: [Float] = []
        let editor = ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: .nan, onCommit: { writes.append($0) }
        )
        editor.beginEditing(locale: posix)
        editor.text = "1234.5"

        editor.receiveModelValue(.nan)

        XCTAssertEqual(editor.text, "1234.5")
        XCTAssertTrue(editor.commit(locale: posix))
        XCTAssertEqual(writes, [1_234.5])
    }

    private var posix: Locale { Locale(identifier: "en_US_POSIX") }

    private func makeEditor(
        onCommit: @escaping (Float) -> Void,
        schedule: @escaping (@escaping () -> Void) -> Void
    ) -> ParameterValueEditor {
        ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: 800, onCommit: onCommit, scheduleDrag: schedule
        )
    }
}

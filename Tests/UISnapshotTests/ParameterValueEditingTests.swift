import Effects
import Foundation
@testable import UI
import XCTest

/// Input helper contracts: constructing, editing, and resyncing never
/// writes; commit/reset deliver native parameter values via the callback.
/// These tests do not host SwiftUI or exercise focus, Space routing, or the
/// drag scheduler; scheduling and model integration have separate test cases.
@MainActor
final class ParameterValueEditingTests: XCTestCase {

    func test_begin_editing_seeds_exact_hertz_instead_of_the_rounded_readout() {
        var writes: [Float] = []
        let editor = makeEditor(value: 1_234.567) { writes.append($0) }

        editor.beginEditing(locale: posix)

        XCTAssertTrue(editor.isEditing)
        XCTAssertEqual(Float(editor.text), Float(1_234.567))
        XCTAssertTrue(writes.isEmpty)
    }

    func test_typing_does_not_write_until_submit_then_delivers_the_exact_value_once() {
        var writes: [Float] = []
        let editor = makeEditor(value: 800) { writes.append($0) }
        editor.beginEditing(locale: posix)
        for text in ["1", "12", "1234", "1234.5"] {
            editor.text = text
        }
        XCTAssertTrue(writes.isEmpty)

        XCTAssertTrue(editor.commit(locale: posix))

        XCTAssertEqual(writes, [1_234.5])
        XCTAssertEqual(editor.value, 1_234.5)
        XCTAssertFalse(editor.isEditing)
    }

    func test_invalid_submit_does_not_write_or_replace_the_model_value() {
        for text in ["", "junk", "NaN", "inf", "-Infinity", "1e309", "199", "18001", "800x"] {
            var writes: [Float] = []
            let editor = makeEditor(value: 800) { writes.append($0) }
            editor.beginEditing(locale: posix)
            editor.text = text

            XCTAssertFalse(editor.commit(locale: posix), text)

            XCTAssertTrue(writes.isEmpty, text)
            XCTAssertEqual(editor.value, 800, text)
            // Keep the invalid draft available for correction or Escape.
            XCTAssertTrue(editor.isEditing, text)
            XCTAssertEqual(editor.text, text)
        }
    }

    func test_cancel_discards_even_a_valid_draft_without_writing() {
        var writes: [Float] = []
        let editor = makeEditor(value: 800) { writes.append($0) }
        editor.beginEditing(locale: posix)
        editor.text = "1500"

        editor.cancel()

        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(editor.value, 800)
        XCTAssertFalse(editor.isEditing)
        editor.beginEditing(locale: posix)
        XCTAssertEqual(Float(editor.text), 800)
    }

    func test_reset_uses_the_catalog_default_not_the_range_midpoint_or_initial_value() {
        for parameter in EQNode.parameterCatalog + GainNode.parameterCatalog {
            var writes: [Float] = []
            let editor = ParameterValueEditor(
                parameter: parameter, initialValue: parameter.range.upperBound,
                onCommit: { writes.append($0) }
            )
            editor.beginEditing(locale: posix)
            editor.text = "invalid draft"

            editor.reset()

            XCTAssertEqual(writes, [parameter.defaultValue], parameter.identifier)
            XCTAssertEqual(editor.value, parameter.defaultValue, parameter.identifier)
            XCTAssertFalse(editor.isEditing)
        }
    }

    func test_programmatic_parameter_resync_updates_the_next_edit_without_echo_writes() {
        var writes: [Float] = []
        let editor = makeEditor(value: 800) { writes.append($0) }

        editor.resync(value: 5_678.25)
        editor.beginEditing(locale: posix)

        XCTAssertEqual(editor.value, 5_678.25)
        XCTAssertEqual(Float(editor.text), 5_678.25)
        XCTAssertTrue(writes.isEmpty)
    }

    func test_preset_resync_invalidates_a_stale_draft_and_cancel_keeps_the_new_value() {
        // External model changes win over an uncommitted edit, preventing a
        // later Return from accidentally restoring a value from the old preset.
        var writes: [Float] = []
        let editor = makeEditor(value: 800) { writes.append($0) }
        editor.beginEditing(locale: posix)
        editor.text = "1500"

        editor.resync(value: 4_321.25)
        XCTAssertEqual(Float(editor.text), 4_321.25, "Return must not submit the old preset's draft")
        editor.cancel()
        editor.beginEditing(locale: posix)

        XCTAssertEqual(editor.value, 4_321.25)
        XCTAssertEqual(Float(editor.text), 4_321.25)
        XCTAssertTrue(writes.isEmpty)
    }

    func test_out_of_range_model_readback_is_retained_but_cannot_be_submitted_as_valid() {
        var writes: [Float] = []
        let editor = makeEditor(value: 19_000) { writes.append($0) }
        editor.beginEditing(locale: posix)

        XCTAssertEqual(editor.value, 19_000)
        XCTAssertEqual(Float(editor.text), 19_000)
        XCTAssertFalse(editor.commit(locale: posix))
        XCTAssertTrue(writes.isEmpty)

        editor.text = "18000"
        XCTAssertTrue(editor.commit(locale: posix))
        XCTAssertEqual(writes, [18_000])
    }

    func test_nonfinite_model_resync_does_not_echo_or_turn_into_a_valid_typed_write() {
        for value: Float in [.nan, .infinity, -.infinity] {
            var writes: [Float] = []
            let editor = makeEditor(value: 800) { writes.append($0) }

            editor.resync(value: value)
            if value.isNaN {
                XCTAssertTrue(editor.value.isNaN)
            } else {
                XCTAssertEqual(editor.value, value)
            }
            editor.beginEditing(locale: posix)
            XCTAssertFalse(editor.commit(locale: posix))
            XCTAssertTrue(writes.isEmpty)
        }
    }

    func test_two_quick_submits_keep_the_final_exact_value_without_waiting_for_a_drag_throttle() {
        // Pure input callback boundary only. Queued-drag ordering and the
        // actual UI writer/model path are exercised in their dedicated suites.
        var writes: [Float] = []
        let editor = makeEditor(value: 800) { writes.append($0) }
        editor.beginEditing(locale: posix)
        editor.text = "1000"
        XCTAssertTrue(editor.commit(locale: posix))
        editor.beginEditing(locale: posix)
        editor.text = "1234.567"
        XCTAssertTrue(editor.commit(locale: posix))

        XCTAssertEqual(writes, [1_000, Float(1_234.567)])
        XCTAssertEqual(editor.value, Float(1_234.567))
    }

    func test_percent_editor_seeds_display_units_and_commits_native_fraction() {
        var writes: [Float] = []
        let parameter = EffectParameter(
            identifier: "test.mix", displayName: "Mix", range: 0 ... 1,
            defaultValue: 0.5, unit: .percent
        )
        let editor = ParameterValueEditor(
            parameter: parameter, initialValue: 0.25, onCommit: { writes.append($0) }
        )
        editor.beginEditing(locale: posix)
        XCTAssertEqual(Float(editor.text), 25)

        editor.text = "70"
        XCTAssertTrue(editor.commit(locale: posix))
        XCTAssertEqual(writes, [0.7])
        XCTAssertEqual(editor.value, 0.7)
    }

    func test_locale_specific_draft_seeding_roundtrips_an_unchanged_exact_value() {
        var writes: [Float] = []
        let editor = makeEditor(value: 1_234.5) { writes.append($0) }
        let german = Locale(identifier: "de_DE")

        editor.beginEditing(locale: german)

        XCTAssertEqual(editor.text, "1234,5")
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(editor.commit(locale: german))
        XCTAssertEqual(writes, [1_234.5])
    }

    private var posix: Locale { Locale(identifier: "en_US_POSIX") }

    private func makeEditor(value: Float, onCommit: @escaping (Float) -> Void) -> ParameterValueEditor {
        ParameterValueEditor(
            parameter: EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!,
            initialValue: value, onCommit: onCommit
        )
    }
}

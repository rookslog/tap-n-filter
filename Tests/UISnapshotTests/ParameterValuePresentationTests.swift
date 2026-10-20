import Effects
import Foundation
@testable import UI
import XCTest

/// Stage A contract tests for a new internal UI helper, not a DSP scale change.
/// Missing `ParameterValuePresentation` is structural red until Stage B;
/// it is not evidence that a behavioral assertion ran and failed.
final class ParameterValuePresentationTests: XCTestCase {

    func test_frequency_endpoints_and_geometric_midpoint_use_logarithmic_position() {
        // Exercise both actual EQ catalog ranges, rather than a convenient
        // power-of-ten range that could hide an incorrect logarithm base.
        for parameter in EQNode.parameterCatalog where parameter.unit == .hertz {
            let presentation = ParameterValuePresentation(parameter: parameter)
            let midpoint = sqrt(parameter.range.lowerBound * parameter.range.upperBound)

            XCTAssertEqual(presentation.position(for: parameter.range.lowerBound), 0, accuracy: 0.00001)
            XCTAssertEqual(presentation.position(for: parameter.range.upperBound), 1, accuracy: 0.00001)
            XCTAssertEqual(presentation.position(for: midpoint), 0.5, accuracy: 0.00001)
            XCTAssertEqual(presentation.value(at: 0), parameter.range.lowerBound, accuracy: 0.001)
            XCTAssertEqual(presentation.value(at: 1), parameter.range.upperBound, accuracy: 0.01)
            XCTAssertEqual(presentation.value(at: 0.5), midpoint, accuracy: 0.01)
        }
    }

    func test_frequency_position_and_value_roundtrip_through_the_whole_range() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        var previous: Float = 0
        for position in [0.0, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 1.0] {
            let value = presentation.value(at: position)
            XCTAssertTrue(frequency.range.contains(value))
            XCTAssertGreaterThan(value, previous)
            XCTAssertEqual(presentation.position(for: value), position, accuracy: 0.00001)
            previous = value
        }
        for value: Float in [200, 333.25, 800, 1_234.5, 5_000, 18_000] {
            XCTAssertEqual(
                presentation.value(at: presentation.position(for: value)), value,
                accuracy: max(0.001, value * 0.00001)
            )
        }
    }

    func test_gain_ratio_and_percent_keep_arithmetic_midpoints() {
        let parameters = [
            GainNode.parameterCatalog[0],
            makeParameter(unit: .ratio, range: 0.5 ... 4, defaultValue: 0.707),
            makeParameter(unit: .percent, range: 0 ... 1, defaultValue: 0.5),
        ]
        for parameter in parameters {
            let presentation = ParameterValuePresentation(parameter: parameter)
            let midpoint = (parameter.range.lowerBound + parameter.range.upperBound) / 2
            XCTAssertEqual(presentation.position(for: parameter.range.lowerBound), 0, accuracy: 0.00001)
            XCTAssertEqual(presentation.position(for: parameter.range.upperBound), 1, accuracy: 0.00001)
            XCTAssertEqual(presentation.position(for: midpoint), 0.5, accuracy: 0.00001)
            XCTAssertEqual(presentation.value(at: 0.5), midpoint, accuracy: 0.00001)
        }
    }

    func test_thumb_and_slider_writes_are_bounded_without_relabelling_model_readback() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        XCTAssertEqual(presentation.position(for: 100), 0, accuracy: 0.00001)
        XCTAssertEqual(presentation.position(for: 19_000), 1, accuracy: 0.00001)
        XCTAssertEqual(presentation.value(at: -0.2), 200, accuracy: 0.001)
        XCTAssertEqual(presentation.value(at: 1.2), 18_000, accuracy: 0.01)

        // The thumb may be constrained, but the readout must not quietly
        // turn an AU readback of 19 kHz into an apparently valid 18 kHz.
        XCTAssertNotEqual(presentation.displayValue(19_000), presentation.displayValue(18_000))
        XCTAssertNotEqual(presentation.displayValue(100), presentation.displayValue(200))
    }

    func test_frequency_readout_changes_units_at_one_kilohertz() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        for (value, expected): (Float, String) in [
            (200, "200 Hz"), (800, "800 Hz"), (999, "999 Hz"),
            (1_000, "1 kHz"), (1_500, "1.5 kHz"), (18_000, "18 kHz"),
        ] {
            XCTAssertEqual(presentation.displayValue(value), expected)
        }
    }

    func test_other_continuous_units_keep_their_existing_readout_conventions() {
        let cases: [(ParameterUnit, Float, String)] = [
            (.decibels, -6, "-6.0 dB"),
            (.ratio, 0.707, "0.71"),
            (.percent, 0.7, "70%"),
            (.normalized, 0.25, "0.25"),
            (.seconds, 1.25, "1.25 s"),
            (.milliseconds, 125, "125 ms"),
        ]
        for (unit, value, expected) in cases {
            let presentation = ParameterValuePresentation(
                parameter: makeParameter(unit: unit, range: -24 ... 200, defaultValue: 0)
            )
            XCTAssertEqual(presentation.displayValue(value), expected)
        }
    }

    func test_nonfinite_readbacks_are_diagnostic_instead_of_valid_endpoint_values() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        let validReadouts = [presentation.displayValue(200), presentation.displayValue(18_000)]
        for value: Float in [.nan, .infinity, -.infinity] {
            let readout = presentation.displayValue(value)
            XCTAssertFalse(readout.isEmpty)
            XCTAssertFalse(validReadouts.contains(readout))
            // Avoid requiring particular warning prose, while rejecting a
            // numeric-looking readout that could be mistaken for valid Hz.
            XCTAssertNil(presentation.parseInput(readout, locale: posix))
        }
    }

    func test_exact_hertz_input_accepts_boundaries_decimals_and_surrounding_whitespace() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        for (text, expected): (String, Float) in [
            ("200", 200), ("18000", 18_000), ("1234.5", 1_234.5), (" 800.25 \n", 800.25),
        ] {
            XCTAssertEqual(presentation.parseInput(text, locale: posix), expected, text)
        }
    }

    func test_hertz_input_rejects_partial_tokens_nonfinite_overflow_and_out_of_range_values() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        for text in [
            "", " ", "abc", "800abc", "800 900", "800..5", "--800", "800\n900",
            "NaN", "nan", "inf", "-inf", "Infinity", "+Infinity", "∞", "1e309",
            "-200", "0", "199.99", "18000.01", "19000",
        ] {
            XCTAssertNil(presentation.parseInput(text, locale: posix), text)
        }
    }

    func test_numeric_only_hertz_entry_does_not_guess_unit_suffixes() {
        // Conservative input grammar: the editor labels its unit as Hz.
        // A kHz suffix is optional in the brief; this slice does not add it.
        let presentation = ParameterValuePresentation(parameter: frequency)
        for text in ["1.5 kHz", "1.5kHz", "800 Hz", "800Hz", "70%", "-6 dB"] {
            XCTAssertNil(presentation.parseInput(text, locale: posix), text)
        }
    }

    func test_input_honors_explicit_decimal_locale_without_guessing_grouping() {
        let presentation = ParameterValuePresentation(parameter: frequency)
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(presentation.parseInput("1234,5", locale: german), 1_234.5)
        XCTAssertEqual(presentation.parseInput("1234.5", locale: posix), 1_234.5)
        XCTAssertNil(presentation.parseInput("1234,5", locale: posix))
        XCTAssertNil(presentation.parseInput("1234.5", locale: german))
        // A pasted grouping character must not silently change magnitude.
        XCTAssertNil(presentation.parseInput("1,234.5", locale: posix))
        XCTAssertNil(presentation.parseInput("1.234,5", locale: german))
    }

    func test_linear_unit_entry_uses_display_units_but_preserves_native_callback_values() {
        let gain = ParameterValuePresentation(parameter: GainNode.parameterCatalog[0])
        XCTAssertEqual(gain.parseInput("-6.25", locale: posix), -6.25)
        XCTAssertNil(gain.parseInput("12.01", locale: posix))

        let percent = ParameterValuePresentation(
            parameter: makeParameter(unit: .percent, range: 0 ... 1, defaultValue: 0.5)
        )
        XCTAssertEqual(percent.parseInput("70", locale: posix), 0.7)
        XCTAssertEqual(percent.parseInput("0", locale: posix), 0)
        XCTAssertEqual(percent.parseInput("100", locale: posix), 1)
        XCTAssertNil(percent.parseInput("100.01", locale: posix))
    }

    private var frequency: EffectParameter {
        EQNode.parameterCatalog.first { $0.identifier == "lp.frequency" }!
    }

    private var posix: Locale { Locale(identifier: "en_US_POSIX") }

    private func makeParameter(
        unit: ParameterUnit, range: ClosedRange<Float>, defaultValue: Float
    ) -> EffectParameter {
        EffectParameter(
            identifier: "test.value", displayName: "Value", range: range,
            defaultValue: defaultValue, unit: unit
        )
    }
}

import Effects
import Foundation
import SwiftUI

/// UI-only scales and display/input units. Native parameter values stay unchanged.
struct ParameterValuePresentation {
    let parameter: EffectParameter

    private var usesLogScale: Bool {
        parameter.unit == .hertz && parameter.range.lowerBound > 0
    }

    func position(for value: Float) -> Double {
        let lower = Double(parameter.range.lowerBound)
        let upper = Double(parameter.range.upperBound)
        guard upper > lower, !value.isNaN else { return 0 }
        let bounded = min(max(Double(value), lower), upper)
        return usesLogScale
            ? log(bounded / lower) / log(upper / lower)
            : (bounded - lower) / (upper - lower)
    }

    func value(at position: Double) -> Float {
        let lower = Double(parameter.range.lowerBound)
        let upper = Double(parameter.range.upperBound)
        let bounded = position.isNaN ? 0 : min(max(position, 0), 1)
        if bounded == 0 { return parameter.range.lowerBound }
        if bounded == 1 { return parameter.range.upperBound }
        let value = usesLogScale
            ? lower * pow(upper / lower, bounded)
            : lower + (upper - lower) * bounded
        return Float(min(max(value, lower), upper))
    }

    func isValid(_ value: Float) -> Bool {
        value.isFinite && parameter.range.contains(value)
    }

    var inputUnit: String {
        switch parameter.unit {
        case .hertz: return "Hz"
        case .decibels: return "dB"
        case .ratio: return "ratio"
        case .seconds: return "s"
        case .milliseconds: return "ms"
        case .normalized: return "0–1"
        case .percent: return "%"
        case .integer, .enumValue: return ""
        }
    }

    func displayValue(_ value: Float) -> String {
        guard value.isFinite else { return "Invalid value (\(value))" }
        let readout: String
        switch parameter.unit {
        case .hertz:
            if abs(value) >= 1_000 {
                var number = format("%.2f", Double(value) / 1_000)
                while number.hasSuffix("0") { number.removeLast() }
                if number.hasSuffix(".") { number.removeLast() }
                readout = "\(number) kHz"
            } else {
                readout = "\(format("%.0f", Double(value.rounded(.towardZero)))) Hz"
            }
        case .decibels: readout = "\(format("%.1f", Double(value))) dB"
        case .ratio, .normalized: readout = format("%.2f", Double(value))
        case .seconds: readout = "\(format("%.2f", Double(value))) s"
        case .milliseconds: readout = "\(format("%.0f", Double(value.rounded(.towardZero)))) ms"
        case .percent: readout = "\(format("%.0f", Double((value * 100).rounded(.towardZero))))%"
        case .integer, .enumValue: readout = format("%.0f", Double(value.rounded(.towardZero)))
        }
        return isValid(value) ? readout : "\(readout) (out of range)"
    }

    /// Full-token numeric grammar with the caller's decimal separator; no
    /// grouping or unit suffixes. Check the Double range before Float rounding.
    func parseInput(_ text: String, locale: Locale) -> Float? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = locale.decimalSeparator ?? "."
        let decimal = NSRegularExpression.escapedPattern(for: separator)
        let pattern = "^[+-]?(?:[0-9]+(?:\(decimal)[0-9]*)?|\(decimal)[0-9]+)(?:[eE][+-]?[0-9]+)?$"
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let display = Double(text.replacingOccurrences(of: separator, with: ".")),
              display.isFinite else { return nil }
        let native = parameter.unit == .percent ? display / 100 : display
        guard native >= Double(parameter.range.lowerBound),
              native <= Double(parameter.range.upperBound) else { return nil }
        let value = Float(native)
        return isValid(value) ? value : nil
    }

    func inputText(for value: Float, locale: Locale) -> String {
        var text = String(value)
        if parameter.unit == .percent, value.isFinite {
            let scaled = value * 100
            // Prefer a short draft such as 70.0, unless that loses a Float
            // bit on conversion back to native units.
            text = Float(Double(scaled) / 100) == value
                ? String(scaled) : String(Double(value) * 100)
        }
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    private func format(_ format: String, _ value: Double) -> String {
        String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// A UI-only focused value, shared with PowerToggle; no persisted app state.
private struct ParameterNumericEditingKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var parameterNumericEditing: Bool? {
        get { self[ParameterNumericEditingKey.self] }
        set { self[ParameterNumericEditingKey.self] = newValue }
    }
}

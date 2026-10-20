import Combine
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

/// Owns draft state and a 33 ms latest-value drag coalescer. Generation checks
/// invalidate queued work even if it has already been enqueued on the main queue.
@MainActor
final class ParameterValueEditor: ObservableObject {
    let presentation: ParameterValuePresentation
    @Published private(set) var value: Float
    @Published var text: String {
        didSet {
            if errorMessage != nil { errorMessage = nil }
        }
    }
    @Published private(set) var isEditing = false
    @Published private(set) var errorMessage: String?

    private var locale = Locale.current
    private let onCommit: (Float) -> Void
    private let readValue: (() -> Float)?
    private let scheduleDrag: (@escaping () -> Void) -> Void
    private var generation: UInt = 0
    private var pendingDrag: Float?
    private var dragScheduled = false
    private var lastWritten: Float?

    init(
        parameter: EffectParameter,
        initialValue: Float,
        onCommit: @escaping (Float) -> Void,
        readValue: (() -> Float)? = nil,
        scheduleDrag: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { action() }
        }
    ) {
        let presentation = ParameterValuePresentation(parameter: parameter)
        self.presentation = presentation
        self.value = initialValue
        self.text = presentation.inputText(for: initialValue, locale: .current)
        self.onCommit = onCommit
        self.readValue = readValue
        self.scheduleDrag = scheduleDrag
    }

    func beginEditing(locale: Locale) {
        self.locale = locale
        if let actual = readValue?() {
            resync(value: actual)
        } else {
            invalidateDrag()
        }
        let draft = presentation.inputText(for: value, locale: locale)
        if text != draft { text = draft }
        if !isEditing { isEditing = true }
    }

    @discardableResult
    func commit(locale: Locale) -> Bool {
        guard let parsed = presentation.parseInput(text, locale: locale) else {
            let range = presentation.parameter.range
            let lower = presentation.inputText(for: range.lowerBound, locale: locale)
            let upper = presentation.inputText(for: range.upperBound, locale: locale)
            errorMessage = "Enter a finite number from \(lower) to \(upper) \(presentation.inputUnit)."
            return false
        }
        invalidateDrag()
        value = parsed
        self.locale = locale
        endEditing()
        write(parsed)
        return true
    }

    func cancel() {
        // Beginning an edit may discard a pending keyboard drag. Restore
        // actual model readback rather than retaining that optimistic value.
        if let actual = readValue?() {
            resync(value: actual)
        } else {
            invalidateDrag()
        }
        endEditing()
    }

    func reset() {
        invalidateDrag()
        value = presentation.parameter.defaultValue
        endEditing()
        write(value)
    }

    func resync(value: Float) {
        invalidateDrag()
        lastWritten = nil
        // NaN is unequal to itself, but repeated NaN readback represents the
        // same diagnostic state. Avoid republishing it (or resetting a draft)
        // when SwiftUI reevaluates onChange for that unchanged invalid value.
        guard self.value != value && !(self.value.isNaN && value.isNaN) else { return }
        self.value = value
        let draft = presentation.inputText(for: value, locale: locale)
        if text != draft { text = draft }
    }

    /// An acknowledgement of our own write must not cancel a newer pending
    /// drag. Any other observed value is authoritative model/preset readback.
    func receiveModelValue(_ value: Float) {
        let echo = lastWritten
        lastWritten = nil
        if echo == value { return }
        resync(value: value)
    }

    func drag(to position: Double) {
        guard position.isFinite else { return }
        // Focus loss can be delivered after the slider's binding update.
        // Mark the text edit finished before enqueuing the new slider value.
        if isEditing { endEditing() }
        value = presentation.value(at: position)
        text = presentation.inputText(for: value, locale: locale)
        pendingDrag = value
        guard !dragScheduled else { return }
        dragScheduled = true
        let scheduledGeneration = generation
        scheduleDrag { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.dragScheduled = false
            guard let pending = self.pendingDrag else { return }
            self.pendingDrag = nil
            self.write(pending)
        }
    }

    /// Deliver the final drag synchronously, then make the queued tick inert.
    func finishDragging() {
        guard let pending = pendingDrag else { return }
        invalidateDrag()
        write(pending)
    }

    func stop() {
        cancel()
    }

    private func endEditing() {
        let draft = presentation.inputText(for: value, locale: locale)
        if text != draft { text = draft }
        if isEditing { isEditing = false }
        if errorMessage != nil { errorMessage = nil }
    }

    private func invalidateDrag() {
        generation &+= 1
        pendingDrag = nil
        dragScheduled = false
    }

    private func write(_ value: Float) {
        guard presentation.isValid(value) else { return }
        lastWritten = value
        onCommit(value)
        // A unit may refuse or alter a write without changing the parent's
        // previous readback, so onChange(initialValue) alone is insufficient.
        if let actual = readValue?(), actual != value {
            resync(value: actual)
        }
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

import Combine
import Effects
import Foundation

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
            // Resync clears the previous acknowledgement. The AU's actual
            // normalized readback is the value the parent will acknowledge.
            lastWritten = actual
        }
    }
}

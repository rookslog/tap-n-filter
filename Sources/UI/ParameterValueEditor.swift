import Combine
import Effects
import Foundation
import ViewModel

/// Owns draft/presentation state. Standalone clients retain local coalescing;
/// the production factory accepts intent synchronously into the VM coalescer.
@MainActor
final class ParameterValueEditor: ObservableObject {
    private enum Fallback {
        case seed(Float)
        case observed(Float)
        case successful(ParameterSuccessfulPresentation)

        var value: Float {
            switch self {
            case .seed(let value), .observed(let value): return value
            case .successful(let basis): return basis.value
            }
        }
    }

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
    private let onCommit: ((Float) -> Void)?
    private let readValue: (() -> Float?)?
    private let scheduleDrag: (@escaping () -> Void) -> Void
    private var generation: UInt = 0
    private var pendingDrag: Float?
    private var dragScheduled = false
    private var lastWritten: Float?
    private let onDragAccepted: ((Float, UInt64) -> Void)?
    private let onCommitIntent: ((Float, UInt64) -> Void)?
    private let finishAcceptedDrag: (() -> Void)?
    private let stopAcceptedEditing: (() -> Void)?
    private let pendingAcceptedValue: (() -> Float?)?
    private let applicationSessionID: UUID?
    private let successfulPresentation: (() -> ParameterSuccessfulPresentation?)?
    private let latestStartedOperationOrder: (() -> UInt64?)?
    private var fallback: Fallback
    private var incorporatedSuccessOrder: UInt64 = 0
    private var awaitingSubmission = false
    private var interactionRevision: UInt64 = 0
    private var latestSubmittedRevision: UInt64 = 0
    private var latestApplicationSerial: UInt64 = 0
    private var authoritativeActual: Float?
    private var stopped = false
    private var usesAcceptedEdits: Bool { onDragAccepted != nil }

    init(
        parameter: EffectParameter,
        initialValue: Float,
        onCommit: ((Float) -> Void)? = nil,
        readValue: (() -> Float?)? = nil,
        scheduleDrag: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(33)) { action() }
        },
        onDragAccepted: ((Float, UInt64) -> Void)? = nil,
        onCommitIntent: ((Float, UInt64) -> Void)? = nil,
        finishAcceptedDrag: (() -> Void)? = nil,
        stopAcceptedEditing: (() -> Void)? = nil,
        pendingAcceptedValue: (() -> Float?)? = nil,
        applicationSessionID: UUID? = nil,
        initialActual: Float? = nil,
        successfulPresentation: (() -> ParameterSuccessfulPresentation?)? = nil,
        latestStartedOperationOrder: (() -> UInt64?)? = nil
    ) {
        let presentation = ParameterValuePresentation(parameter: parameter)
        self.presentation = presentation
        self.value = initialValue
        self.text = presentation.inputText(for: initialValue, locale: .current)
        self.onCommit = onCommit
        self.readValue = readValue
        self.scheduleDrag = scheduleDrag
        self.onDragAccepted = onDragAccepted
        self.onCommitIntent = onCommitIntent
        self.finishAcceptedDrag = finishAcceptedDrag
        self.stopAcceptedEditing = stopAcceptedEditing
        self.pendingAcceptedValue = pendingAcceptedValue
        self.applicationSessionID = applicationSessionID
        self.successfulPresentation = successfulPresentation
        self.latestStartedOperationOrder = latestStartedOperationOrder
        // Optimistic initial pending input is not successful history. Only an
        // actual observation, scoped success, or original catalog seed may be
        // used after a settled rejection.
        self.fallback = .seed(parameter.defaultValue)
        if let initialActual { observe(initialActual) }
        else { incorporateSuccessfulPresentation() }
    }

    func beginEditing(locale: Locale) {
        guard !stopped else { return }
        interactionRevision &+= 1
        self.locale = locale
        if usesAcceptedEdits {
            // A numeric draft is not a cancellation of already accepted VM
            // input. Keep own-write echo acknowledgements across draft starts.
            invalidateDrag()
            if let current = readValue?() {
                present(current)
                if pendingAcceptedValue?() == nil { observe(current) }
            } else {
                authoritativeActual = nil
            }
        } else if let actual = readValue?() {
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
        guard !stopped else { return false }
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
        if usesAcceptedEdits {
            invalidateDrag()
            if let pending = pendingAcceptedValue?() { present(pending) }
            else if let actual = readValue?() { observe(actual); present(actual) }
            else {
                authoritativeActual = nil
                incorporateSuccessfulPresentation()
                present(fallback.value)
            }
            endEditing()
            return
        }
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
        guard !stopped else { return }
        invalidateDrag()
        value = presentation.parameter.defaultValue
        endEditing()
        write(value)
    }

    func resync(value: Float) {
        invalidateDrag()
        lastWritten = nil
        if usesAcceptedEdits { observe(value) }
        else { authoritativeActual = value }
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
        if usesAcceptedEdits {
            guard !stopped else { return }
            // Parent floats may be stale or a default substituted for nil.
            if let pending = pendingAcceptedValue?() {
                if !isEditing { present(pending) }
                return
            }
            guard let actual = readValue?() else { return }
            let previousActual = authoritativeActual
            // Even an equal ordinary observation watermarks already-started
            // invocations, including success not yet published by an outer write.
            observe(actual)
            // The result already reconciled this actual without erasing a
            // newer draft. No historical float backlog can hide a later change.
            if let previousActual, sameValue(previousActual, actual) { return }
            // A genuine authoritative transition must reconcile text even if
            // its scalar equals our optimistic value. Standalone resync keeps
            // its unchanged-value/NaN draft suppression semantics.
            invalidateDrag()
            lastWritten = nil
            present(actual)
            return
        }
        let echo = lastWritten
        lastWritten = nil
        if let echo, sameValue(echo, value) { return }
        resync(value: value)
    }

    /// Acknowledges actual native application without cancelling accepted input
    /// or overwriting a newer drag/numeric draft. Nil is never a default value.
    func receiveApplicationResult(_ result: ParameterApplicationResult) {
        guard !stopped, let applicationSessionID, result.sessionID == applicationSessionID,
              result.applicationSerial > latestApplicationSerial else { return }
        latestApplicationSerial = result.applicationSerial
        // Success order is independent of callback serial and editor revision.
        // An older outer callback may establish fallback after a newer reject.
        incorporateSuccessfulPresentation()
        if result.intentRevision == latestSubmittedRevision { awaitingSubmission = false }
        authoritativeActual = result.actualValue
        guard let actual = result.actualValue else {
            let accepted: Float
            if let pending = pendingAcceptedValue?() { accepted = pending }
            else if awaitingSubmission, result.intentRevision < latestSubmittedRevision { return }
            else { accepted = fallback.value }
            // Fallback never repopulates authoritativeActual. Preserve exact
            // text/editing/error while repairing the backing value of a draft.
            if isEditing {
                if !sameValue(value, accepted) { value = accepted }
            } else {
                present(accepted)
            }
            return
        }
        observe(actual)
        if !isEditing, result.intentRevision >= latestSubmittedRevision { present(actual) }
    }

    func drag(to position: Double) {
        guard !stopped, position.isFinite else { return }
        // Focus loss can be delivered after the slider's binding update.
        // Mark the text edit finished before enqueuing the new slider value.
        if isEditing { endEditing() }
        value = presentation.value(at: position)
        text = presentation.inputText(for: value, locale: locale)
        if let onDragAccepted {
            interactionRevision &+= 1
            latestSubmittedRevision = interactionRevision
            awaitingSubmission = true
            onDragAccepted(value, interactionRevision)
            return
        }
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
        if let finishAcceptedDrag { finishAcceptedDrag(); return }
        guard let pending = pendingDrag else { return }
        invalidateDrag()
        write(pending)
    }

    func stop() {
        if let stopAcceptedEditing {
            stopAcceptedEditing()
            stopped = true
        }
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
        if let onCommitIntent {
            interactionRevision &+= 1
            latestSubmittedRevision = interactionRevision
            awaitingSubmission = true
            onCommitIntent(value, interactionRevision)
            return
        }
        lastWritten = value
        onCommit?(value)
        // A unit may refuse or alter a write without changing the parent's
        // previous readback, so onChange(initialValue) alone is insufficient.
        if let actual = readValue?(), actual != value {
            resync(value: actual)
            // Resync clears the previous acknowledgement. The AU's actual
            // normalized readback is the value the parent will acknowledge.
            lastWritten = actual
        }
    }

    private func sameValue(_ lhs: Float, _ rhs: Float) -> Bool {
        lhs == rhs || (lhs.isNaN && rhs.isNaN)
    }

    private func observe(_ actual: Float) {
        authoritativeActual = actual
        fallback = .observed(actual)
        incorporatedSuccessOrder = max(
            incorporatedSuccessOrder, latestStartedOperationOrder?() ?? 0
        )
    }

    private func incorporateSuccessfulPresentation() {
        guard let basis = successfulPresentation?(),
              basis.operationOrder > incorporatedSuccessOrder else { return }
        incorporatedSuccessOrder = basis.operationOrder
        fallback = .successful(basis)
    }

    private func present(_ actual: Float) {
        if !sameValue(value, actual) { value = actual }
        let draft = presentation.inputText(for: actual, locale: locale)
        if text != draft { text = draft }
    }
}

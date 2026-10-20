import Effects
import Foundation

/// Whether a native parameter setter completed without throwing. Different or
/// unavailable readback is not itself a rejection.
public enum ParameterApplicationOutcome: Equatable {
    /// Setter completed without throwing; readback may still differ or be nil.
    case applied
    /// Setter threw, leaving an unresolved failure on the live target.
    case rejected
}

/// Scoped acknowledgement of one actual setter attempt, independent of whether
/// the native value changed enough to produce a SwiftUI model echo.
public struct ParameterApplicationResult {
    /// The submitting session, or the pending session superseded by this write.
    public let sessionID: UUID
    /// Submitted intent revision, including an intent superseded by a direct write.
    public let intentRevision: UInt64
    /// Monotonically increasing application acknowledgement serial.
    public let applicationSerial: UInt64
    /// Accepted value passed to the native setter.
    public let requestedValue: Float
    /// Actual readback, including nil and diagnostic nonfinite values unchanged.
    public let actualValue: Float?
    /// Setter success or throwing rejection.
    public let outcome: ParameterApplicationOutcome
}

/// Presentation history from a successful setter invocation, not current
/// measured state or a guarantee that a throwing setter rolled back.
public struct ParameterSuccessfulPresentation {
    /// Setter-invocation order, independent of intent and callback order.
    public let operationOrder: UInt64
    /// Returned actual when available, otherwise the successful request.
    public let value: Float
}

/// A control session bound to a graph generation and one concrete node object.
/// The owner and node are weak; keeping a control alive cannot keep the VM alive.
@MainActor
public final class ParameterEditHandle {
    /// Unique identity for scoped application results.
    public let sessionID = UUID()
    fileprivate weak var owner: AcceptedParameterEdits?
    fileprivate weak var node: (any EffectNode)?
    fileprivate let nodeID: UUID
    fileprivate let parameterID: String
    fileprivate let generation: UInt64
    fileprivate var active = true
    fileprivate var handler: ((ParameterApplicationResult) -> Void)?

    fileprivate init(owner: AcceptedParameterEdits, node: any EffectNode, parameterID: String) {
        self.owner = owner
        self.node = node
        self.nodeID = node.id
        self.parameterID = parameterID
        self.generation = owner.generation
    }

    /// Install the session's single result consumer. UI consumers capture their
    /// editor weakly. Retired/obsolete sessions never receive new applications.
    public func setApplicationResultHandler(_ handler: @escaping (ParameterApplicationResult) -> Void) {
        self.handler = handler
    }

    /// Latest successful presentation for this live session's concrete target.
    /// Validates ownership/generation/session without reading native state.
    public var successfulPresentation: ParameterSuccessfulPresentation? {
        owner?.successfulPresentation(for: self)
    }
}

struct ParameterApplication {
    let success: Bool
    let actual: Float?
}

/// The single production delivery coalescer. Pending intent crosses this VM
/// boundary synchronously; only native delivery is deferred. No timer retries.
@MainActor
final class AcceptedParameterEdits {
    private struct Target: Hashable {
        let object: ObjectIdentifier
        let parameter: String
    }
    private struct Pending {
        let handle: ParameterEditHandle
        let value: Float
        let intentRevision: UInt64
        let order: UInt64
        let ticket: UInt64
    }
    private final class Failure {
        weak var node: (any EffectNode)?
        let nodeID: UUID
        init(_ node: any EffectNode) { self.node = node; self.nodeID = node.id }
    }
    private final class Completed {
        weak var node: (any EffectNode)?
        let nodeID: UUID
        var success: ParameterSuccessfulPresentation?
        var outcomeOrder: UInt64 = 0
        init(_ node: any EffectNode) { self.node = node; self.nodeID = node.id }
    }

    fileprivate private(set) var generation: UInt64 = 0
    private let schedule: (@escaping () -> Void) -> Void
    private let isCurrent: (any EffectNode) -> Bool
    private let apply: (any EffectNode, String, Float) -> ParameterApplication
    private var pending: [Target: Pending] = [:]
    private var failures: [Target: Failure] = [:]
    private var completed: [Target: Completed] = [:]
    private var latestOrders: [Target: UInt64] = [:]
    private var nextTicket: UInt64 = 0
    private var nextOrder: UInt64 = 0
    private var nextAttempt: UInt64 = 0
    private var applicationSerial: UInt64 = 0

    init(schedule: @escaping (@escaping () -> Void) -> Void,
         isCurrent: @escaping (any EffectNode) -> Bool,
         apply: @escaping (any EffectNode, String, Float) -> ParameterApplication) {
        self.schedule = schedule
        self.isCurrent = isCurrent
        self.apply = apply
    }

    func makeHandle(node: any EffectNode, parameterID: String) -> ParameterEditHandle? {
        discardStale()
        guard isCurrent(node), node.parameters.contains(where: { $0.identifier == parameterID }) else {
            return nil
        }
        return ParameterEditHandle(owner: self, node: node, parameterID: parameterID)
    }

    func accept(_ value: Float, for handle: ParameterEditHandle, intentRevision: UInt64) -> Bool {
        guard let node = liveNode(handle), accepts(value, node: node, parameter: handle.parameterID) else {
            return false
        }
        let target = key(node, handle.parameterID)
        nextOrder &+= 1
        latestOrders[target] = nextOrder
        if let old = pending[target] {
            pending[target] = Pending(handle: handle, value: value, intentRevision: intentRevision,
                                      order: nextOrder, ticket: old.ticket)
        } else {
            enqueue(handle: handle, value: value, intentRevision: intentRevision, order: nextOrder, target: target)
        }
        return true
    }

    func commit(_ value: Float, for handle: ParameterEditHandle, intentRevision: UInt64) -> Bool {
        guard let node = liveNode(handle), accepts(value, node: node, parameter: handle.parameterID) else {
            return false
        }
        let target = key(node, handle.parameterID)
        nextOrder &+= 1
        latestOrders[target] = nextOrder
        invalidate(target)
        return attempt(node, parameter: handle.parameterID, value: value,
                       handle: handle, intentRevision: intentRevision).success
    }

    func pendingValue(for handle: ParameterEditHandle) -> Float? {
        guard let node = liveNode(handle) else { return nil }
        return pending[key(node, handle.parameterID)]?.value
    }

    fileprivate func successfulPresentation(for handle: ParameterEditHandle) -> ParameterSuccessfulPresentation? {
        discardStale()
        guard let node = liveNode(handle), let record = completed[key(node, handle.parameterID)],
              record.node === node, record.nodeID == node.id else { return nil }
        return record.success
    }

    func finish(_ handle: ParameterEditHandle) -> Bool {
        guard let node = liveNode(handle) else { return false }
        let target = key(node, handle.parameterID)
        while pending[target]?.handle === handle { drain(target) }
        return failures[target] == nil
    }

    func retire(_ handle: ParameterEditHandle) {
        guard handle.owner === self else { return }
        _ = finish(handle)
        handle.active = false
        handle.handler = nil
        // Rejections belong to the live target, not the disappearing consumer.
    }

    func applyImmediate(node: any EffectNode, parameter: String, value: Float) {
        nextOrder &+= 1
        let cutoff = nextOrder
        let target = key(node, parameter)
        let attemptedGeneration = generation
        let unattempted = pending[target]
        invalidate(target)
        let scopeStart = nextAttempt
        let result = attempt(node, parameter: parameter, value: value)
        guard generation == attemptedGeneration, isCurrent(node) else { return }
        // Any successful invocation begun in this scope supersedes captured
        // input, including inner success followed by outer rejection. Queue
        // admission order still protects genuinely newer pending intent.
        if let success = completed[target]?.success, success.operationOrder > scopeStart {
            if (latestOrders[target] ?? 0) <= cutoff { latestOrders[target] = cutoff }
            if let queued = pending[target], queued.order <= cutoff { invalidate(target) }
            // A direct write can leave the native scalar unchanged, so no model
            // echo will reconcile the cancelled optimistic drag. Acknowledge
            // its revision with THIS write's truthful outcome/readback. The
            // handle's separate success history reconciles nested operations.
            if let unattempted {
                acknowledge(unattempted.handle, intentRevision: unattempted.intentRevision,
                            requestedValue: value, result: result)
            }
        } else if let unattempted, pending[target] == nil,
                  latestOrders[target] == unattempted.order, liveNode(unattempted.handle) != nil {
            // Restore delivery of the previously accepted, UNATTEMPTED drag,
            // not the rejected immediate request. Old delivered ticks stay inert.
            enqueue(handle: unattempted.handle, value: unattempted.value,
                    intentRevision: unattempted.intentRevision, order: unattempted.order, target: target)
        }
    }

    func flushAll() -> Bool {
        discardStale()
        while !pending.isEmpty {
            let batch = pending.sorted { $0.value.order < $1.value.order }
            // Invalidate ALL scheduled deliveries before any native setter can
            // reenter acceptance, but keep unattempted entries discoverable for
            // immediate supersession and its scoped acknowledgement.
            for (target, entry) in batch {
                nextTicket &+= 1
                pending[target] = Pending(handle: entry.handle, value: entry.value,
                                          intentRevision: entry.intentRevision,
                                          order: entry.order, ticket: nextTicket)
            }
            // Newer reentrant intent belongs to a later ordered batch, not the
            // superseded entry's position in this one.
            for (target, entry) in batch where pending[target]?.order == entry.order {
                drain(target)
            }
            discardStale()
        }
        return failures.isEmpty
    }

    func invalidateGeneration() {
        generation &+= 1
        nextTicket &+= 1
        pending.removeAll()
        failures.removeAll()
        completed.removeAll()
        latestOrders.removeAll()
    }

    private func key(_ node: any EffectNode, _ parameter: String) -> Target {
        Target(object: ObjectIdentifier(node), parameter: parameter)
    }

    private func liveNode(_ handle: ParameterEditHandle) -> (any EffectNode)? {
        guard handle.owner === self, handle.active, handle.generation == generation,
              let node = handle.node, node.id == handle.nodeID, isCurrent(node),
              node.parameters.contains(where: { $0.identifier == handle.parameterID }) else { return nil }
        return node
    }

    private func accepts(_ value: Float, node: any EffectNode, parameter: String) -> Bool {
        value.isFinite && node.parameters.contains { $0.identifier == parameter && $0.range.contains(value) }
    }

    private func invalidate(_ target: Target) {
        nextTicket &+= 1
        pending.removeValue(forKey: target)
    }

    private func enqueue(handle: ParameterEditHandle, value: Float, intentRevision: UInt64,
                         order: UInt64, target: Target) {
        nextTicket &+= 1
        let ticket = nextTicket
        let scheduledGeneration = generation
        pending[target] = Pending(handle: handle, value: value, intentRevision: intentRevision,
                                  order: order, ticket: ticket)
        schedule { [weak self] in
            guard let self, self.generation == scheduledGeneration,
                  self.pending[target]?.ticket == ticket else { return }
            self.drain(target)
        }
    }

    private func drain(_ target: Target) {
        guard let entry = pending[target] else { return }
        invalidate(target)
        deliver(entry)
    }

    private func deliver(_ entry: Pending) {
        guard let node = liveNode(entry.handle),
              latestOrders[key(node, entry.handle.parameterID)] == entry.order else { return }
        _ = attempt(node, parameter: entry.handle.parameterID, value: entry.value,
                    handle: entry.handle, intentRevision: entry.intentRevision)
    }

    private func attempt(_ node: any EffectNode, parameter: String, value: Float,
                         handle: ParameterEditHandle? = nil, intentRevision: UInt64 = 0) -> ParameterApplication {
        discardStale()
        let target = key(node, parameter)
        let attemptedGeneration = generation
        let nodeID = node.id
        nextAttempt &+= 1
        let attemptID = nextAttempt
        let result = apply(node, parameter, value)
        if generation == attemptedGeneration, node.id == nodeID, isCurrent(node),
           node.parameters.contains(where: { $0.identifier == parameter }) {
            let record = completed[target] ?? Completed(node)
            completed[target] = record
            // An older outer success is useful after newer rejection, but
            // must never replace a newer successful inner operation.
            if result.success, attemptID > (record.success?.operationOrder ?? 0) {
                record.success = ParameterSuccessfulPresentation(
                    operationOrder: attemptID, value: result.actual ?? value
                )
            }
            // Completed outcome order, not unwind/callback order, owns the
            // persistent target failure independently of successful history.
            if attemptID > record.outcomeOrder {
                record.outcomeOrder = attemptID
                if result.success { failures.removeValue(forKey: target) }
                else { failures[target] = Failure(node) }
            }
        }
        if let handle {
            acknowledge(handle, intentRevision: intentRevision, requestedValue: value, result: result)
        }
        return result
    }

    private func acknowledge(_ handle: ParameterEditHandle, intentRevision: UInt64,
                             requestedValue: Float, result: ParameterApplication) {
        guard liveNode(handle) != nil else { return }
        applicationSerial &+= 1
        handle.handler?(ParameterApplicationResult(
            sessionID: handle.sessionID, intentRevision: intentRevision,
            applicationSerial: applicationSerial, requestedValue: requestedValue,
            actualValue: result.actual, outcome: result.success ? .applied : .rejected
        ))
    }

    private func discardStale() {
        pending = pending.filter { liveNode($0.value.handle) != nil }
        completed = completed.filter { target, record in
            guard let node = record.node, node.id == record.nodeID, isCurrent(node) else { return false }
            return node.parameters.contains { $0.identifier == target.parameter }
        }
        failures = failures.filter { target, failure in
            guard let node = failure.node, node.id == failure.nodeID, isCurrent(node) else { return false }
            return node.parameters.contains { $0.identifier == target.parameter }
        }
    }
}

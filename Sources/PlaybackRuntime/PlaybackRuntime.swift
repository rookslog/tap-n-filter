import Foundation

@MainActor
public final class PlaybackRuntime {
    private struct ActiveCapture {
        let session: any CaptureSession
        let lease: InputGuardLease
        let preparation: CapturePreparation
    }

    @MainActor
    private final class Record {
        var request: StartRequest?
        var operationID = UUID()
        var task: Task<LifecycleObservation, Never>?
        var isStartOperation = false
        var active: ActiveCapture?
        var preparation: (token: PlanToken, value: CapturePreparation)?
        var latest: LifecycleObservation?
        var sourceInvalidatedAt: UInt64?
        var formatInvalidatedAt: UInt64?
        var lastResolved: (epoch: UInt64, process: ResolvedProcess)?
        var lastFormat: (epoch: UInt64, format: StreamFormat)?
    }

    private let resolver: any ProcessResolving
    private let factory: any CaptureSessionFactory
    private let leases: InputGuardLeaseCoordinator
    private let observe: @MainActor (LifecycleObservation) -> Void
    private var records: [AssignmentID: Record] = [:]

    public init(resolver: any ProcessResolving, factory: any CaptureSessionFactory,
                leases: InputGuardLeaseCoordinator,
                observe: @escaping @MainActor (LifecycleObservation) -> Void = { _ in }) {
        self.resolver = resolver
        self.factory = factory
        self.leases = leases
        self.observe = observe
    }

    public func observation(for assignment: AssignmentID) -> LifecycleObservation? {
        records[assignment]?.latest
    }

    public func resource(for assignment: AssignmentID, matching token: PlanToken) -> (any CaptureResource)? {
        guard let record = records[assignment], record.request?.token == token,
              let preparation = record.preparation, preparation.token == token else { return nil }
        switch record.latest?.event {
        case .prepared, .starting, .running: return preparation.value.resource
        case let .condition(condition) where !condition.isTerminal: return preparation.value.resource
        default: return nil
        }
    }

    public func start(_ request: StartRequest) async -> LifecycleObservation {
        if Task.isCancelled {
            return publish(LifecycleObservation(assignment: request.assignment, token: request.token,
                                                event: .stopped(.cancelled, nil, nil)))
        }
        let record = records[request.assignment] ?? Record()
        records[request.assignment] = record
        if let old = record.request {
            if request.token.isOlder(than: old.token) {
                return refusal(request, .staleToken)
            }
            if request.token == old.token, request != old {
                return refusal(request, .conflictingEqualToken)
            }
            if let invalidated = record.sourceInvalidatedAt, request.token.source <= invalidated {
                return refusal(request, .sourceEpochRequired)
            }
            if let invalidated = record.formatInvalidatedAt, request.token.format <= invalidated {
                return refusal(request, .formatEpochRequired)
            }
            if request.token.source == old.token.source,
               request.binding != old.binding || request.preferredPID != old.preferredPID {
                return refusal(request, .sourceEpochRequired)
            }
            if request.token.format == old.token.format, request.expectedFormat != old.expectedFormat {
                return refusal(request, .formatEpochRequired)
            }
            if request == old, record.isStartOperation, let task = record.task {
                return await awaitStart(task, record: record, operationID: record.operationID,
                                        assignment: request.assignment)
            }
            if record.task == nil, let active = record.active, request.binding == old.binding,
               request.preferredPID == old.preferredPID, request.expectedFormat == old.expectedFormat,
               request.token.source == old.token.source, request.token.format == old.token.format {
                if request != old { record.operationID = UUID() }
                record.request = request
                record.preparation = (request.token, active.preparation)
                return emit(record, request.assignment, request.token, .running(active.preparation.format))
            }
        }
        let previous = record.task
        previous?.cancel()
        let operationID = UUID()
        record.operationID = operationID
        record.request = request
        record.isStartOperation = true
        emit(record, request.assignment, request.token, .queued)
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.drainActive(record)
            return await self.runStart(request, record: record, operationID: operationID)
        }
        record.task = task
        return await awaitStart(task, record: record, operationID: operationID, assignment: request.assignment)
    }

    public func stop(_ assignment: AssignmentID) async -> LifecycleObservation {
        await stop(assignment, reason: .explicit)
    }

    public func report(condition: CaptureCondition, for assignment: AssignmentID,
                       matching token: PlanToken) async -> LifecycleObservation {
        guard let record = records[assignment], record.request?.token == token else {
            return publish(LifecycleObservation(assignment: assignment, token: token, event: .refused(.staleToken)))
        }
        let active = record.active != nil && record.task == nil
        let preparing = record.isStartOperation && record.task != nil
        guard active || (condition.isTerminal && preparing) else {
            return publish(LifecycleObservation(assignment: assignment, token: token, event: .refused(.notRunning)))
        }
        let observation = emit(record, assignment, token, .condition(condition))
        if !condition.isTerminal { return observation }
        switch condition {
        case .sourceDisappeared, .sourceReplaced: record.sourceInvalidatedAt = token.source
        case .formatChanged: record.formatInvalidatedAt = token.format
        default: break
        }
        return await stop(assignment, reason: .condition(condition))
    }

    public func stopAll() async -> [LifecycleObservation] {
        var results: [LifecycleObservation] = []
        for assignment in Array(records.keys) { results.append(await stop(assignment)) }
        return results
    }

    private func stop(_ assignment: AssignmentID, reason: StopReason) async -> LifecycleObservation {
        let record = records[assignment] ?? Record()
        records[assignment] = record
        let previous = record.task
        let stoppingToken = record.request?.token
        previous?.cancel()
        let operationID = UUID()
        record.operationID = operationID
        record.isStartOperation = false
        emit(record, assignment, stoppingToken, .stopping(reason))
        let task = Task { @MainActor in
            let previousResult = await previous?.value
            let (teardown, release) = await self.drainActive(record)
            let inherited: (TeardownOutcome?, LeaseRelease?)
            switch previousResult?.event {
            case let .stopped(_, previousTeardown, previousRelease), let .failed(_, previousTeardown, previousRelease):
                inherited = (previousTeardown, previousRelease)
            default: inherited = (nil, nil)
            }
            let result = LifecycleObservation(assignment: assignment, token: stoppingToken,
                                              event: .stopped(reason, teardown ?? inherited.0, release ?? inherited.1))
            if record.operationID == operationID {
                record.task = nil
                record.preparation = nil
                return self.emit(record, assignment, result.token, result.event)
            }
            return result
        }
        record.task = task
        return await task.value
    }

    private func runStart(_ request: StartRequest, record: Record,
                          operationID: UUID) async -> LifecycleObservation {
        var session: (any CaptureSession)?
        var lease: InputGuardLease?
        var stage: RuntimeStage = .resolve
        do {
            try checkCurrent(record, operationID)
            emit(record, request.assignment, request.token, .resolving)
            let process = try await resolver.resolve(binding: request.binding, preferredPID: request.preferredPID)
            try checkCurrent(record, operationID)
            guard process.binding == request.binding, process.pid > 0, process.audioProcessID != 0 else {
                throw SourceResolutionError.replaced
            }
            if let old = record.lastResolved, old.epoch == request.token.source,
               old.process.binding != process.binding || old.process.pid != process.pid
                || old.process.audioProcessID != process.audioProcessID
                || old.process.instanceIdentifier != process.instanceIdentifier {
                throw SourceResolutionError.replaced
            }
            record.lastResolved = (request.token.source, process)
            emit(record, request.assignment, request.token, .resolved(process))
            emit(record, request.assignment, request.token, .guarding)
            let acquisition = await leases.acquire()
            lease = acquisition.lease
            try checkCurrent(record, operationID)
            emit(record, request.assignment, request.token, .guardReady(acquisition.observation))
            try await resolver.revalidate(process)
            try checkCurrent(record, operationID)
            stage = .prepare
            let created = factory.makeSession()
            session = created
            emit(record, request.assignment, request.token, .preparing)
            let preparation = try await created.prepare(source: process)
            try checkCurrent(record, operationID)
            if let expected = request.expectedFormat, expected != preparation.format {
                throw RuntimeFailure.formatMismatch(expected: expected, actual: preparation.format)
            }
            if let old = record.lastFormat, old.epoch == request.token.format, old.format != preparation.format {
                throw RuntimeFailure.formatMismatch(expected: old.format, actual: preparation.format)
            }
            record.lastFormat = (request.token.format, preparation.format)
            record.preparation = (request.token, preparation)
            emit(record, request.assignment, request.token, .prepared(preparation.format))
            try await resolver.revalidate(process)
            try checkCurrent(record, operationID)
            stage = .start
            emit(record, request.assignment, request.token, .starting)
            try await created.start()
            try checkCurrent(record, operationID)
            record.active = ActiveCapture(session: created, lease: acquisition.lease, preparation: preparation)
            record.task = nil
            return emit(record, request.assignment, request.token, .running(preparation.format))
        } catch {
            let teardown = await session?.stop()
            if record.preparation?.token == request.token { record.preparation = nil }
            let release: LeaseRelease?
            if let lease { release = await leases.release(lease) } else { release = nil }
            let event: LifecycleEvent
            if error is CancellationError || record.operationID != operationID {
                event = .stopped(record.operationID == operationID ? .cancelled : .superseded, teardown, release)
            } else if let failure = error as? RuntimeFailure {
                event = .failed(failure, teardown, release)
            } else if let failure = error as? SourceResolutionError {
                event = .failed(.source(failure), teardown, release)
            } else {
                let message = String(describing: error)
                let failure: RuntimeFailure
                switch stage {
                case .resolve: failure = .source(.lookupFailed(message))
                case .prepare: failure = .prepare(message)
                case .start: failure = .start(message)
                }
                event = .failed(failure, teardown, release)
            }
            let result = LifecycleObservation(assignment: request.assignment, token: request.token, event: event)
            if record.operationID == operationID {
                record.task = nil
                record.preparation = nil
                return emit(record, request.assignment, request.token, event)
            }
            return result
        }
    }

    private enum RuntimeStage { case resolve, prepare, start }

    private func checkCurrent(_ record: Record, _ operationID: UUID) throws {
        try Task.checkCancellation()
        guard record.operationID == operationID else { throw CancellationError() }
    }

    @discardableResult
    private func drainActive(_ record: Record) async -> (TeardownOutcome?, LeaseRelease?) {
        guard let active = record.active else { return (nil, nil) }
        record.active = nil
        let teardown = await active.session.stop()
        let release = await leases.release(active.lease)
        record.preparation = nil
        return (teardown, release)
    }

    private func awaitStart(_ task: Task<LifecycleObservation, Never>, record: Record,
                            operationID: UUID, assignment: AssignmentID) async -> LifecycleObservation {
        await withTaskCancellationHandler {
            if Task.isCancelled { task.cancel() }
            return await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor in
                if record.operationID == operationID {
                    _ = await self.stop(assignment, reason: .cancelled)
                }
            }
        }
    }

    private func refusal(_ request: StartRequest, _ refusal: Refusal) -> LifecycleObservation {
        publish(LifecycleObservation(assignment: request.assignment, token: request.token, event: .refused(refusal)))
    }

    @discardableResult
    private func emit(_ record: Record, _ assignment: AssignmentID, _ token: PlanToken?,
                      _ event: LifecycleEvent) -> LifecycleObservation {
        let observation = LifecycleObservation(assignment: assignment, token: token, event: event)
        record.latest = observation
        return publish(observation)
    }

    private func publish(_ observation: LifecycleObservation) -> LifecycleObservation {
        observe(observation)
        return observation
    }
}

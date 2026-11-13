import Foundation
import SoundModel
import EverydayMenu
import PlaybackRenderBridge

// No App/path/capture policy here. Later composition supplies a real pure mapper admission port.
enum LibraryConsumerStartup: Equatable {
    case starting, existing, fresh
    case migrated(LibraryMigrationReceipt)
    case refused(LibraryOpenFailure)
    case unresolved(LibraryMigrationReceipt, String)
    case freshPreparationFailed(LibraryFreshPreparationFailure)
}
enum LibraryConsumerCommandOutcome: Equatable, Sendable {
    case accepted(LibraryCommit)
    case refused(LibraryCommit)
    case unresolved(LibraryCommit)
    case blocked(UUID?)
    case failed(String)
    case rejected(LibraryConsumerLifecycle)
    case cancelled
}
struct LibraryConsumerCommandResult: Equatable, Sendable {
    let command: UUID
    let outcome: LibraryConsumerCommandOutcome
    var creation: LibraryCreationResult? = nil
    var publication: LibraryUpdateResult? = nil
}
enum LibraryConsumerReconciliation: Equatable {
    case idle
    case inFlight(UUID?)
    case accepted(command: UUID, commit: UUID)
    case refused(command: UUID, commit: UUID, reason: LibraryWriteRefusal)
    case unresolved(UUID?, String)
    case superseded
}
enum LibraryDeliveryMode { case activation, positions }

struct LibraryConsumerPublication {
    let generation: UInt64
    let presentation: LibraryMenuState
    let positionContext: MenuPositionContext
    let menu: MenuLibraryProjection
    let admissionFailure: String?
}
enum LibraryConsumerLifecycle: Equatable { case running, draining, closed }
enum LibraryConsumerLifecycleError: Error { case unavailable(LibraryConsumerLifecycle), notReady }
enum LibraryDrainMode: Equatable { case save, discard }
enum LibraryDrainResult: Equatable {
    case saved(LibraryCommit)
    case refused(LibraryCommit)
    case unresolved(UUID?, String)
    case blocked(UUID?)
    case startupUnavailable(LibraryConsumerStartup?)
    case failed(String)
    case discarded
    case cancelled
    case closed
}

enum LibraryConsumerEvent {
    case startup(LibraryConsumerStartup)
    case state(LibraryConsumerPublication)
    case positionContext(MenuPositionContext)
    case command(LibraryConsumerCommandResult)
    case reconciliation(LibraryConsumerReconciliation)
    case readFailure(String)
    case lifecycle(LibraryConsumerLifecycle)
    case editor(LibraryEditorState)
    case editorMutation(UUID)
    case creationAccepted(command: UUID, commit: UUID, reference: LibraryReference)

    /// The sole roster receipt adapter; async returned command results are not a second UI path.
    var rosterReceipt: LibraryRosterReceipt? {
        switch self {
        case .command(let result):
            switch result.outcome {
            case .accepted(let receipt): return .accepted(command: result.command, commit: receipt.token)
            case .unresolved(let receipt): return .unresolved(command: result.command, commit: receipt.token)
            case .refused(let receipt):
                guard case .refused(let reason) = receipt.outcome else { return nil }
                return .refused(command: result.command, commit: receipt.token, reason: reason)
            case .blocked: return .blocked(command: result.command)
            case .failed, .rejected, .cancelled: return .failed(command: result.command)
            }
        case .reconciliation(.accepted(let command, let commit)):
            return .reconciled(command: command, commit: commit, accepted: true)
        case .reconciliation(.refused(let command, let commit, _)):
            return .reconciled(command: command, commit: commit, accepted: false)
        default: return nil
        }
    }
}

@MainActor
private final class LibraryCommandCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var value: Void {
        get async { if !finished { await withCheckedContinuation { waiters.append($0) } } }
    }
    func finish() {
        finished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Single application-side owner. Accepted publications and apply calls are synchronous MainActor effects.
@MainActor
final class LibraryListeningCoordinator {
    typealias Move = @MainActor @Sendable (SoundLibrarySession, LibraryControlAddress, LibraryBinding, LibraryOptionGesture?, LibraryPosition) async throws -> LibraryLiveMutation
    typealias FreshPreparation = @Sendable (SoundLibrarySession) async -> LibraryFreshPreparationResult
    typealias EditRead = @Sendable (SoundLibrarySession, LibraryEditHandle) async throws -> LibraryEditSnapshot
    typealias Read = @Sendable (SoundLibrarySession) async throws -> LibraryMenuState
    private let publish: (LibraryConsumerEvent) -> Void
    private let admit: (ListeningRenderSnapshot) throws -> Void
    private var apply: ((ListeningRenderSnapshot, Bool, LibraryDeliveryMode) -> Void)?
    private let read: Read
    private let editRead: EditRead
    private var session: SoundLibrarySession?
    private var started = false
    private var startupTask: Task<Void, Never>?
    private var startupPending = false
    private var openingOwner: SoundLibrarySession?
    private var startupStatus: LibraryConsumerStartup?
    private var startupOff = false
    private var startupRelease = false
    private(set) var lifecycle = LibraryConsumerLifecycle.running
    private var drainTask: Task<LibraryDrainResult, Never>?
    private var discardRequested = false
    private var liveSequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var liveTail: LibraryCommandCompletion?
    private var structuralTail: LibraryCommandCompletion?
    private var structuralActive: UUID?
    private var pending: (command: UUID, commit: UUID, creation: LibraryCreationResult?, publication: Bool)?
    private var refreshTask: Task<Void, Never>?
    private var refreshWanted = false
    private var refreshMode = LibraryDeliveryMode.positions
    private(set) var presentation: LibraryMenuState?
    private(set) var positionContext: MenuPositionContext?
    private var deliveryEpoch: UInt64 = 0
    private(set) var fullReadAttempts: UInt64 = 0
    private let publishPositions: (LibraryMenuDelta, MenuPositionContext) -> Bool
    private let menuMoveOverride: MenuMove?
    typealias MenuMove = @MainActor @Sendable (SoundLibrarySession, LibraryControlAddress, LibraryMenuIdentity, LibraryOptionGesture?, LibraryPosition) async throws -> LibraryMenuMoveResult
    private var sliderBatch: LibrarySliderBatch?
    private var checkpointAdmissions = 0
    private var editorReaders = 0
    private var checkpointGestureContext: MenuPositionContext?
    private var menuGestureContext: MenuPositionContext?
    private var menuGestureIdentity: UUID?
    private var parameterEnabled = false
    private var parameterGesture: LibraryParameterGesture?
    var perfParameterEvaluated: ((Double, LibraryPosition) -> Void)?
    var perfParameterDocumentCommit: ((LibraryLiveMutation) -> Void)?
    func beginParameterGesture(identity: UUID? = nil) {
        sealSliderMoves()
        menuGestureIdentity = identity
        menuGestureContext = identity == nil ? nil : positionContext ?? checkpointGestureContext
        parameterEnabled = true
    }
    @discardableResult
    private func commitParameter(_ owner: SoundLibrarySession) async throws -> LibraryLiveMutation? {
        guard let gesture = parameterGesture else { return nil }
        parameterGesture = nil
        guard let latest = gesture.latest else { return nil }
        let result = try await executeMenuOrdered(owner, address: gesture.plan.address,
            expected: gesture.plan.identity, option: gesture.plan.option, value: latest)
        perfParameterDocumentCommit?(result.outcome)
        editor.invalidateCoverage()
        return result.outcome
    }
    private func evaluateParameter(_ owner: SoundLibrarySession, address: LibraryControlAddress,
        identity: LibraryMenuIdentity, option: LibraryOptionGesture?, value: LibraryPosition, epoch: UInt64) async throws -> LibrarySliderResult {
        if let current = parameterGesture,
           current.plan.identity != identity || current.plan.address != address || current.plan.option != option {
            try await commitParameter(owner)
            _ = await refresh(mode: .positions)
        }
        if parameterGesture == nil {
            guard let plan = presentation?.parameterPlans.first(where: { $0.identity == identity && $0.address == address && $0.option == option }), plan.lease.isValid else {
                return .executed(try await executeMenuOrdered(owner, address: address, expected: identity, option: option, value: value).outcome)
            }
            parameterGesture = LibraryParameterGesture(plan, epoch: epoch)
        }
        guard let gesture = parameterGesture else { return .executed(.superseded) }
        gesture.latest = value
        let started = ProcessInfo.processInfo.systemUptime
        guard let delta = try gesture.plan.evaluate(value) else {
            let outcome = try await commitParameter(owner) ?? .superseded
            invalidatePositionDelivery()
            return .executed(outcome)
        }
        guard epoch == deliveryEpoch, let context = positionContext,
              let candidate = presentation?.applying(delta) else { return .fenced(.noChange) }
        let delivered = try gesture.plan.lease.ifValid {
            let transport = ListeningRenderSnapshot(menu: candidate)
            try admit(transport)
            guard publishPositions(delta, context) else { return false }
            presentation = candidate
            deliver(transport, compare: candidate.compareOriginal, mode: .positions)
            return true
        } ?? false
        guard delivered else { invalidatePositionDelivery(); return .fenced(.superseded) }
        perfParameterEvaluated?(ProcessInfo.processInfo.systemUptime - started, value)
        return .live
    }
    private var sliderEligibility: [LibrarySliderEligibility] = []
    private var sliderEligibilityBarriers = 0
    private let moveOverride: Move?
    var perfMoveExecuted: ((LibraryMoveMeasurement, LibraryPosition) -> Void)?
    var perfSliderCoalesced: (() -> Void)?
    var perfSliderQueueChanged: ((Int, Int) -> Void)?
    lazy var editor = LibraryEditorAdapter(coordinator: self)
    var readyForEditing: Bool { lifecycle == .running && session != nil }
    private var applied: (snapshot: ListeningRenderSnapshot, compare: Bool)?

    init(publish: @escaping (LibraryConsumerEvent) -> Void,
         admit: @escaping (ListeningRenderSnapshot) throws -> Void = RenderAssignmentMapper.admitCapabilities,
         apply: ((ListeningRenderSnapshot, Bool, LibraryDeliveryMode) -> Void)? = nil,
         read: @escaping Read = { try await $0.menuState() },
         editRead: @escaping EditRead = { try await $0.inspectEdit($1) },
         move: Move? = nil,
         menuMove: MenuMove? = nil,
         positions: @escaping (LibraryMenuDelta, MenuPositionContext) -> Bool = { _, _ in true }) {
        moveOverride = move; menuMoveOverride = menuMove; publishPositions = positions
        self.editRead = editRead
        self.publish = publish; self.admit = admit; self.apply = apply; self.read = read
    }
    func beginEdit(_ target: LibraryEditTarget) async throws -> LibraryEditSnapshot {
        guard lifecycle == .running else { throw LibraryConsumerLifecycleError.unavailable(lifecycle) }
        guard let session else { throw LibraryConsumerLifecycleError.notReady }
        invalidatePositionDelivery()
        await joinLive()
        try await commitParameter(session)
        return try await session.beginEdit(target, admission: RenderAssignmentMapper.admitParts)
    }
    func start(persistence: any LibraryPersistence, limits: LibraryLimits,
               migrationSource: LibraryMigrationSource? = nil,
               freshPreparation: FreshPreparation? = nil, builtins: LibraryBuiltinSet = .standard) async {
        guard !started, lifecycle == .running else { return }
        started = true; startupPending = true; emit(.startup(.starting))
        let task = Task { @MainActor in
            let result = await SoundLibrarySession.open(persistence: persistence, limits: limits, migrationSource: migrationSource, builtins: builtins)
            let status: LibraryConsumerStartup
            switch result {
            case .existing(let owner):
                openingOwner = owner
                await applyStartupEmergency(owner)
                await joinLive()
                session = owner; status = .existing
            case .fresh(let owner):
                openingOwner = owner
                await applyStartupEmergency(owner)
                if let freshPreparation {
                    switch await freshPreparation(owner) {
                    case .prepared(let receipt):
                        await applyStartupEmergency(owner)
                        await joinLive()
                        do {
                            guard try await owner.saveCoverage().isSaved else {
                                let failure = LibraryConsumerStartup.freshPreparationFailed(.invalidSeed(receipt))
                                startupStatus = failure; openingOwner = nil; startupPending = false
                                emit(.startup(failure)); return
                            }
                            session = owner; status = .fresh
                        } catch { status = .freshPreparationFailed(.failure(String(describing: error))) }
                    case .failed(let reason): status = .freshPreparationFailed(reason)
                    }
                } else {
                    await joinLive()
                    session = owner; status = .fresh
                }
            case .migrated(let owner, let receipt):
                openingOwner = owner
                await applyStartupEmergency(owner)
                await joinLive()
                session = owner; status = .migrated(receipt)
            case .refused(let reason): status = .refused(reason)
            case .unresolved(let receipt, let detail): status = .unresolved(receipt, detail)
            }
            openingOwner = nil; startupStatus = status; startupPending = false
            emit(.startup(status))
        }
        startupTask = task
        await task.value
        await refresh()
    }
    private func applyStartupEmergency(_ owner: SoundLibrarySession) async {
        if startupOff { await owner.setEnabled(false) }
        if startupRelease { await owner.compareOriginal(false) }
    }
    private func emit(_ event: LibraryConsumerEvent) {
        guard lifecycle != .closed else { return }
        publish(event)
    }
    private func invalidate() { generation += 1 }
    private func deliver(_ snapshot: ListeningRenderSnapshot, compare: Bool, mode: LibraryDeliveryMode) {
        guard lifecycle != .closed, let apply,
              applied?.snapshot != snapshot || applied?.compare != compare else { return }
        applied = (snapshot, compare); apply(snapshot, compare, mode)
    }
    /// Attach only a real synchronous consumer. Never replay an inactive startup intent.
    @discardableResult
    func attachPlayback(_ port: @escaping (ListeningRenderSnapshot, Bool, LibraryDeliveryMode) -> Void) async -> Bool {
        guard lifecycle == .running, session != nil, apply == nil else { return false }
        await joinLive()
        guard lifecycle == .running else { return false }
        invalidate()
        apply = port
        await refresh()
        return lifecycle == .running
    }
    private func restrict(_ live: LibraryLiveState) {
        if let applied { deliver(applied.snapshot.restricting(to: live), compare: live.compareOriginal, mode: .positions) }
    }
    /// Read initiation order fences completions; command completions always request a new read.
    @discardableResult
    func refresh(mode: LibraryDeliveryMode = .activation) async -> Bool {
        guard lifecycle == .running, let session else { return false }
        invalidate(); let requested = generation
        do {
            fullReadAttempts &+= 1
            let snapshot = try await read(session)
            guard requested == generation else { return false }
            let transport = ListeningRenderSnapshot(menu: snapshot)
            let failure: String?
            do { try admit(transport); failure = nil }
            catch { failure = String(describing: error) }
            if failure == nil && sliderEligibilityBarriers == 0 { deliver(transport, compare: snapshot.compareOriginal, mode: mode) }
            else {
                let live = try await session.liveState()
                guard requested == generation else { return false }
                restrict(live)
            }
            presentation = snapshot
            if checkpointAdmissions == 0 && !snapshot.writing { checkpointGestureContext = nil }
            let context = MenuPositionContext(presentation: snapshot, epoch: deliveryEpoch)
            positionContext = context
            installSliderEligibility(snapshot, admitted: failure == nil)
            emit(.state(LibraryConsumerPublication(generation: requested, presentation: snapshot, positionContext: context,
                menu: MenuLibraryProjection(snapshot), admissionFailure: failure)))
            return true
        } catch {
            guard requested == generation else { return false }
            sliderEligibility = []
            if let live = try? await session.liveState(), requested == generation { restrict(live) }
            guard requested == generation else { return false }
            emit(.readFailure(String(describing: error)))
            return false
        }
    }
    /// Only the mutation + cheap status read are ordered. Neither disk nor the full projection is on this tail.
    func enqueueMutation<Value: Sendable>(allowDuringDrain: Bool = false, statusAfterOperation: Bool = true,
        preservingSliderEligibility: Bool = false, preservingGestureAdmission: Bool = false,
        _ operation: @escaping @MainActor @Sendable (SoundLibrarySession) async throws -> Value) throws -> Task<Value, Error> {
        guard lifecycle != .closed, lifecycle != .draining || allowDuringDrain else {
            throw LibraryConsumerLifecycleError.unavailable(lifecycle)
        }
        guard let session = session ?? (allowDuringDrain ? openingOwner : nil) else {
            throw LibraryConsumerLifecycleError.notReady
        }
        if preservingSliderEligibility { sealSliderMoves() }
        else { beginSliderEligibilityBarrier(preservingGestureAdmission: preservingGestureAdmission) }
        liveSequence += 1
        invalidate()
        let previous = liveTail, completion = LibraryCommandCompletion()
        liveTail = completion
        let task = Task { @MainActor in
            defer {
                if !preservingSliderEligibility { endSliderEligibilityBarrier() }
                completion.finish()
            }
            await previous?.value
            let result: Value
            do {
                if !preservingSliderEligibility { try await self.commitParameter(session) }
                result = try await operation(session)
            }
            catch { invalidate(); throw error }
            if statusAfterOperation { try await mutationStatus(session) }
            return result
        }
        return task
    }
    private func mutationStatus(_ session: SoundLibrarySession) async throws {
        invalidate()
        editor.invalidateCoverage()
        let live = try await session.liveState()
        invalidate()
        restrict(live)
    }
    private func scheduleLive(allowDuringDrain: Bool = false,
        _ operation: @escaping @Sendable (SoundLibrarySession) async throws -> LibraryLiveMutation) throws -> Task<LibraryLiveMutation, Error> {
        try enqueueMutation(allowDuringDrain: allowDuringDrain, operation)
    }
    func publishEditor(_ state: LibraryEditorState) { emit(.editor(state)) }
    func editorAcknowledged(_ command: UUID) { emit(.editorMutation(command)) }
    private func beginEditorRead() {
        if editorReaders == 0 { invalidatePositionDelivery() }
        else { sealSliderMoves() }
        editorReaders += 1
    }
    private func finishEditorRead(_ owner: SoundLibrarySession?) async {
        editorReaders -= 1
        guard editorReaders == 0, lifecycle == .running, let owner else { return }
        let expected = generation
        do {
            fullReadAttempts &+= 1
            let snapshot = try await read(owner)
            guard editorReaders == 0, expected == generation else { return }
            let transport = ListeningRenderSnapshot(menu: snapshot)
            try admit(transport)
            if sliderEligibilityBarriers == 0 { deliver(transport, compare: snapshot.compareOriginal, mode: .positions) }
            else { restrict(snapshot.live) }
            let unchanged = presentation == snapshot
            presentation = snapshot
            let context = MenuPositionContext(presentation: snapshot, epoch: deliveryEpoch)
            positionContext = context
            if checkpointAdmissions == 0 && !snapshot.writing { checkpointGestureContext = nil }
            installSliderEligibility(snapshot, admitted: true)
            if unchanged { emit(.positionContext(context)) }
            else { emit(.state(LibraryConsumerPublication(generation: expected, presentation: snapshot, positionContext: context,
                menu: MenuLibraryProjection(snapshot), admissionFailure: nil))) }
        } catch { emit(.readFailure(String(describing: error))) }
    }
    func editorRead(_ handle: LibraryEditHandle) async throws -> (LibraryEditSnapshot, LibrarySaveCoverage) {
        beginEditorRead()
        do {
            await joinLive()
            guard lifecycle != .closed, let session else { throw LibraryConsumerLifecycleError.notReady }
            try await commitParameter(session)
            let result = try await (editRead(session, handle), session.saveCoverage())
            await finishEditorRead(session)
            return result
        } catch { await finishEditorRead(session); throw error }
    }
    func editorInspect(_ owner: SoundLibrarySession, _ handle: LibraryEditHandle) async throws -> LibraryEditSnapshot {
        try await editRead(owner, handle)
    }
    func editorObservationIsCurrent(_ version: UInt64) -> Bool { lifecycle == .running && generation == version }
    func editorQuery<Value: Sendable>(_ operation: @Sendable (SoundLibrarySession) async throws -> Value) async throws -> (Value, UInt64) {
        beginEditorRead()
        do {
            await joinLive()
            guard lifecycle == .running, let session else { throw LibraryConsumerLifecycleError.unavailable(lifecycle) }
            try await commitParameter(session)
            let version = generation
            let result = try await operation(session)
            await finishEditorRead(session)
            return (result, version)
        } catch { await finishEditorRead(session); throw error }
    }
    func cancelEditorPreview(_ preview: LibraryUpdatePreview) async { await session?.cancelUpdateLibrary(preview) }
    func requestRefresh(mode: LibraryDeliveryMode = .activation) {
        refreshWanted = true
        if mode == .activation { refreshMode = .activation }
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            repeat {
                refreshWanted = false
                let mode = refreshMode; refreshMode = .positions
                await refresh(mode: mode)
            } while refreshWanted && lifecycle == .running
            refreshTask = nil
        }
    }
    private func installSliderEligibility(_ snapshot: LibraryMenuState, admitted: Bool) {
        sliderEligibility = []
        guard admitted, sliderEligibilityBarriers == 0, !snapshot.writing, !snapshot.unresolved else { return }
        for assignment in snapshot.assignments {
            guard let use = snapshot.uses.first(where: { $0.id == assignment.use }), use.builtin != nil,
                  !use.hasLocalDraft, let direct = use.directSliderControls else { continue }
            let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
            for address in direct {
                let relations = use.optionControls.filter { $0.child == address }
                if relations.isEmpty {
                    sliderEligibility.append(LibrarySliderEligibility(binding: binding, address: address, option: nil))
                } else {
                    for relation in relations where relation.isActive {
                        sliderEligibility.append(LibrarySliderEligibility(binding: binding, address: address,
                            option: LibraryOptionGesture(parent: relation.parent, option: relation.option)))
                    }
                }
            }
        }
    }
    func sliderCanCoalesce(_ address: LibraryControlAddress, expected: LibraryBinding,
                           optionGesture: LibraryOptionGesture? = nil) -> Bool {
        lifecycle == .running && sliderEligibilityBarriers == 0 && sliderEligibility.contains(
            LibrarySliderEligibility(binding: expected, address: address, option: optionGesture))
    }
    private func beginSliderEligibilityBarrier(preservingGestureAdmission: Bool = false) {
        invalidatePositionDelivery(preservingGestureAdmission: preservingGestureAdmission)
        sliderEligibility = []
        sliderEligibilityBarriers += 1
        invalidate()
    }
    private func endSliderEligibilityBarrier() {
        sliderEligibilityBarriers -= 1
        sliderEligibility = []
        invalidate()
    }
    func invalidatePositionDelivery(preservingGestureAdmission: Bool = false) {
        if !preservingGestureAdmission {
            checkpointGestureContext = nil
            menuGestureContext = nil
            menuGestureIdentity = nil
        }
        parameterEnabled = false
        deliveryEpoch &+= 1
        invalidate()
        positionContext = nil
        sealSliderMoves()
        sliderEligibility = []
    }
    func playbackDidChange() {
        invalidatePositionDelivery()
        Task { @MainActor in
            await joinLive()
            do { if let session { try await commitParameter(session) } }
            catch { emit(.readFailure(String(describing: error))) }
            requestRefresh(mode: .positions)
        }
    }
    func sealSliderMoves() {
        sliderBatch?.accepting = false
        sliderBatch = nil
    }
    private func executeMove(_ session: SoundLibrarySession, address: LibraryControlAddress, binding: LibraryBinding,
                             option: LibraryOptionGesture?, position: LibraryPosition) async throws -> LibraryLiveMutation {
        if let moveOverride { return try await moveOverride(session, address, binding, option, position) }
        if perfMoveExecuted != nil {
            let measured = try await session.measuredMove(address, expected: binding, optionGesture: option, to: position)
            perfMoveExecuted?(measured, position)
            return measured.outcome
        }
        if let option { return try await session.move(address, expected: binding, optionGesture: option, to: position) }
        return try await session.move(address, expected: binding, to: position)
    }
    private func acceptsMenuEpoch(_ expected: UInt64?, gestureIdentity: UUID?) -> Bool {
        if let gestureIdentity {
            return gestureIdentity == menuGestureIdentity && expected != nil
                && (expected == positionContext?.epoch || expected == menuGestureContext?.epoch)
        }
        return expected == nil || expected == positionContext?.epoch
    }
    func submitSliderMove(_ address: LibraryControlAddress, expected: LibraryBinding, to value: LibraryPosition,
                          optionGesture: LibraryOptionGesture? = nil, menuIdentity: LibraryMenuIdentity? = nil, expectedEpoch: UInt64? = nil, gestureIdentity: UUID? = nil) throws -> Task<LibrarySliderResult, Error> {
        guard lifecycle == .running else { throw LibraryConsumerLifecycleError.unavailable(lifecycle) }
        guard session != nil else { throw LibraryConsumerLifecycleError.notReady }
        guard acceptsMenuEpoch(expectedEpoch, gestureIdentity: gestureIdentity) else { return Task { .executed(.superseded) } }
        if let menuIdentity, presentation?.identity(for: expected) != menuIdentity {
            return Task { .executed(.superseded) }
        }
        guard sliderCanCoalesce(address, expected: expected, optionGesture: optionGesture) else {
            let ordered: Task<LibraryLiveMutation, Error>
            if let menuIdentity {
                ordered = try enqueueMutation(preservingGestureAdmission: gestureIdentity != nil && gestureIdentity == menuGestureIdentity) { session in
                    try await self.executeMenuOrdered(session, address: address, expected: menuIdentity,
                        option: optionGesture, value: value).outcome
                }
            } else {
                ordered = try submitMove(address, expected: expected, to: value, optionGesture: optionGesture)
            }
            return Task { .executed(try await ordered.value) }
        }
        let request = LibrarySliderRequest(value)
        if let batch = sliderBatch, batch.matches(expected, address, optionGesture, identity: menuIdentity) {
            liveSequence += 1; invalidate()
            if batch.pending != nil { perfSliderCoalesced?() }
            batch.replace(request)
            perfSliderQueueChanged?(batch.inFlight ? 1 : 0, 1)
        } else {
            let batch = LibrarySliderBatch(binding: expected, address: address, option: optionGesture, identity: menuIdentity, request: request)
            // enqueueMutation seals the previous segment before installing this one's tail.
            let epoch = deliveryEpoch
            let identity = menuIdentity ?? presentation?.identity(for: expected)
            _ = try enqueueMutation(statusAfterOperation: false, preservingSliderEligibility: true) { session in
                defer { if self.sliderBatch === batch { self.sliderBatch = nil } }
                while let next = batch.take() {
                    batch.inFlight = true
                    self.perfSliderQueueChanged?(1, batch.pending == nil ? 0 : 1)
                    do {
                        let result: LibrarySliderResult
                        if let identity, self.moveOverride == nil, self.parameterEnabled || self.parameterGesture != nil {
                            result = try await self.evaluateParameter(session, address: batch.address, identity: identity,
                                option: batch.option, value: next.position, epoch: epoch)
                        } else if let identity, self.moveOverride == nil {
                            let value = try await self.executeMenuOrdered(session, address: batch.address,
                                expected: identity, option: batch.option, value: next.position)
                            result = .executed(value.outcome)
                        } else {
                            let value = try await self.executeMove(session, address: batch.address, binding: batch.binding,
                                                                  option: batch.option, position: next.position)
                            try await self.mutationStatus(session)
                            result = .executed(value)
                        }
                        next.finish(.success(result))
                    } catch { next.finish(.failure(error)) }
                    batch.inFlight = false
                }
                self.perfSliderQueueChanged?(0, 0)
            }
            sliderBatch = batch
            perfSliderQueueChanged?(0, 1)
        }
        return Task { try await request.value }
    }
    func submitMove(_ address: LibraryControlAddress, expected: LibraryBinding, to value: LibraryPosition,
                    optionGesture: LibraryOptionGesture? = nil) throws -> Task<LibraryLiveMutation, Error> {
        try scheduleLive { session in
            try await self.executeMove(session, address: address, binding: expected, option: optionGesture, position: value)
        }
    }
    private func executeMenuOrdered(_ session: SoundLibrarySession, address: LibraryControlAddress,
                                    expected: LibraryMenuIdentity, option: LibraryOptionGesture?, value: LibraryPosition) async throws -> LibraryMenuMoveResult {
        if let override = menuMoveOverride { return try await override(session, address, expected, option, value) }
        if perfMoveExecuted != nil {
            let measured = try await session.measuredMenuMove(address, expected: expected, optionGesture: option, to: value)
            perfMoveExecuted?(measured.measurement, value)
            return measured.result
        }
        return try await session.moveForMenu(address, expected: expected, optionGesture: option, to: value)
    }
    func submitMenuMove(_ address: LibraryControlAddress, expected: LibraryMenuIdentity, to value: LibraryPosition,
                        optionGesture: LibraryOptionGesture?, expectedEpoch: UInt64?, gestureIdentity: UUID? = nil) throws -> Task<LibraryLiveMutation, Error> {
        let checkpointChoice: Bool
        if gestureIdentity == nil, let expectedEpoch, checkpointGestureContext?.epoch == expectedEpoch,
           checkpointGestureContext?.identities.contains(expected) == true,
           let control = presentation?.uses.first(where: { $0.id == expected.binding.use })?.occurrences
            .first(where: { $0.path == address.path })?.controls.first(where: { $0.id == address.control }), case .choice = control.face {
            checkpointChoice = true
        } else { checkpointChoice = false }
        guard acceptsMenuEpoch(expectedEpoch, gestureIdentity: gestureIdentity) || checkpointChoice else { return Task { .superseded } }
        if checkpointChoice {
            menuGestureIdentity = nil; menuGestureContext = nil
            return try enqueueMutation(preservingGestureAdmission: true) { session in
                try await self.executeMenuOrdered(session, address: address, expected: expected, option: optionGesture, value: value).outcome
            }
        }
        return try scheduleLive { session in
            try await self.executeMenuOrdered(session, address: address, expected: expected, option: optionGesture, value: value).outcome
        }
    }
    func submitEnabled(_ enabled: Bool, expected: LibraryBinding? = nil) throws -> Task<LibraryLiveMutation, Error> {
        if let expected { return try scheduleLive(allowDuringDrain: !enabled) { try await $0.setEnabled(enabled, expected: expected) } }
        if !enabled, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupOff = true; liveSequence += 1; invalidate(); return Task { .changed }
        }
        return try scheduleLive(allowDuringDrain: !enabled) {
            let old = try await $0.liveState().isEnabled
            await $0.setEnabled(enabled)
            return old == enabled ? .noChange : .changed
        }
    }
    func submitCompare(_ comparing: Bool) throws -> Task<LibraryLiveMutation, Error> {
        if !comparing, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupRelease = true; liveSequence += 1; invalidate(); return Task { .noChange }
        }
        return try scheduleLive(allowDuringDrain: !comparing) {
            let old = try await $0.liveState().compareOriginal
            await $0.compareOriginal(comparing)
            return old == comparing ? .noChange : .changed
        }
    }
    private func completeLive(_ task: Task<LibraryLiveMutation, Error>) async throws -> LibraryLiveMutation {
        do {
            let result = try await task.value
            await refresh()
            return result
        } catch {
            await refresh(); throw error
        }
    }
    func move(_ address: LibraryControlAddress, expected: LibraryBinding, to value: LibraryPosition) async throws -> LibraryLiveMutation {
        let task = try scheduleLive { try await $0.move(address, expected: expected, to: value) }
        return try await completeLive(task)
    }
    func setEnabled(_ enabled: Bool, expected: LibraryBinding) async throws -> LibraryLiveMutation {
        let task = try scheduleLive(allowDuringDrain: !enabled) { try await $0.setEnabled(enabled, expected: expected) }
        return try await completeLive(task)
    }
    func setEnabled(_ enabled: Bool) async throws -> LibraryLiveMutation {
        if !enabled, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupOff = true; liveSequence += 1; invalidate(); return .changed
        }
        let task = try scheduleLive(allowDuringDrain: !enabled) {
            let old = try await $0.liveState().isEnabled
            await $0.setEnabled(enabled)
            return old == enabled ? .noChange : .changed
        }
        return try await completeLive(task)
    }
    func compareOriginal(_ comparing: Bool) async throws -> LibraryLiveMutation {
        if !comparing, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupRelease = true; liveSequence += 1; invalidate(); return .noChange
        }
        let task = try scheduleLive(allowDuringDrain: !comparing) {
            let old = try await $0.liveState().compareOriginal
            await $0.compareOriginal(comparing)
            return old == comparing ? .noChange : .changed
        }
        return try await completeLive(task)
    }
    /// Only a matching uncertain token and a definitive non-identical readback can acknowledge a held command.
    private func reconcileOwner() async throws -> LibraryConsumerReconciliation {
        guard let session else { throw LibraryError.invalidArchive }
        let before = try await session.liveState()
        if before.writing { return .inFlight(before.pendingCommit) }
        guard before.unresolved else { return .idle }
        beginSliderEligibilityBarrier()
        defer { endSliderEligibilityBarrier() }
        let held = pending
        let outcome = try await session.reconcile()
        let after = try await session.liveState()
        if after.unresolved || after.writing { return .unresolved(after.pendingCommit, String(describing: outcome)) }
        guard let held, held.commit == before.pendingCommit,
              pending?.command == held.command, pending?.commit == held.commit else {
            if let held, held.publication { await editor.receiveReconciliation(command: held.command, commit: held.commit, result: .superseded, report: nil) }
            return .superseded
        }
        switch outcome {
        case .committed:
            pending = nil
            editor.invalidateCoverage()
            if let creation = held.creation { emit(.creationAccepted(command: held.command, commit: held.commit, reference: creation.candidate)) }
            let result = LibraryConsumerReconciliation.accepted(command: held.command, commit: held.commit)
            if held.publication { await editor.receiveReconciliation(command: held.command, commit: held.commit, result: result, report: try await session.takeUpdateReport(token: held.commit)) }
            return result
        case .refused(let reason):
            pending = nil; editor.invalidateCoverage()
            let result = LibraryConsumerReconciliation.refused(command: held.command, commit: held.commit, reason: reason)
            if held.publication { await editor.receiveReconciliation(command: held.command, commit: held.commit, result: result, report: nil) }
            return result
        case .identical: return .idle
        case .unresolved(let detail): return .unresolved(before.pendingCommit, detail)
        }
    }
    func onMenuOpen() async {
        guard lifecycle == .running else { return }
        invalidatePositionDelivery()
        await joinLive()
        do {
            if let session { try await commitParameter(session) }
            if structuralActive != nil {
                emit(.reconciliation(.inFlight(try await session?.liveState().pendingCommit)))
            } else { emit(.reconciliation(try await reconcileOwner())) }
        }
        catch { emit(.readFailure(String(describing: error))) }
        await refresh()
    }
    private func scheduleStructural(commandID: UUID, _ action: @escaping @Sendable (SoundLibrarySession) async throws -> LibraryCommit) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID) { try await .commit(action($0)) }
    }
    private enum DurableValue: Sendable {
        case commit(LibraryCommit)
        case creation(LibraryCreationResult)
        case publication(LibraryUpdateResult)
        var receipt: LibraryCommit {
            switch self { case .commit(let value): return value; case .creation(let value): return value.commit; case .publication(let value): return value.commit }
        }
        var creation: LibraryCreationResult? { if case .creation(let value) = self { return value }; return nil }
    }
    private func scheduleDurable(commandID: UUID, preservingGestureAdmission: Bool = false,
        _ action: @escaping @Sendable (SoundLibrarySession) async throws -> DurableValue) -> Task<LibraryConsumerCommandResult, Never> {
        let id = commandID
        guard lifecycle == .running else {
            let result = LibraryConsumerCommandResult(command: id, outcome: .rejected(lifecycle))
            emit(.command(result)); return Task { result }
        }
        let checkpointContext = preservingGestureAdmission ? positionContext ?? checkpointGestureContext : nil
        if preservingGestureAdmission { checkpointAdmissions += 1 }
        beginSliderEligibilityBarrier(preservingGestureAdmission: preservingGestureAdmission)
        if preservingGestureAdmission {
            checkpointGestureContext = checkpointContext
            menuGestureContext = nil
            menuGestureIdentity = nil
        }
        let prior = structuralTail, mutationBarrier = liveTail, completion = LibraryCommandCompletion()
        structuralTail = completion
        let task = Task { @MainActor in
            defer {
                if preservingGestureAdmission { checkpointAdmissions -= 1 }
                endSliderEligibilityBarrier(); completion.finish()
            }
            _ = await prior?.value
            await mutationBarrier?.value
            let outcome: LibraryConsumerCommandOutcome
            var creation: LibraryCreationResult?
            var publication: LibraryUpdateResult?
            do {
                guard let session else { throw LibraryError.invalidArchive }
                try await commitParameter(session)
                emit(.reconciliation(try await reconcileOwner()))
                let state = try await session.liveState()
                if state.unresolved || state.writing { outcome = .blocked(state.pendingCommit) }
                else {
                    structuralActive = id
                    defer { structuralActive = nil }
                    let value = try await action(session), receipt = value.receipt
                    creation = value.creation
                    if case .publication(let result) = value { publication = result }
                    invalidate()
                    editor.invalidateCoverage()
                    switch receipt.outcome {
                    case .committed, .identical: outcome = .accepted(receipt)
                    case .refused: outcome = .refused(receipt)
                    case .unresolved:
                        pending = (id, receipt.token, creation, publication != nil); outcome = .unresolved(receipt)
                    }
                }
            } catch { outcome = .failed(String(describing: error)) }
            let result = LibraryConsumerCommandResult(command: id, outcome: outcome, creation: creation, publication: publication)
            await editor.receivePublication(result)
            emit(.command(result))
            editor.requestDisplay()
            if case .accepted(let receipt) = outcome, let creation {
                emit(.creationAccepted(command: id, commit: receipt.token, reference: creation.candidate))
            }
            return result
        }
        return task
    }
    private func completeStructural(_ task: Task<LibraryConsumerCommandResult, Never>) async -> LibraryConsumerCommandResult {
        let result = await task.value
        await refresh()
        return result
    }
    func select(_ definition: UUID?, on target: String, commandID: UUID = UUID()) async -> LibraryConsumerCommandResult {
        let task = scheduleStructural(commandID: commandID) { try await $0.select(definition, on: target) }
        return await completeStructural(task)
    }
    func nameUse(on target: String, name: String?, commandID: UUID = UUID()) async -> LibraryConsumerCommandResult {
        let task = scheduleStructural(commandID: commandID) { try await $0.nameUse(on: target, name: name) }
        return await completeStructural(task)
    }
    func checkpoint(commandID: UUID = UUID()) async -> LibraryConsumerCommandResult {
        let task = submitCheckpoint(commandID: commandID)
        return await completeStructural(task)
    }

    func submitSelect(_ definition: UUID?, on target: String, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleStructural(commandID: commandID) { try await $0.select(definition, on: target) }
    }
    func waitForIssuedSaves() async {
        await structuralTail?.value
    }
    func submitGestureCheckpoint() -> Task<LibraryConsumerCommandResult, Never> {
        sealSliderMoves()
        return Task { @MainActor in
            await joinLive()
            if Task.isCancelled { return LibraryConsumerCommandResult(command: UUID(), outcome: .cancelled) }
            guard lifecycle == .running else {
                return LibraryConsumerCommandResult(command: UUID(), outcome: .rejected(lifecycle))
            }
            let checkpoint = submitCheckpoint()
            let result = await checkpoint.value
            while lifecycle == .running {
                await joinLive()
                let sequence = liveSequence
                if await refresh(mode: .positions), sequence == liveSequence { break }
                if !refreshWanted { break }
            }
            return result
        }
    }
    func submitCheckpoint(commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID, preservingGestureAdmission: true) { try await .commit($0.checkpoint()) }
    }
    func submitCreateEmpty(name: String, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID) { try await .creation($0.createEmpty(name: name)) }
    }
    func submitDuplicate(_ reference: LibraryReference, name: String, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID) { try await .creation($0.duplicate(reference, name: name)) }
    }
    func submitCreateFromUse(_ binding: LibraryBinding, name: String, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID) { try await .creation($0.createFromUse(expected: binding, name: name)) }
    }
    func submitRename(_ definition: UUID, name: String, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleStructural(commandID: commandID) { try await $0.renameDefinition(definition, name: name) }
    }
    func submitNameUse(_ binding: LibraryBinding, name: String?, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleStructural(commandID: commandID) { session in
            let state = try await session.liveState()
            guard state.assignments.contains(where: { $0.binding == binding }) else { throw LibraryError.staleBinding }
            return try await session.nameUse(on: binding.target, name: name)
        }
    }
    func submitInMenu(_ definition: UUID, visible: Bool, commandID: UUID = UUID()) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleStructural(commandID: commandID) { try await $0.setInMenu(definition, visible) }
    }

    func submitUpdate(_ preview: LibraryUpdatePreview, commandID: UUID) -> Task<LibraryConsumerCommandResult, Never> {
        scheduleDurable(commandID: commandID) { session in
            do { return try await .publication(session.confirmUpdateLibrary(preview)) }
            catch { await session.cancelUpdateLibrary(preview); throw error }
        }
    }

    @discardableResult
    func beginDrain() -> Bool {
        guard lifecycle == .running else { return false }
        invalidatePositionDelivery()
        editor.prepareDrain()
        lifecycle = .draining; discardRequested = false; invalidate()
        emit(.lifecycle(.draining)); return true
    }
    /// Cancel never cancels an issued replacement. While it is still joining/saving, return busy.
    @discardableResult
    func cancelDrain() -> Bool {
        guard lifecycle == .draining, drainTask == nil else { return false }
        lifecycle = .running; editor.resume(); invalidate(); emit(.lifecycle(.running)); return true
    }
    func finishDrain(_ mode: LibraryDrainMode) async -> LibraryDrainResult {
        if lifecycle == .running { _ = beginDrain() }
        if mode == .discard { discardRequested = true }
        if let drainTask { return await drainTask.value }
        guard lifecycle == .draining else { return lifecycle == .closed ? .closed : .cancelled }
        let task = Task { @MainActor in await drainOwner() }
        drainTask = task
        let result = await task.value
        drainTask = nil
        return result
    }
    private func joinLive() async {
        sealSliderMoves()
        while true {
            let sequence = liveSequence, tail = liveTail
            await tail?.value
            if sequence == liveSequence { return }
        }
    }
    private func drainOwner() async -> LibraryDrainResult {
        // These tasks end at model completion, not at the caller's potentially held display refresh.
        await startupTask?.value
        _ = await structuralTail?.value
        await joinLive()
        if discardRequested { return .discarded }
        if let failure = editor.drainFailure { return .failed(failure) }
        guard lifecycle != .closed else { return .closed }
        guard let session else { return .startupUnavailable(startupStatus) }
        do {
            try await commitParameter(session)
            emit(.reconciliation(try await reconcileOwner()))
            let state = try await session.liveState()
            if state.unresolved { return .unresolved(state.pendingCommit, "readback remains unresolved") }
            if state.writing { return .blocked(state.pendingCommit) }
            while true {
                await joinLive()
                if discardRequested { return .discarded }
                guard lifecycle != .closed else { return .closed }
                let receipt = try await session.checkpoint()
                invalidate()
                if discardRequested { await joinLive(); return .discarded }
                switch receipt.outcome {
                case .refused: return .refused(receipt)
                case .unresolved(let detail): return .unresolved(receipt.token, detail)
                case .committed, .identical: break
                }
                await joinLive()
                let sequence = liveSequence
                let coverage = try await session.saveCoverage()
                if discardRequested { return .discarded }
                guard lifecycle != .closed else { return .closed }
                if sequence != liveSequence { continue }
                if coverage.isSaved { return .saved(receipt) }
                // An accepted replacement covered older state. Persist the newer admitted OFF,
                // not a retry of refused or unknown bytes. No ordinary ON/move is admitted here.
            }
        } catch { return .failed(String(describing: error)) }
    }
    /// Call after saved/discarded drain and before the existing output-first native shutdown.
    func closePublications() { invalidatePositionDelivery(); lifecycle = .closed; editor.retire(); apply = nil; invalidate() }

}

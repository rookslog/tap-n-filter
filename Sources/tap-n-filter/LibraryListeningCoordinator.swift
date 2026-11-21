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

/// What can change admission. Each event has exactly one outcome (EVENT-TABLE A-P, A-SEM, A-M1, A-E1).
enum AdmissionCause: Equatable {
    /// A-G1: a drag begins. `nil` is the legacy anonymous begin, which never makes a drag identity live.
    case beginDrag(UUID?)
    /// A-G4: the pointer is released.
    case endDrag
    /// A-E1: applying an admitted move failed; the drag stops counting.
    case failedApply
    /// A-M1: the menu opened; a drag the old menu never ended is over.
    case menuOpened
    /// A-SEM: source or output format change, structural command, edit begin. Every shown card becomes stale.
    case realBarrier
    /// A-LC: a lane finished starting or stopping. Not a barrier.
    case laneChange
    /// A save, click, move, read or other mutation. Not a barrier (A-K0); it only suspends live delivery.
    case mutation
    /// Drain or close: nothing is admitted afterwards.
    case retireAll
}

struct AdmissionDecision {
    let request: MenuAdmission.Request
    let admitted: Bool
}

/// MENU-STATE-01: the one owner of live-value admission. Two parts, both from the event table:
/// the pointer (free, dragging one identity, or holding a drag a real barrier retired) and card currency (a card is current until a real barrier
/// replaces it). Saves, reads, clicks and playback lane changes appear in neither.
struct MenuAdmission {
    /// `.retired`: the pointer still holds a drag whose identity a real barrier retired (A-N3). It admits no drag sample
    /// and no keyboard step, and is freed only by the release, a failed apply, a menu reopen or drain.
    enum Pointer: Equatable { case free, dragging(UUID?), retired }
    enum Request {
        /// A drag sample: carries the drag's identity and the card it was sent from.
        case dragMove(UUID, card: UInt64?)
        /// An anonymous choice click (or other non-slider move).
        case click(card: UInt64?)
        /// An anonymous slider move: a keyboard or accessibility step.
        case step(card: UInt64?)
    }
    private(set) var pointer = Pointer.free
    /// Advanced by real barriers only. A card is current when it carries this epoch.
    private(set) var barrierEpoch: UInt64 = 0
    /// True while a live (not retired) drag is held. A retired held pointer is not a live drag.
    var isDragging: Bool { if case .dragging = pointer { return true } else { return false } }
    var isHeld: Bool { pointer != .free }

    mutating func apply(_ cause: AdmissionCause) {
        switch cause {
        case .beginDrag(let identity): pointer = .dragging(identity)      // A-G1: retires any earlier drag
        case .endDrag, .failedApply, .menuOpened: pointer = .free         // A-G4, A-E1, A-M1
        case .realBarrier:                                                 // A-SEM
            if case .dragging(.some) = pointer { pointer = .retired }       // still held: stays held, identity retired
            else if pointer != .retired { pointer = .free }                  // the legacy anonymous begin has no identity to hold
            barrierEpoch &+= 1
        case .retireAll: pointer = .free; barrierEpoch &+= 1
        case .laneChange, .mutation: break                                // A-LC, A-K0
        }
    }

    /// A-D. `card == nil` is a caller with no menu card (editor, legacy), which has no staleness to check.
    func decide(_ request: Request) -> Bool {
        func current(_ card: UInt64?) -> Bool { card == nil || card == barrierEpoch }
        switch request {
        case .dragMove(let gesture, let card):
            guard case .dragging(let live) = pointer, live == gesture else { return false }   // A-G3a
            return current(card)                                                              // A-G2, A-G3b
        case .click(let card):
            return current(card)                                                              // A-C1, A-C2, A-CD
        case .step(let card):
            // A-N1, A-N2, A-NR; A-N3: while the pointer holds an identified drag, a menu step can only be a stale
            // callback. The legacy anonymous begin (`.dragging(nil)`, non-menu callers only, D-1) has no identity
            // to be stale against, so its anonymous moves stay admitted.
            if card != nil {
                if case .dragging(.some) = pointer { return false }
                if pointer == .retired { return false }
            }
            return current(card)
        }
    }
}

@MainActor
private final class LibraryCommandCompletion {
    private var finished = false
    var isFinished: Bool { finished }
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
    /// The context of the card the menu shows, present only while the presentation equals the live state.
    /// It gates the live (position-only) delivery path and is cleared by every mutation or read; it does not
    /// decide admission. Admission is `admission`, below.
    private(set) var positionContext: MenuPositionContext?
    /// MENU-STATE-01: the single owner of live-value admission (pointer state and card currency).
    private(set) var admission = MenuAdmission()
    private var readOrder: UInt64 = 0
    private var newestEffectiveRead: UInt64 = 0
    private var editorReadOrder: UInt64 = 0
    private(set) var fullReadAttempts: UInt64 = 0
    private let publishPositions: (LibraryMenuDelta, MenuPositionContext) -> Bool
    private let menuMoveOverride: MenuMove?
    typealias MenuMove = @MainActor @Sendable (SoundLibrarySession, LibraryControlAddress, LibraryMenuIdentity, LibraryOptionGesture?, LibraryPosition) async throws -> LibraryMenuMoveResult
    private var sliderBatch: LibrarySliderBatch?
    private var checkpointAdmissions = 0
    private var editorReaders = 0
    /// Editor completion reads begun and not yet published or failed. M3 waits for these too (R1-5).
    private var editorCompletions = 0
    /// Calls of `refresh` begun and not finished, whoever made them. M3 waits for these (R2-3).
    private var refreshesInFlight = 0
    private var parameterGesture: LibraryParameterGesture?
    var perfParameterEvaluated: ((Double, LibraryPosition) -> Void)?
    var perfParameterDocumentCommit: ((LibraryLiveMutation) -> Void)?
    /// Test seams (M1, M6). Inert unless installed.
    /// M1: called synchronously at each admission decision with the request's gesture identity (nil for a step or click).
    var admissionDecided: ((AdmissionDecision) -> Void)?
    /// M2: awaited before a read's result is published, tagged by what asked for it. Inert unless installed.
    enum PublicationKind: Sendable { case menuRefresh, editorCompletion, menuOpen }
    var beforePublication: (@Sendable (PublicationKind) async -> Void)?
    /// M3: returns once no refresh, issued write, mutation or editor read is pending.
    func quiescent() async {
        while true {
            await liveTail?.value; await structuralTail?.value; await refreshTask?.value
            _ = await parameterCommit?.result    // P2 (round 3): a drag's ordered commit is pending work too
            if refreshTask == nil && parameterCommit == nil && editorReaders == 0 && editorCompletions == 0 && refreshesInFlight == 0 && !refreshWanted && (liveTail?.isFinished ?? true)
                && (structuralTail?.isFinished ?? true) { return }
            await Task.yield()
        }
    }
    /// M6: runs on the live apply path, before a sample is applied; throwing makes that apply fail.
    var applyFailureForTesting: (() throws -> Void)?
    /// M6b: runs in `executeMove` just before `session.move` (the ordered path: editor rows, no edit open); throwing makes that move
    /// fail through the normal failure path. Like M6 the closure clears itself for a single failure. Inert when nil.
    var moveFailureForTesting: (() throws -> Void)?
    /// A-G1: a new drag retires the earlier one. Moves are admitted by `admission`, never by what is in flight.
    func beginParameterGesture(identity: UUID? = nil) {
        sealSliderMoves()
        invalidate(.beginDrag(identity))
    }
    /// A-G4, A-E1, A-M1: the pointer is released, the drag failed, or the menu reopened over it.
    func endDrag() { invalidate(.endDrag) }
    var isDragging: Bool { admission.isDragging }
    /// The one place that changes admission or the live-delivery gate on behalf of an event.
    func invalidate(_ cause: AdmissionCause) {
        admission.apply(cause)
        sealSliderMoves()
        switch cause {
        case .beginDrag, .endDrag, .failedApply, .laneChange: break
        case .mutation, .menuOpened, .realBarrier, .retireAll:
            positionContext = nil; sliderEligibility = []
            fenceReads()
        }
    }
    /// R2-1: the one ordering rule for a drag's final value. The commit is registered as `parameterCommit` in the same
    /// synchronous step that retires `parameterGesture`, so any later caller (a save, a structural command, an editor read)
    /// waits for the write instead of finding neither the gesture nor the write. The caller that starts the commit
    /// gets its error; a caller that joins one only waits.
    @discardableResult
    private func commitParameter(_ owner: SoundLibrarySession) async throws -> LibraryLiveMutation? {
        if let gesture = parameterGesture {
            parameterGesture = nil
            if let latest = gesture.latest {
                let previous = parameterCommit
                commitSerial &+= 1; let serial = commitSerial
                let task = Task { @MainActor [self] () async throws -> LibraryLiveMutation? in
                    defer { if commitSerial == serial { parameterCommit = nil } }
                    _ = await previous?.result
                    let result = try await executeMenuOrdered(owner, address: gesture.plan.address,
                        expected: gesture.plan.identity, option: gesture.plan.option, value: latest)
                    perfParameterDocumentCommit?(result.outcome)
                    editor.invalidateCoverage()
                    return result.outcome
                }
                parameterCommit = task
                return try await task.value
            }
        }
        guard let pending = parameterCommit else { return nil }
        _ = await pending.result
        return nil
    }
    private var parameterCommit: Task<LibraryLiveMutation?, Error>?
    private var commitSerial: UInt64 = 0
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
        let previous = gesture.latest
        gesture.latest = value
        do { return try await applyLive(owner, gesture, value, epoch: epoch) }
        catch { gesture.latest = previous; throw error }    // A-E1: a failed apply changes nothing
    }
    private func applyLive(_ owner: SoundLibrarySession, _ gesture: LibraryParameterGesture, _ value: LibraryPosition,
                           epoch: UInt64) async throws -> LibrarySliderResult {
        let started = ProcessInfo.processInfo.systemUptime
        try applyFailureForTesting?()
        guard let delta = try gesture.plan.evaluate(value) else {
            let outcome = try await commitParameter(owner) ?? .superseded
            invalidate(.mutation)
            return .executed(outcome)
        }
        // A real barrier after admission: the barrier's own flush commits `latest`; this sample is not delivered live.
        guard epoch == admission.barrierEpoch else { return .fenced(.noChange) }
        guard let context = positionContext, let candidate = presentation?.applying(delta) else {
            // The presentation is behind the live state (a refresh is pending): write the admitted value in order.
            return .executed(try await commitParameter(owner) ?? .superseded)
        }
        var menuBehind = false
        let delivered = try gesture.plan.lease.ifValid {
            let transport = ListeningRenderSnapshot(menu: candidate)
            try admit(transport)
            menuBehind = !publishPositions(delta, context)
            presentation = candidate
            deliver(transport, compare: candidate.compareOriginal, mode: .positions)
            return true
        } ?? false
        // An admitted value always reaches the live state: a lease that lapsed or a menu that is behind
        // never drops it (A-G2). The menu catches up through a refresh.
        guard delivered else { return .executed(try await commitParameter(owner) ?? .superseded) }
        if menuBehind { requestRefresh(mode: .positions) }
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
    /// The last full (activation) delivery. An activation is dropped only when it repeats this one: a positions
    /// delivery of the same state does not stand in for it, because only an activation can clear a failed lane
    /// or authorize a restart (B-F2, B-A2).
    private var activated: (snapshot: ListeningRenderSnapshot, compare: Bool)?
    /// An activation was requested and no delivered refresh has carried it yet. A refresh a mutation fenced off
    /// must not turn it into a positions delivery, which never starts a lane (B3).
    private var activationPending = false
    private var lastRefreshFenced = false

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
        invalidate(.realBarrier)    // A-SEM: opening an edit can change what a card position means
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
    /// Read initiation order fences completions: a read begun before this call is discarded when it lands (A-K2).
    private func fenceReads() { generation += 1 }
    private func deliver(_ snapshot: ListeningRenderSnapshot, compare: Bool, mode: LibraryDeliveryMode) {
        guard lifecycle != .closed, let apply else { return }
        switch mode {
        case .positions: guard applied?.snapshot != snapshot || applied?.compare != compare else { return }
        case .activation: guard activated?.snapshot != snapshot || activated?.compare != compare else { return }
        }
        applied = (snapshot, compare)
        if mode == .activation { activated = (snapshot, compare) }
        // B-A4, B-R4: the controller withdraws restart authorization when a positions delivery turns power or an app
        // off. Then the last activation is no longer honoured, so an identical activation is not a repeat (B-F2, R1-1).
        else if !snapshot.isEnabled || snapshot.assignments.contains(where: { !$0.isEnabled }) { activated = nil }
        apply(snapshot, compare, mode)
    }
    /// Attach only a real synchronous consumer. Never replay an inactive startup intent.
    @discardableResult
    func attachPlayback(_ port: @escaping (ListeningRenderSnapshot, Bool, LibraryDeliveryMode) -> Void) async -> Bool {
        guard lifecycle == .running, session != nil, apply == nil else { return false }
        await joinLive()
        guard lifecycle == .running else { return false }
        fenceReads()
        apply = port
        await refresh()
        return lifecycle == .running
    }
    private func restrict(_ live: LibraryLiveState) {
        if let applied { deliver(applied.snapshot.restricting(to: live), compare: live.compareOriginal, mode: .positions) }
    }
    /// Read initiation order fences completions; command completions always request a new read.
    @discardableResult
    func refresh(mode: LibraryDeliveryMode = .activation, kind: PublicationKind = .menuRefresh) async -> Bool {
        guard lifecycle == .running, let session else { return false }
        refreshesInFlight += 1; defer { refreshesInFlight -= 1 }    // R2-3: a direct refresh (menu open) is pending work too
        fenceReads(); let requested = generation
        readOrder &+= 1; let order = readOrder
        let delivery = activationPending ? LibraryDeliveryMode.activation : mode
        lastRefreshFenced = false
        func fenced() -> Bool { if requested != generation { lastRefreshFenced = true; return true }; return false }
        do {
            fullReadAttempts &+= 1
            let snapshot = try await read(session)
            guard !fenced() else { return false }
            if let gate = beforePublication { await gate(kind); guard !fenced() else { return false } }
            let transport = ListeningRenderSnapshot(menu: snapshot)
            let failure: String?
            do { try admit(transport); failure = nil }
            catch { failure = String(describing: error) }
            if failure == nil && sliderEligibilityBarriers == 0 {
                deliver(transport, compare: snapshot.compareOriginal, mode: delivery)
                if delivery == .activation { activationPending = false }
            } else {
                let live = try await session.liveState()
                guard !fenced() else { return false }
                restrict(live)
            }
            presentation = snapshot
            let context = MenuPositionContext(presentation: snapshot, epoch: admission.barrierEpoch)
            positionContext = context
            newestEffectiveRead = max(newestEffectiveRead, order)
            installSliderEligibility(snapshot, admitted: failure == nil)
            emit(.state(LibraryConsumerPublication(generation: requested, presentation: snapshot, positionContext: context,
                menu: MenuLibraryProjection(snapshot), admissionFailure: failure)))
            return true
        } catch {
            guard !fenced() else { return false }
            sliderEligibility = []
            if let live = try? await session.liveState(), requested == generation { restrict(live) }
            guard !fenced() else { return false }
            newestEffectiveRead = max(newestEffectiveRead, order)
            emit(.readFailure(String(describing: error)))
            return false
        }
    }
    /// Only the mutation + cheap status read are ordered. Neither disk nor the full projection is on this tail.
    func enqueueMutation<Value: Sendable>(allowDuringDrain: Bool = false, statusAfterOperation: Bool = true,
        preservingSliderEligibility: Bool = false, realBarrier: Bool = false,
        _ operation: @escaping @MainActor @Sendable (SoundLibrarySession) async throws -> Value) throws -> Task<Value, Error> {
        guard lifecycle != .closed, lifecycle != .draining || allowDuringDrain else {
            throw LibraryConsumerLifecycleError.unavailable(lifecycle)
        }
        guard let session = session ?? (allowDuringDrain ? openingOwner : nil) else {
            throw LibraryConsumerLifecycleError.notReady
        }
        // R2-2: a caller that opens an editor edit says so, and the barrier goes through the one funnel, as `beginEdit` does.
        if realBarrier { invalidate(.realBarrier) }
        if preservingSliderEligibility { sealSliderMoves() }
        else { beginSliderEligibilityBarrier() }
        liveSequence += 1
        fenceReads()
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
            catch { fenceReads(); throw error }
            if statusAfterOperation { try await mutationStatus(session) }
            return result
        }
        return task
    }
    private func mutationStatus(_ session: SoundLibrarySession) async throws {
        fenceReads()
        editor.invalidateCoverage()
        let live = try await session.liveState()
        fenceReads()
        restrict(live)
    }
    private func scheduleLive(allowDuringDrain: Bool = false,
        _ operation: @escaping @Sendable (SoundLibrarySession) async throws -> LibraryLiveMutation) throws -> Task<LibraryLiveMutation, Error> {
        try enqueueMutation(allowDuringDrain: allowDuringDrain, operation)
    }
    func publishEditor(_ state: LibraryEditorState) { emit(.editor(state)) }
    func editorAcknowledged(_ command: UUID) { emit(.editorMutation(command)) }
    /// A-R1: a read changes no admission and no card; it only suspends live delivery until its result lands.
    @discardableResult
    private func beginEditorRead() -> UInt64 {
        if editorReaders == 0 { invalidate(.mutation) } else { sealSliderMoves() }
        editorReaders += 1
        readOrder &+= 1; editorReadOrder = readOrder
        return readOrder
    }
    /// Overlapping reads coalesce (A-R8): only the last to finish publishes, and an earlier one publishes nothing,
    /// success or failure.
    private func finishEditorRead(_ owner: SoundLibrarySession?) async {
        editorReaders -= 1
        guard editorReaders == 0, lifecycle == .running, let owner else { return }
        editorCompletions += 1
        defer { editorCompletions -= 1 }
        let expected = generation
        let began = editorReadOrder
        readOrder &+= 1; let completionOrder = readOrder
        do {
            fullReadAttempts &+= 1
            let snapshot = try await read(owner)
            guard editorReaders == 0, expected == generation else { return }
            if let gate = beforePublication {
                await gate(.editorCompletion)
                guard editorReaders == 0, expected == generation else { return }
            }
            let transport = ListeningRenderSnapshot(menu: snapshot)
            try admit(transport)
            if sliderEligibilityBarriers == 0 { deliver(transport, compare: snapshot.compareOriginal, mode: .positions) }
            else { restrict(snapshot.live) }
            let unchanged = presentation == snapshot
            presentation = snapshot
            let context = MenuPositionContext(presentation: snapshot, epoch: admission.barrierEpoch)
            positionContext = context
            newestEffectiveRead = max(newestEffectiveRead, completionOrder)
            installSliderEligibility(snapshot, admitted: true)
            if unchanged { emit(.positionContext(context)) }
            else { emit(.state(LibraryConsumerPublication(generation: expected, presentation: snapshot, positionContext: context,
                menu: MenuLibraryProjection(snapshot), admissionFailure: nil))) }
        } catch {
            // A-R5/A-R6: the warning shows only if no newer read took effect since this read began.
            guard began > newestEffectiveRead else { return }
            newestEffectiveRead = began
            emit(.readFailure(String(describing: error)))
        }
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
        if mode == .activation { refreshMode = .activation; activationPending = true }
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor in
            repeat {
                refreshWanted = false
                let mode = refreshMode; refreshMode = .positions
                let published = await refresh(mode: mode)
                // A refresh a newer mutation fenced off keeps its activation. A failed read never asks for itself
                // again (B6, A-R5).
                if !published, activationPending, lastRefreshFenced { refreshWanted = true }
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
    private func beginSliderEligibilityBarrier() {
        invalidate(.mutation)
        sliderEligibilityBarriers += 1
    }
    private func endSliderEligibilityBarrier() {
        sliderEligibilityBarriers -= 1
        sliderEligibility = []
        fenceReads()
    }
    /// M5: which playback publications are real barriers, decided here and not in App wiring.
    /// `.sourceOrFormat` (a source or output format change, or a lane set that needs a full delivery) is a real
    /// barrier (A-SEM). `.lane` (a lane finished starting or stopping, a problem or comparison change) is not:
    /// it changes playback state, not which control a card position means (A-LC).
    enum PlaybackChange { case sourceOrFormat, lane }
    func playbackDidChange(_ change: PlaybackChange = .sourceOrFormat) {
        switch change {
        case .sourceOrFormat: invalidate(.realBarrier)
        case .lane: invalidate(.laneChange)
        }
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
        try moveFailureForTesting?()
        if let option { return try await session.move(address, expected: binding, optionGesture: option, to: position) }
        return try await session.move(address, expected: binding, to: position)
    }
    /// The admission decision (A-D), made synchronously from the state as it stands when the action is sent.
    private func admits(_ request: MenuAdmission.Request) -> Bool {
        let decision = admission.decide(request)
        admissionDecided?(AdmissionDecision(request: request, admitted: decision))
        return decision
    }
    func submitSliderMove(_ address: LibraryControlAddress, expected: LibraryBinding, to value: LibraryPosition,
                          optionGesture: LibraryOptionGesture? = nil, menuIdentity: LibraryMenuIdentity? = nil, expectedEpoch: UInt64? = nil, gestureIdentity: UUID? = nil) throws -> Task<LibrarySliderResult, Error> {
        guard lifecycle == .running else { throw LibraryConsumerLifecycleError.unavailable(lifecycle) }
        guard session != nil else { throw LibraryConsumerLifecycleError.notReady }
        guard admits(gestureIdentity.map { .dragMove($0, card: expectedEpoch) } ?? .step(card: expectedEpoch)) else {
            return Task { .executed(.superseded) }
        }
        if let menuIdentity, presentation?.identity(for: expected) != menuIdentity {
            return Task { .executed(.superseded) }
        }
        guard sliderCanCoalesce(address, expected: expected, optionGesture: optionGesture) else {
            let ordered: Task<LibraryLiveMutation, Error>
            if let menuIdentity {
                ordered = try enqueueMutation { session in
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
            liveSequence += 1; fenceReads()
            if batch.pending != nil { perfSliderCoalesced?() }
            batch.replace(request)
            perfSliderQueueChanged?(batch.inFlight ? 1 : 0, 1)
        } else {
            let batch = LibrarySliderBatch(binding: expected, address: address, option: optionGesture, identity: menuIdentity, request: request)
            // enqueueMutation seals the previous segment before installing this one's tail.
            let epoch = admission.barrierEpoch
            let identity = menuIdentity ?? presentation?.identity(for: expected)
            _ = try enqueueMutation(statusAfterOperation: false, preservingSliderEligibility: true) { session in
                defer { if self.sliderBatch === batch { self.sliderBatch = nil } }
                while let next = batch.take() {
                    batch.inFlight = true
                    self.perfSliderQueueChanged?(1, batch.pending == nil ? 0 : 1)
                    do {
                        let result: LibrarySliderResult
                        if let identity, self.moveOverride == nil, self.admission.isDragging || self.parameterGesture != nil {
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
        guard admits(gestureIdentity.map { .dragMove($0, card: expectedEpoch) } ?? .click(card: expectedEpoch)) else {
            return Task { .superseded }
        }
        return try scheduleLive { session in
            try await self.executeMenuOrdered(session, address: address, expected: expected, option: optionGesture, value: value).outcome
        }
    }
    func submitEnabled(_ enabled: Bool, expected: LibraryBinding? = nil) throws -> Task<LibraryLiveMutation, Error> {
        if let expected { return try scheduleLive(allowDuringDrain: !enabled) { try await $0.setEnabled(enabled, expected: expected) } }
        if !enabled, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupOff = true; liveSequence += 1; fenceReads(); return Task { .changed }
        }
        return try scheduleLive(allowDuringDrain: !enabled) {
            let old = try await $0.liveState().isEnabled
            await $0.setEnabled(enabled)
            return old == enabled ? .noChange : .changed
        }
    }
    func submitCompare(_ comparing: Bool) throws -> Task<LibraryLiveMutation, Error> {
        if !comparing, startupPending, session == nil, openingOwner == nil, lifecycle != .closed {
            startupRelease = true; liveSequence += 1; fenceReads(); return Task { .noChange }
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
            startupOff = true; liveSequence += 1; fenceReads(); return .changed
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
            startupRelease = true; liveSequence += 1; fenceReads(); return .noChange
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
        // A-M1: the reopen retired any held drag once, synchronously, in `LibraryAppSession.menuOpened()`. This queued
        // task must not touch the pointer: a drag begun since belongs to the new menu (R1-3). It only gates live delivery.
        invalidate(.mutation)
        await joinLive()
        do {
            if let session { try await commitParameter(session) }
            if structuralActive != nil {
                emit(.reconciliation(.inFlight(try await session?.liveState().pendingCommit)))
            } else { emit(.reconciliation(try await reconcileOwner())) }
        }
        catch { emit(.readFailure(String(describing: error))) }
        await refresh(kind: .menuOpen)
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
    /// `barrier`: a structural command (A-SEM). A checkpoint is not one: it saves, and changes no card.
    private func scheduleDurable(commandID: UUID, barrier: Bool = true,
        _ action: @escaping @Sendable (SoundLibrarySession) async throws -> DurableValue) -> Task<LibraryConsumerCommandResult, Never> {
        let id = commandID
        guard lifecycle == .running else {
            let result = LibraryConsumerCommandResult(command: id, outcome: .rejected(lifecycle))
            emit(.command(result)); return Task { result }
        }
        if barrier { invalidate(.realBarrier) }
        beginSliderEligibilityBarrier()
        let prior = structuralTail, mutationBarrier = liveTail, completion = LibraryCommandCompletion()
        structuralTail = completion
        let task = Task { @MainActor in
            defer { endSliderEligibilityBarrier(); completion.finish() }
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
                    fenceReads()
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
        invalidate(.endDrag)       // A-G4: the drag is retired at once, before any save step runs
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
        scheduleDurable(commandID: commandID, barrier: false) { try await .commit($0.checkpoint()) }
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
        invalidate(.retireAll)
        editor.prepareDrain()
        lifecycle = .draining; discardRequested = false; fenceReads()
        emit(.lifecycle(.draining)); return true
    }
    /// Cancel never cancels an issued replacement. While it is still joining/saving, return busy.
    @discardableResult
    func cancelDrain() -> Bool {
        guard lifecycle == .draining, drainTask == nil else { return false }
        lifecycle = .running; editor.resume(); fenceReads(); emit(.lifecycle(.running)); return true
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
                fenceReads()
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
    func closePublications() { invalidate(.retireAll); lifecycle = .closed; editor.retire(); apply = nil; fenceReads() }

}

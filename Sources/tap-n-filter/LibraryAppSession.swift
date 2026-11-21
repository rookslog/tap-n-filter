import Foundation
import SoundModel
import EverydayMenu
import PlaybackRenderBridge

/// The normal App's semantic owner and command adapter. No native objects, second model or writer.
@MainActor
final class LibraryAppSession {
    static func normalLimits() throws -> LibraryLimits {
        try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128,
            expansion: LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128))
    }
    private(set) var presentation: LibraryMenuState?
    private(set) var menuData: MenuSoundData?
    private(set) var presentationGeneration: UInt64?
    private(set) var roster = LibraryRosterRequests()
    private(set) var startup: LibraryConsumerStartup = .starting
    /// Read problem first, then the startup/editor problem, then the save problem, then the apply problem (A-E1 writers kept apart).
    var problem: String? { readProblem ?? startupEditorProblem ?? saveProblem ?? applyProblem }
    private var readProblem: String?
    /// Startup and editor failures: never cleared (neither is reachable in a normal launch).
    private var startupEditorProblem: String?
    /// A command or checkpoint result that was not accepted. Cleared by the next accepted command result or accepted reconciliation.
    private var saveProblem: String?
    /// A slider, power or compare command that threw. Cleared by the next live command that succeeds and when the alert showing it is dismissed.
    private var applyProblem: String?
    private var shownApplyProblem: String?
    private(set) var acceptedCreation: (command: UUID, commit: UUID, reference: LibraryReference)?
    var editor: LibraryEditorAdapter { coordinator.editor }
    private let changed: () -> Void
    private let attentionChanged: () -> Void
    private let contextChanged: (MenuPositionContext) -> Void
    private let positionsChanged: (LibraryMenuDelta, MenuPositionContext) -> Bool
    private let menuMove: LibraryListeningCoordinator.MenuMove?
    var perfMutationCompleted: ((LibraryLiveMutation) -> Void)?
    var perfMutationFailed: (() -> Void)?
    /// M1: an admission receipt for each menu action, delivered synchronously at the decision (or at a failed apply).
    enum AdmissionOutcome: Sendable { case admitted, superseded, failed }
    /// Unarmed (nil) it does no work: no coordinator closure, no stored action, nothing captured (R1-6).
    var admissionDecided: ((EverydayMenuAction, AdmissionOutcome) -> Void)? { didSet { wireAdmissionReceipt() } }
    private func wireAdmissionReceipt() {
        guard admissionDecided != nil else { coordinator.admissionDecided = nil; actionInFlight = nil; return }
        coordinator.admissionDecided = { [weak self] decision in
            guard let self, let action = actionInFlight else { return }
            admissionDecided?(action, decision.admitted ? .admitted : .superseded)
        }
    }
    private var actionInFlight: EverydayMenuAction?
    /// Reads `actionInFlight` only while M1 is armed (R2-4); unarmed it is a constant nil and nothing is loaded.
    private var armedAction: EverydayMenuAction? { admissionDecided == nil ? nil : actionInFlight }
    /// M3: the coordinator's quiescence plus the issued gesture save.
    func quiescent() async { _ = await gestureSave?.value; await coordinator.quiescent() }
    func perfRefresh(_ menu: EverydayMenu, apps: [SourceAppInfo]) {
        guard let presentation, let menuData else { return }
        menu.update(data: menuData, positionContext: coordinator.positionContext, pendingApps: [], apps: apps, comparing: presentation.compareOriginal,
                    compareAvailable: false, problem: problem == nil ? nil : "Audio Needs Attention…")
    }
    private let checkpointDelay: @Sendable () async throws -> Void
    private var debounce: Task<Void, Never>?
    private var gesturing = false
    private var saveEpoch: UInt64 = 0
    private(set) var gestureSave: Task<LibraryConsumerCommandResult, Never>?
    private let editRead: LibraryListeningCoordinator.EditRead
    private let read: LibraryListeningCoordinator.Read
    private let move: LibraryListeningCoordinator.Move?
    private(set) lazy var coordinator: LibraryListeningCoordinator = {
        let owner = LibraryListeningCoordinator(
            publish: { [weak self] in self?.receive($0) }, read: read, editRead: editRead, move: move,
            menuMove: menuMove, positions: { [weak self] in self?.receivePositions($0, context: $1) ?? false })
        return owner
    }()

    init(changed: @escaping () -> Void,
         attentionChanged: @escaping () -> Void = {},
         contextChanged: @escaping (MenuPositionContext) -> Void = { _ in },
         positionsChanged: @escaping (LibraryMenuDelta, MenuPositionContext) -> Bool = { _, _ in true },
         read: @escaping LibraryListeningCoordinator.Read = { try await $0.menuState() },
         editRead: @escaping LibraryListeningCoordinator.EditRead = { try await $0.inspectEdit($1) },
         checkpointDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) },
         move: LibraryListeningCoordinator.Move? = nil,
         menuMove: LibraryListeningCoordinator.MenuMove? = nil) {
        self.move = move; self.menuMove = menuMove; self.positionsChanged = positionsChanged; self.contextChanged = contextChanged
        self.attentionChanged = attentionChanged; self.changed = changed; self.read = read; self.editRead = editRead; self.checkpointDelay = checkpointDelay
    }
    private func receivePositions(_ delta: LibraryMenuDelta, context: MenuPositionContext) -> Bool {
        guard let next = presentation?.applying(delta), let data = menuData?.applying(delta),
              positionsChanged(delta, context) else { return false }
        presentation = next; menuData = data
        return true
    }
    /// Internal so tests can deliver coordinator events directly.
    func receive(_ event: LibraryConsumerEvent) {
        if let receipt = event.rosterReceipt { roster.receive(receipt) }
        switch event {
        case .positionContext(let context):
            menuData = menuData?.contextualized(context)
            contextChanged(context)
            if readProblem != nil { readProblem = nil; attentionChanged() }
            return
        case .state(let publication):
            presentation = publication.presentation
            menuData = MenuSoundData(projection: publication.menu).contextualized(publication.positionContext)
            presentationGeneration = publication.generation
            roster.update(publication.presentation)
            readProblem = publication.admissionFailure
        case .startup(let status):
            startup = status
            switch status {
            case .starting, .existing, .fresh, .migrated: break
            default: startupEditorProblem = String(describing: status)
            }
        case .command(let result):
            switch result.outcome {
            case .accepted: saveProblem = nil
            default: saveProblem = "The change could not be saved. \(result.outcome)"
            }
        case .reconciliation(let result):
            if case .accepted = result { saveProblem = nil }
        case .editorMutation: scheduleSave()
        case .editor(let state):
            if let failure = state.failure { startupEditorProblem = failure }
        case .creationAccepted(let command, let commit, let reference):
            acceptedCreation = (command, commit, reference)
        case .readFailure(let reason):
            readProblem = reason
            attentionChanged()
            return
        default: break
        }
        changed()
    }
    func start(persistence: any LibraryPersistence, limits: LibraryLimits,
               migrationSource: LibraryMigrationSource? = nil) async {
        await coordinator.start(persistence: persistence, limits: limits, migrationSource: migrationSource,
                                freshPreparation: LibraryFreshPreparation.safariEveryday, builtins: .quickMenu)
    }
    var isReady: Bool { presentation != nil && coordinator.lifecycle == .running }
    var neutral: ListeningRenderSnapshot? { presentation.map(ListeningRenderSnapshot.init(menu:)) }

    /// Admission and identity binding happen synchronously, before the command Task exists.
    @discardableResult
    func toggle(_ target: String, id: UUID = UUID()) -> Bool {
        request(roster.committed.contains(target) ? .remove : .add, target: target, id: id)
    }
    @discardableResult
    func request(_ direction: LibraryRosterRequests.Direction, target: String, id: UUID = UUID()) -> Bool {
        guard coordinator.lifecycle == .running, let presentation else { return false }
        let removing = direction == .remove
        let definition = removing ? nil : presentation.definitions.first(where: \.inTheMenu)?.id
        guard removing || definition != nil,
              roster.bind(id, bundle: target, direction: removing ? .remove : .add) else { return false }
        observe(coordinator.submitSelect(definition, on: target, commandID: id))
        changed()
        return true
    }
    func select(_ definition: UUID?, on target: String) {
        if definition == nil { _ = request(.remove, target: target); return }
        guard roster.isEnabled(target) else { return }
        observe(coordinator.submitSelect(definition, on: target))
    }
    func send(_ action: EverydayMenuAction) {
        guard coordinator.lifecycle != .closed else { return }
        if admissionDecided != nil { actionInFlight = action }
        defer { if admissionDecided != nil { actionInFlight = nil } }
        switch action {
        case .beginGesture: beginGesture(nil)
        case .beginMenuGesture(let identity): beginGesture(identity)
        case .endGesture:
            guard gesturing else { return }
            gesturing = false
            gestureSave = flushSave()
        case .putOn(let target): _ = request(.add, target: target)
        case .selectBlock(let definition, let target): select(definition, on: target)
        case .setEnabled(let enabled): live { try $0.submitEnabled(enabled) }
        case .libraryPower(let binding, let enabled): live { try $0.submitEnabled(enabled, expected: binding) }
        case .gestureMove(let gesture, let identity, let epoch, let address, let option, let position):
            listen(identity.binding, address, position, option: option, identity: identity, deliveryEpoch: epoch, gestureIdentity: gesture)
        case .menuMove(let identity, let epoch, let address, let option, let position):
            listen(identity.binding, address, position, option: option, identity: identity, deliveryEpoch: epoch)
        case .libraryMove(let binding, let address, let position):
            listen(binding, address, position, option: nil)
        case .libraryOptionMove(let binding, let address, let gesture, let position):
            listen(binding, address, position, option: gesture)
        case .libraryGestureMove(let drag, let binding, let address, let option, let position):
            listen(binding, address, position, option: option, gestureIdentity: drag)
        case .compare(let comparing): live(save: false) { try $0.submitCompare(comparing) }
        default: break
        }
    }
    private func beginGesture(_ identity: UUID?) {
        gestureSave?.cancel(); gestureSave = nil
        coordinator.beginParameterGesture(identity: identity)
        gesturing = true
        saveEpoch &+= 1
        cancelPendingSave()
    }
    private func listen(_ binding: LibraryBinding, _ address: LibraryControlAddress,
                        _ position: LibraryPosition, option: LibraryOptionGesture?, identity: LibraryMenuIdentity? = nil,
                        deliveryEpoch: UInt64? = nil, gestureIdentity: UUID? = nil) {
        let card = menuData?.assignments.first { $0.binding == binding }
        let controls = (card?.controls ?? []) + (card?.optionTabs.flatMap(\.controls) ?? [])
        let slider = controls.contains { control in
            guard control.address == address, control.optionGesture == option, case .slider = control.face else { return false }
            return true
        }
        guard slider, case .scalar = position else {
            if let identity {
                live(positionOnly: true) { try $0.submitMenuMove(address, expected: identity, to: position,
                    optionGesture: option, expectedEpoch: deliveryEpoch, gestureIdentity: gestureIdentity) }
            } else {
                live(positionOnly: true) { try $0.submitMove(address, expected: binding, to: position, optionGesture: option) }
            }
            return
        }
        let action = armedAction
        do {
            let task = try coordinator.submitSliderMove(address, expected: binding, to: position,
                optionGesture: option, menuIdentity: identity, expectedEpoch: deliveryEpoch, gestureIdentity: gestureIdentity)
            let epoch = saveEpoch
            Task {
                do {
                    switch try await task.value {
                    case .coalesced: break
                    case .live: applyDidSucceed()
                    case .delivered(let result), .fenced(let result):
                        perfMutationCompleted?(result)
                        applyDidSucceed()
                        if !gesturing && epoch == saveEpoch { scheduleSave() }
                    case .executed(let result):
                        perfMutationCompleted?(result)
                        applyDidSucceed()
                        coordinator.requestRefresh(mode: .positions)
                        if !gesturing && epoch == saveEpoch { scheduleSave() }
                    }
                } catch { perfMutationFailed?(); record(error, action: action) }
            }
        } catch { perfMutationFailed?(); record(error, action: action) }
    }
    private func live(save: Bool = true, positionOnly: Bool = false,
                      _ action: (LibraryListeningCoordinator) throws -> Task<LibraryLiveMutation, Error>) {
        let received = armedAction
        do {
            let task = try action(coordinator)
            let epoch = saveEpoch
            Task {
                do {
                    let result = try await task.value
                    perfMutationCompleted?(result)
                    applyDidSucceed()
                    coordinator.requestRefresh(mode: positionOnly ? .positions : .activation)
                    if save && !gesturing && epoch == saveEpoch { scheduleSave() }
                }
                catch { perfMutationFailed?(); record(error, action: received) }
            }
        } catch { perfMutationFailed?(); record(error, action: received) }
    }
    /// A-E1: a failed apply shows the problem once and ends the drag, saving the earlier values.
    func record(_ error: Error, action: EverydayMenuAction? = nil) {
        guard coordinator.lifecycle != .closed else { return }
        applyProblem = "The change could not be saved. \(error)"; changed()
        if let action { admissionDecided?(action, .failed) }
        coordinator.invalidate(.failedApply)
        if gesturing { gesturing = false; _ = flushSave() }
    }
    /// A live command succeeded: an earlier apply problem no longer describes the menu.
    func applyDidSucceed() {
        guard applyProblem != nil else { return }
        applyProblem = nil; changed()
    }
    /// The text the problem alert is about to show. Remembers when that text is the apply problem, so dismissal can clear it.
    func presentProblem() -> String? {
        shownApplyProblem = readProblem == nil && startupEditorProblem == nil && saveProblem == nil ? applyProblem : nil
        return problem
    }
    /// The alert from `presentProblem()` was dismissed: an apply problem the person has seen is cleared.
    func problemDismissed() {
        defer { shownApplyProblem = nil }
        guard let shown = shownApplyProblem, applyProblem == shown else { return }
        applyProblem = nil; changed()
    }
    private func observe(_ task: Task<LibraryConsumerCommandResult, Never>) {
        Task { _ = await task.value; coordinator.requestRefresh(); editor.requestDisplay() }
    }
    @discardableResult
    func createEmpty(name: String) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitCreateEmpty(name: name); observe(task); return task
    }
    @discardableResult
    func duplicate(_ reference: LibraryReference, name: String) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitDuplicate(reference, name: name); observe(task); return task
    }
    @discardableResult
    func createFromUse(_ binding: LibraryBinding, name: String) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitCreateFromUse(binding, name: name); observe(task); return task
    }
    @discardableResult
    func rename(_ definition: UUID, name: String) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitRename(definition, name: name); observe(task); return task
    }
    @discardableResult
    func nameUse(_ binding: LibraryBinding, name: String?) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitNameUse(binding, name: name); observe(task); return task
    }
    @discardableResult
    func setInMenu(_ definition: UUID, visible: Bool) -> Task<LibraryConsumerCommandResult, Never> {
        let task = coordinator.submitInMenu(definition, visible: visible); observe(task); return task
    }
    /// A-M1: a drag the old menu never ended is over: the pointer is free and one save is issued as at end.
    @discardableResult func menuOpened() -> Task<Void, Never> {
        coordinator.invalidate(.menuOpened)
        if gesturing { gesturing = false; gestureSave = flushSave() }
        return Task { await coordinator.onMenuOpen() }
    }
    func cancelPendingSave() {
        debounce?.cancel(); debounce = nil
    }
    func scheduleSave() {
        cancelPendingSave()
        guard coordinator.lifecycle == .running, !gesturing else { return }
        debounce = Task {
            do { try await checkpointDelay() } catch { return }
            guard !Task.isCancelled else { return }
            // Only the unissued sleep is cancellable. The issued coordinator write has its own tail.
            debounce = nil
            let task = coordinator.submitCheckpoint()
            _ = await task.value
            coordinator.requestRefresh(mode: .positions); editor.requestDisplay()
        }
    }
    @discardableResult
    func flushSave() -> Task<LibraryConsumerCommandResult, Never>? {
        cancelPendingSave()
        saveEpoch &+= 1
        guard coordinator.lifecycle == .running else { return nil }
        let task = coordinator.submitGestureCheckpoint()
        Task { _ = await task.value; editor.requestDisplay() }
        return task
    }
    func beginDrain() {
        gesturing = false
        saveEpoch &+= 1
        debounce?.cancel(); debounce = nil
        _ = coordinator.beginDrain()
    }
    /// A drain result that needs the person's decision. `startupUnavailable`: startup never opened a session, so there is nothing to save.
    static func drainNeedsDecision(_ result: LibraryDrainResult) -> Bool {
        switch result {
        case .saved, .startupUnavailable: return false
        default: return true
        }
    }
    func finishDrain(_ mode: LibraryDrainMode) async -> LibraryDrainResult { await coordinator.finishDrain(mode) }
    @discardableResult func cancelDrain() -> Bool {
        let cancelled = coordinator.cancelDrain()
        if cancelled { Task { await coordinator.refresh() } }
        return cancelled
    }
    func close() { debounce?.cancel(); debounce = nil; coordinator.closePublications() }
}

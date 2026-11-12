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
    private(set) var snapshot: LibrarySnapshot?
    private(set) var menuData: MenuSoundData?
    private(set) var snapshotGeneration: UInt64?
    private(set) var roster = LibraryRosterRequests()
    private(set) var startup: LibraryConsumerStartup = .starting
    private(set) var problem: String?
    private(set) var acceptedCreation: (command: UUID, commit: UUID, reference: LibraryReference)?
    var editor: LibraryEditorAdapter { coordinator.editor }
    private let changed: () -> Void
    var perfMutationCompleted: ((LibraryLiveMutation) -> Void)?
    var perfMutationFailed: (() -> Void)?
    func perfRefresh(_ menu: EverydayMenu, apps: [SourceAppInfo]) {
        guard let snapshot, let menuData else { return }
        menu.update(data: menuData, pendingApps: [], apps: apps, comparing: snapshot.compareOriginal,
                    compareAvailable: false, problem: nil)
    }
    private let checkpointDelay: @Sendable () async throws -> Void
    private var debounce: Task<Void, Never>?
    private var gesturing = false
    private var saveEpoch: UInt64 = 0
    private let editRead: LibraryListeningCoordinator.EditRead
    private let read: LibraryListeningCoordinator.Read
    private let move: LibraryListeningCoordinator.Move?
    private(set) lazy var coordinator = LibraryListeningCoordinator(
        publish: { [weak self] in self?.receive($0) }, read: read, editRead: editRead, move: move)

    init(changed: @escaping () -> Void,
         read: @escaping LibraryListeningCoordinator.Read = { try await $0.snapshot() },
         editRead: @escaping LibraryListeningCoordinator.EditRead = { try await $0.inspectEdit($1) },
         checkpointDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(200)) },
         move: LibraryListeningCoordinator.Move? = nil) {
        self.move = move
        self.changed = changed; self.read = read; self.editRead = editRead; self.checkpointDelay = checkpointDelay
    }
    private func receive(_ event: LibraryConsumerEvent) {
        if let receipt = event.rosterReceipt { roster.receive(receipt) }
        switch event {
        case .state(let publication):
            if snapshot != publication.snapshot {
                snapshot = publication.snapshot
                menuData = MenuSoundData(projection: publication.menu)
            }
            snapshotGeneration = publication.generation
            roster.update(publication.snapshot)
            if let failure = publication.admissionFailure { problem = failure }
        case .startup(let status):
            startup = status
            switch status {
            case .starting, .existing, .fresh, .migrated: break
            default: problem = String(describing: status)
            }
        case .command(let result):
            switch result.outcome {
            case .accepted: break
            default: problem = "The change could not be saved. \(result.outcome)"
            }
        case .editorMutation: scheduleSave()
        case .editor(let state):
            if let failure = state.failure { problem = failure }
        case .creationAccepted(let command, let commit, let reference):
            acceptedCreation = (command, commit, reference)
        case .readFailure(let reason): problem = reason
        default: break
        }
        changed()
    }
    func start(persistence: any LibraryPersistence, limits: LibraryLimits,
               migrationSource: LibraryMigrationSource? = nil) async {
        await coordinator.start(persistence: persistence, limits: limits, migrationSource: migrationSource,
                                freshPreparation: LibraryFreshPreparation.safariEveryday, builtins: .quickMenu)
    }
    var isReady: Bool { snapshot != nil && coordinator.lifecycle == .running }
    var neutral: ListeningRenderSnapshot? { snapshot.map(ListeningRenderSnapshot.init(library:)) }

    /// Admission and identity binding happen synchronously, before the command Task exists.
    @discardableResult
    func toggle(_ target: String, id: UUID = UUID()) -> Bool {
        request(roster.committed.contains(target) ? .remove : .add, target: target, id: id)
    }
    @discardableResult
    func request(_ direction: LibraryRosterRequests.Direction, target: String, id: UUID = UUID()) -> Bool {
        guard coordinator.lifecycle == .running, let snapshot else { return false }
        let removing = direction == .remove
        let definition = removing ? nil : snapshot.definitions.first(where: \.inTheMenu)?.id
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
        switch action {
        case .beginGesture:
            coordinator.sealSliderMoves()
            gesturing = true
            saveEpoch &+= 1
            cancelPendingSave()
        case .endGesture:
            guard gesturing else { return }
            gesturing = false
            _ = flushSave()
        case .putOn(let target): _ = request(.add, target: target)
        case .selectBlock(let definition, let target): select(definition, on: target)
        case .setEnabled(let enabled): live { try $0.submitEnabled(enabled) }
        case .libraryPower(let binding, let enabled): live { try $0.submitEnabled(enabled, expected: binding) }
        case .libraryMove(let binding, let address, let position):
            listen(binding, address, position, option: nil)
        case .libraryOptionMove(let binding, let address, let gesture, let position):
            listen(binding, address, position, option: gesture)
        case .compare(let comparing): live(save: false) { try $0.submitCompare(comparing) }
        default: break
        }
    }
    private func listen(_ binding: LibraryBinding, _ address: LibraryControlAddress,
                        _ position: LibraryPosition, option: LibraryOptionGesture?) {
        let card = menuData?.assignments.first { $0.binding == binding }
        let controls = (card?.controls ?? []) + (card?.optionTabs.flatMap(\.controls) ?? [])
        let slider = controls.contains { control in
            guard control.address == address, control.optionGesture == option, case .slider = control.face else { return false }
            return true
        }
        guard slider, case .scalar = position else {
            live { try $0.submitMove(address, expected: binding, to: position, optionGesture: option) }
            return
        }
        do {
            let task = try coordinator.submitSliderMove(address, expected: binding, to: position, optionGesture: option)
            let epoch = saveEpoch
            Task {
                do {
                    switch try await task.value {
                    case .coalesced: break
                    case .executed(let result):
                        perfMutationCompleted?(result)
                        coordinator.requestRefresh()
                        if !gesturing && epoch == saveEpoch { scheduleSave() }
                    }
                } catch { perfMutationFailed?(); record(error) }
            }
        } catch { perfMutationFailed?(); record(error) }
    }
    private func live(save: Bool = true,
                      _ action: (LibraryListeningCoordinator) throws -> Task<LibraryLiveMutation, Error>) {
        do {
            let task = try action(coordinator)
            let epoch = saveEpoch
            Task {
                do {
                    let result = try await task.value
                    perfMutationCompleted?(result)
                    coordinator.requestRefresh()
                    if save && !gesturing && epoch == saveEpoch { scheduleSave() }
                }
                catch { perfMutationFailed?(); record(error) }
            }
        } catch { perfMutationFailed?(); record(error) }
    }
    private func record(_ error: Error) {
        guard coordinator.lifecycle != .closed else { return }
        problem = "The change could not be saved. \(error)"; changed()
        if gesturing { gesturing = false; _ = flushSave() }
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
    @discardableResult func menuOpened() -> Task<Void, Never> { Task { await coordinator.onMenuOpen() } }
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
            coordinator.requestRefresh(); editor.requestDisplay()
        }
    }
    @discardableResult
    func flushSave() -> Task<LibraryConsumerCommandResult, Never>? {
        cancelPendingSave()
        saveEpoch &+= 1
        guard coordinator.lifecycle == .running else { return nil }
        let task = coordinator.submitCheckpoint()
        Task { _ = await task.value; coordinator.requestRefresh(); editor.requestDisplay() }
        return task
    }
    func beginDrain() {
        gesturing = false
        saveEpoch &+= 1
        debounce?.cancel(); debounce = nil
        _ = coordinator.beginDrain()
    }
    func finishDrain(_ mode: LibraryDrainMode) async -> LibraryDrainResult { await coordinator.finishDrain(mode) }
    @discardableResult func cancelDrain() -> Bool {
        let cancelled = coordinator.cancelDrain()
        if cancelled { Task { await coordinator.refresh() } }
        return cancelled
    }
    func close() { debounce?.cancel(); debounce = nil; coordinator.closePublications() }
}

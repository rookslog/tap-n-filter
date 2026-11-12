import Combine
import Foundation
import SoundModel

struct TNFEditorActionFailure: Error { let action: UUID; let underlying: Error }

enum TNFEditorError: Error { case noSelection, readOnly, stale, noLane, busy, checkpoint }
enum TNFEditorGestureSubject: Equatable {
    case control(LibraryControlAddress)
    case physical(UUID, String)
    case response([UUID], UUID)
}

struct TNFEditorOptionPlan {
    let request: LibraryEditorRequest
    let preview: LibraryOptionEditPreview
}
struct TNFEditorUpdatePlan {
    let request: LibraryEditorRequest
    let preview: LibraryUpdatePreview
}

/// Presentation and command routing only. The adapter owns admission, history and durable work.
@MainActor final class TNFEditorCommands: ObservableObject {
    let app: LibraryAppSession
    @Published private(set) var target: LibraryEditTarget?
    @Published private(set) var projection: LibraryEditorMappingRead?
    @Published private(set) var editing = false
    @Published private(set) var error: String?
    @Published private(set) var offerMakeOwn = false
    @Published private(set) var optionPlan: TNFEditorOptionPlan?
    @Published private(set) var updatePlan: TNFEditorUpdatePlan?
    @Published private(set) var selectorPlan: (LibraryEditorRequest, LibrarySelectorPreview)?
    @Published private(set) var reportCommands: [UUID] = []
    @Published var openControls = Set<LibraryControlAddress>()
    @Published var openPart: UUID?
    @Published var openBlock: [UUID]?
    @Published var appIdentities: [String: TNFEditorAppIdentity] = [:]
    var appIdentityResolver: (@MainActor (String) -> TNFEditorAppIdentity)?
    @Published var sidebarVisible = true
    @Published var librarySearch = ""
    @Published var renameSheet: TNFEditorRename?
    @Published var updateChooser = false
    @Published var newControlKind: TNFEditorControlKind?
    @Published var focusedControl: LibraryControlAddress?
    @Published var windowPresented = false
    @Published var compareAvailable = false
    private var displayTask: Task<Void, Never>?
    private var wantedDisplay = false
    private var readTask: (UUID, Task<Bool, Error>)?
    private var activeCommands = 0
    private var retired = false
    private var changingLifetime = false
    private var gesture: (LibraryEditorToken, TNFEditorGestureSubject, UUID)?
    private var feedbackActions = Set<UUID>()
    private let feedback: @MainActor () -> Void
    var lastOpenToggle: TNFEditorOpenToggle?
    @Published var collapsedTree = Set<TNFEditorTreeKey>()
    private(set) var optionNames: [UUID: String] = [:]
    private(set) var controlNames: [UUID: String] = [:]

    init(app: LibraryAppSession, feedback: @escaping @MainActor () -> Void = {}) { self.app = app; self.feedback = feedback }
    var adapter: LibraryEditorAdapter { app.editor }
    var edit: LibraryEditSnapshot? { adapter.state.target == target ? adapter.state.edit : nil }
    var binding: LibraryBinding? { if case .use(let value) = target { return value }; return nil }
    var definition: LibraryDefinitionSummary? {
        let id: UUID?
        switch target {
        case .definition(let value): id = value
        case .use(let value): id = app.presentation?.uses.first { $0.id == value.use }?.definition
        case nil: id = nil
        }
        return app.presentation?.definitions.first { $0.id == id }
    }
    var use: LibraryUseSummary? { binding.flatMap { b in app.presentation?.uses.first { $0.id == b.use } } }
    var title: String { use?.name ?? definition?.name ?? "Library" }
    var controls: [LibraryControl] { edit?.controls ?? use?.controls ?? definition?.controls ?? [] }
    var isReadOnly: Bool { binding == nil && edit == nil && definition?.origin != "custom" }
    var canAuthor: Bool { !retired && !changingLifetime && adapter.state.canEdit && !isReadOnly }
    var reports: [LibraryEditorReportReceipt] { reportCommands.compactMap { adapter.reports[$0] } }

    func receiveOwnerChange() {
        if windowPresented { refreshAppIdentities() }
        objectWillChange.send()
        for control in (app.presentation?.definitions.flatMap(\.controls) ?? []) + (app.presentation?.uses.flatMap(\.controls) ?? []) {
            if controlNames[control.id] == nil { controlNames[control.id] = control.title }
            if case .choice(let options) = control.face { for option in options where optionNames[option.id] == nil { optionNames[option.id] = option.title } }
        }
        collectReports()
        guard !retired, activeCommands == 0, optionPlan == nil, updatePlan == nil, selectorPlan == nil else { return }
        wantedDisplay = true
        guard displayTask == nil else { return }
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                wantedDisplay = false
                do { try await refresh() } catch { self.error = String(describing: error) }
            } while wantedDisplay && !retired && app.coordinator.lifecycle == .running
            displayTask = nil
        }
    }
    func refresh() async throws {
        while !retired {
            let id: UUID, task: Task<Bool, Error>
            if let pending = readTask { id = pending.0; task = pending.1 }
            else {
                id = UUID()
                task = Task { @MainActor in try await self.readProjection() }
                readTask = (id, task)
            }
            let installed: Bool
            do { installed = try await task.value }
            catch { if readTask?.0 == id { readTask = nil }; throw error }
            if readTask?.0 == id { readTask = nil }
            if installed, projection?.snapshot.generation == adapter.state.edit?.generation { return }
            if adapter.token == nil || adapter.state.target != target { return }
            await Task.yield()
        }
    }
    private func readProjection() async throws -> Bool {
        guard !retired, let token = adapter.token, adapter.state.target == target else { return true }
        let query = try adapter.mappings(token)
        switch await query.completion.value {
        case .value(let request, let value):
            guard adapter.isCurrent(request), target == value.snapshot.handle.target else { return false }
            projection = value
            for descriptor in value.mappings.descriptors {
                guard let control = descriptor.presentation else { continue }
                controlNames[control.id] = control.title
                if case .choice(let options) = control.face { for option in options { optionNames[option.id] = option.title } }
            }
        case .superseded: return false
        case .refused(_, let failure): throw failure
        }
        collectReports()
        return true
    }
    func select(_ next: LibraryEditTarget) async throws {
        guard !changingLifetime else { throw TNFEditorError.busy }
        if !retired, target == next, adapter.token != nil || isReadOnly {
            try await refresh()
            return
        }
        changingLifetime = true
        app.cancelPendingSave()
        defer { changingLifetime = false }
        try await cancelPreview()
        try await settleGesture()
        if adapter.token != nil {
            app.cancelPendingSave()
            try requireCheckpoint(await app.coordinator.submitCheckpoint().value)
        }
        let readOnlyDefinition: Bool
        if case .definition(let id) = next {
            let (current, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
            guard let definition = current.definitions.first(where: { $0.id == id }) else { throw LibraryError.unknownDefinition }
            readOnlyDefinition = definition.origin != "custom"
        } else { readOnlyDefinition = false }
        if readOnlyDefinition {
            if let token = adapter.token { _ = try await accept(adapter.done(token)) }
        } else {
            _ = try await accept(adapter.select(next))
        }
        retired = false; editing = false; target = next; projection = nil
        openControls = []; openPart = nil; openBlock = nil; focusedControl = nil; error = nil; offerMakeOwn = false
        try await refresh()
    }
    func selectInitial(preferredApp: String? = nil) async throws {
        guard let snapshot = app.presentation else { throw TNFEditorError.noSelection }
        let assignment = snapshot.assignments.first { $0.target == (preferredApp ?? "com.apple.Safari") }
            ?? snapshot.assignments.first
        if let assignment {
            try await select(.use(LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)))
        } else if let definition = snapshot.definitions.first { try await select(.definition(definition.id)) }
    }
    @discardableResult
    func accept(_ receipt: LibraryEditorReceipt) async throws -> LibraryEditSnapshot? {
        activeCommands += 1
        defer { activeCommands -= 1 }
        let outcome = await receipt.completion.value
        collectReports()
        switch outcome {
        case .model(let value): return value
        case .reported(let value): return value.snapshot
        case .publication(let result, let snapshot):
            switch result.outcome {
            case .accepted: return snapshot
            case .refused, .failed: fail(TNFEditorActionFailure(action: result.command, underlying: TNFEditorError.noSelection)); return snapshot
            default: error = String(describing: result.outcome); return snapshot
            }
        case .closed: return nil
        case .failure(let value): throw TNFEditorActionFailure(action: receipt.command, underlying: value)
        case .refused(let reason): error = reason; throw TNFEditorError.stale
        }
    }
    func command(_ command: LibraryEditCommand, gesture: UUID? = nil) async throws {
        guard editing, canAuthor, let token = adapter.token else { throw TNFEditorError.readOnly }
        _ = try await accept(adapter.submit(token, command: command, gesture: gesture))
        try await refresh()
    }
    func mapping(_ command: LibraryMappingCommand, path: [UUID] = []) async throws {
        try await self.command(.mapping(path: path, command))
    }
    func startEditing() throws {
        guard canAuthor else { throw TNFEditorError.readOnly }
        editing = true
    }
    private func settleGesture() async throws {
        guard let (token, _, id) = gesture else { return }
        let receipt = try adapter.barrier(token, .end(id))
        gesture = nil
        _ = try await accept(receipt)
        // End acknowledgement can schedule a timer. Cancel it before the display read,
        // which may be slow; this does not cancel an already-issued durable write.
        app.cancelPendingSave()
        try await refresh()
    }
    func done() async throws {
        guard !changingLifetime else { throw TNFEditorError.busy }
        guard adapter.token != nil else { throw TNFEditorError.noSelection }
        changingLifetime = true
        app.cancelPendingSave()
        defer { changingLifetime = false }
        try await cancelPreview()
        try await settleGesture()
        editing = false
        app.cancelPendingSave()
        let checkpoint = await app.coordinator.submitCheckpoint().value
        await app.coordinator.refresh()
        try await refresh()
        try requireCheckpoint(checkpoint)
    }
    func discard() async throws {
        guard let token = adapter.token, canAuthor else { throw TNFEditorError.noSelection }
        _ = try await accept(adapter.barrier(token, .discard)); try await refresh()
    }
    func history(redo: Bool) async throws {
        guard let token = adapter.token, canAuthor else { throw TNFEditorError.noSelection }
        _ = try await accept(adapter.barrier(token, redo ? .redo : .undo)); try await refresh()
    }
    func move(_ address: LibraryControlAddress, to value: Double) async throws {
        try await consume(admitMove(address, to: value))
    }
    func admitMove(_ address: LibraryControlAddress, to value: Double) throws -> LibraryEditorReceipt? {
        if editing {
            guard canAuthor, let token = adapter.token else { throw TNFEditorError.readOnly }
            let gesture = gestureID(.control(address))
            return try adapter.submit(token, command: .moveControl(address, .scalar(value)), gesture: gesture)
        }
        else {
            guard let binding else { throw TNFEditorError.readOnly }
            app.send(.libraryMove(binding, address, .scalar(value)))
            return nil
        }
    }
    func consume(_ receipt: LibraryEditorReceipt?) async throws {
        if let receipt { _ = try await accept(receipt) }
        try await refresh()
    }
    var positionGestureActive: Bool { gesture != nil }
    var positionGestureActiveControl: Bool { if let (_, subject, _) = gesture, case .control = subject { return true }; return false }
    var positionGestureActivePhysical: Bool { if let (_, subject, _) = gesture, case .physical = subject { return true }; return false }
    private func gestureID(_ subject: TNFEditorGestureSubject) -> UUID? {
        gesture.flatMap { $0.0 == adapter.token && $0.1 == subject ? $0.2 : nil }
    }
    private func begin(_ subject: TNFEditorGestureSubject) throws {
        guard editing else { return }
        guard canAuthor, gesture == nil, let token = adapter.token else { throw TNFEditorError.busy }
        let id = UUID(); _ = try adapter.barrier(token, .begin(id)); gesture = (token, subject, id)
    }
    private func end(_ subject: TNFEditorGestureSubject) throws -> LibraryEditorReceipt? {
        guard let (token, actual, id) = gesture else { return nil }
        guard actual == subject else { throw TNFEditorError.busy }
        gesture = nil; return try adapter.barrier(token, .end(id))
    }
    func beginPositionGesture(_ address: LibraryControlAddress) throws { try begin(.control(address)) }
    func endPositionGesture() async throws { try await consume(admitEndPositionGesture()) }
    func admitEndPositionGesture() throws -> LibraryEditorReceipt? {
        guard let (_, subject, _) = gesture, case .control = subject else { return nil }
        return try end(subject)
    }
    func beginPhysicalGesture(part: UUID, parameter: String) throws { try begin(.physical(part, parameter)) }
    func admitPhysical(part: UUID, parameter: String, value: Double) throws -> LibraryEditorReceipt {
        guard editing, canAuthor, let token = adapter.token else { throw TNFEditorError.readOnly }
        return try adapter.submit(token, command: .setPhysical(part: part, parameter: parameter, value: value), gesture: gestureID(.physical(part, parameter)))
    }
    func admitEndPhysicalGesture() throws -> LibraryEditorReceipt? {
        guard let (_, subject, _) = gesture, case .physical = subject else { return nil }
        return try end(subject)
    }
    func beginResponseGesture(_ binding: LibraryMappingSummary) throws { try begin(.response(binding.path, binding.id)) }
    func admitResponse(_ binding: LibraryMappingSummary, command: LibraryMappingCommand) throws -> LibraryEditorReceipt {
        guard editing, canAuthor, let token = adapter.token else { throw TNFEditorError.readOnly }
        return try adapter.submit(token, command: .mapping(path: binding.path, command), gesture: gestureID(.response(binding.path, binding.id)))
    }
    func admitEndResponseGesture(_ binding: LibraryMappingSummary) throws -> LibraryEditorReceipt? { try end(.response(binding.path, binding.id)) }
    func renameControl(_ token: LibraryEditorToken, path: [UUID], control: UUID, title: String) async throws {
        guard adapter.token == token else { throw TNFEditorError.stale }
        _ = try await accept(adapter.submit(token, command: .mapping(path: path, .rename(control: control, title: title))))
        try await refresh()
    }
    func compare(_ held: Bool) { app.send(.compare(held)) }
    func rename(_ name: String, libraryName: Bool = false) async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.invalidPresentation }
        let result: LibraryConsumerCommandResult
        if let binding, !libraryName { result = await app.nameUse(binding, name: name).value }
        else if let definition { result = await app.rename(definition.id, name: name).value }
        else { throw TNFEditorError.noSelection }
        try requireAccepted(result); await app.coordinator.refresh(); try await refresh()
    }
    func useLibraryName() async throws {
        guard let binding else { throw TNFEditorError.noSelection }
        try requireAccepted(await app.nameUse(binding, name: nil).value)
        await app.coordinator.refresh()
    }
    func setInMenu(_ value: Bool) async throws {
        guard let definition else { throw TNFEditorError.noSelection }
        try requireAccepted(await app.setInMenu(definition.id, visible: value).value)
        await app.coordinator.refresh()
    }
    func makeItsOwn() async throws {
        guard let binding else { throw TNFEditorError.noSelection }
        let wasEditing = editing
        try requireAccepted(await app.createFromUse(binding, name: title).value)
        await app.coordinator.refresh()
        let (current, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        if target == .use(binding), let assignment = current.assignments.first(where: { $0.id == binding.assignment && $0.target == binding.target }) {
            try await select(.use(LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)))
            if wasEditing { try startEditing() }
        }
    }
    private func requireCheckpoint(_ result: LibraryConsumerCommandResult) throws {
        do { try requireAccepted(result) }
        catch { throw TNFEditorError.checkpoint }
    }
    func requireAccepted(_ result: LibraryConsumerCommandResult) throws {
        guard case .accepted = result.outcome else { error = String(describing: result.outcome); throw TNFEditorActionFailure(action: result.command, underlying: TNFEditorError.checkpoint) }
    }
    func connect(source: LibraryMappingControlDescriptor, target: LibraryMappingTarget, selector: UUID? = nil) async throws {
        guard let control = source.presentation else { throw TNFEditorError.readOnly }
        let command: LibraryMappingCommand
        if let selector { command = .connectOptions(id: UUID(), source: LibraryMappingSource(control.id), target: target, selector: selector) }
        else if source.storage == .legacy, case .slider = control.face, case .setting(let part, let parameter) = target {
            command = .connectLegacy(source: LibraryMappingSource(control.id), part: part, parameter: parameter)
        } else { command = .connect(id: UUID(), source: LibraryMappingSource(control.id), target: target) }
        try await mapping(command, path: source.address.path)
    }
    func previewOption(_ address: LibraryControlAddress, mutation: LibraryOptionMutation) async throws {
        await displayTask?.value
        try await refresh()
        guard editing, let token = adapter.token else { throw TNFEditorError.readOnly }
        let query = try adapter.previewOption(token, address: address, mutation: mutation)
        switch await query.completion.value {
        case .value(let request, let preview):
            guard adapter.isCurrent(request) else { throw TNFEditorError.stale }
            optionPlan = TNFEditorOptionPlan(request: request, preview: preview)
        case .superseded: throw TNFEditorError.stale
        case .refused(_, let reason): throw reason
        }
    }
    func applyOption() async throws {
        guard let plan = optionPlan else { throw TNFEditorError.noSelection }
        let receipt = try adapter.applyOption(plan.request, preview: plan.preview)
        optionPlan = nil
        _ = try await accept(receipt)
        try await refresh()
    }
    func previewUpdate(places: [LibraryUpdatePlace], replacements: [LibraryOptionReplacement] = []) async throws {
        await displayTask?.value
        guard let token = adapter.token else { throw TNFEditorError.noSelection }
        try await cancelPreview()
        let query = try adapter.previewUpdate(token, places: places, replacements: replacements)
        switch await query.completion.value {
        case .value(let request, let preview):
            guard adapter.isCurrent(request) else { throw TNFEditorError.stale }
            updatePlan = TNFEditorUpdatePlan(request: request, preview: preview)
        case .superseded: throw TNFEditorError.stale
        case .refused(_, let reason):
            if binding != nil {
                switch reason { case .model(.protectedBuiltin), .model(.unsupportedEdit): offerMakeOwn = true; default: break }
            }
            throw reason
        }
    }
    func confirmUpdate() async throws {
        guard let plan = updatePlan else { throw TNFEditorError.noSelection }
        let receipt = try adapter.confirmUpdate(plan.request, preview: plan.preview)
        updatePlan = nil
        _ = try await accept(receipt)
        try await refresh()
    }
    func cancelPreview() async throws {
        optionPlan = nil; selectorPlan = nil
        if let plan = updatePlan {
            updatePlan = nil
            _ = await (try adapter.cancelUpdate(plan.request.token, preview: plan.preview)).completion.value
        }
    }
    func previewSameForAll(path: [UUID], source: UUID) async throws {
        await displayTask?.value
        try await refresh()
        guard editing, let token = adapter.token else { throw TNFEditorError.readOnly }
        let query = try adapter.previewSelector(token, path: path, source: source)
        switch await query.completion.value {
        case .value(let request, let value):
            guard adapter.isCurrent(request) else { throw TNFEditorError.stale }
            selectorPlan = (request, value)
        case .superseded: throw TNFEditorError.stale
        case .refused(_, let reason): throw reason
        }
    }
    func applySameForAll() async throws {
        guard let (request, preview) = selectorPlan else { throw TNFEditorError.noSelection }
        let receipt = try adapter.applySelector(request, preview: preview)
        selectorPlan = nil
        _ = try await accept(receipt); try await refresh()
    }
    func collectReports() {
        for (id, report) in adapter.reports {
            let empty: Bool
            switch report.report {
            case .choice(let value): empty = value.changes.isEmpty
            case .update: empty = false
            }
            if empty { _ = adapter.acknowledgeReport(id) }
            else if !reportCommands.contains(id) { reportCommands.append(id) }
        }
        // The old status Close was a reservation owner. Definitive no-report outcomes now
        // retire here; acknowledgeReport itself refuses pending/uncertain publications.
        for (id, record) in adapter.publications where record.initial != nil && adapter.reports[id] == nil {
            if adapter.acknowledgeReport(id) { reportCommands.removeAll { $0 == id } }
        }
    }
    func acknowledgeReport(_ command: UUID) {
        if adapter.acknowledgeReport(command) { reportCommands.removeAll { $0 == command } }
    }
    func reconcilePublication() async { await app.coordinator.onMenuOpen(); collectReports() }
    @discardableResult func menuOpened() -> Task<Void, Never> { app.menuOpened() }
    func close() async throws {
        guard !changingLifetime else { throw TNFEditorError.busy }
        changingLifetime = true
        app.cancelPendingSave()
        defer { changingLifetime = false }
        compare(false); try await cancelPreview()
        try await settleGesture()
        app.cancelPendingSave()
        try requireCheckpoint(await app.coordinator.submitCheckpoint().value)
        if let token = adapter.token { _ = try await accept(adapter.done(token)) }
        retired = true; projection = nil; editing = false
    }
    func prepareQuit() { compare(false); gesture = nil }
    func requestRename() {
        if let binding { renameSheet = TNFEditorRename(title: title, action: .use(binding)) }
        else if let definition { renameSheet = TNFEditorRename(title: title, action: .definition(definition.id)) }
    }
    func validateCallback(_ token: LibraryEditorToken?) throws {
        guard !changingLifetime else { throw TNFEditorError.busy }
        guard token == adapter.token else { throw TNFEditorError.stale }
    }
    func quickBypass(_ part: UUID, bypassed: Bool) async throws {
        guard let token = adapter.token, canAuthor else { throw TNFEditorError.readOnly }
        _ = try await accept(adapter.submit(token, command: .bypassPart(part, bypassed))); try await refresh()
    }
    func fail(_ failure: Error) {
        let action = (failure as? TNFEditorActionFailure)?.action
        let underlying = (failure as? TNFEditorActionFailure)?.underlying ?? failure
        switch underlying {
        case TNFEditorError.stale, LibraryEditorFailure.admission(.staleSelection), LibraryEditorFailure.model(.staleEdit), LibraryEditorFailure.model(.staleBinding):
            // A stale callback is not a fresh user action. Refresh the same owner; no replay/reseat.
            receiveOwnerChange(); return
        case TNFEditorError.readOnly, TNFEditorError.busy, LibraryEditorFailure.admission(.unavailable), LibraryEditorFailure.admission(.gestureMismatch): return
        case TNFEditorError.checkpoint: return // durability carries this, with no alert or retry
        default: break
        }
        self.error = String(describing: underlying) // internal diagnostic only
        if let action { guard feedbackActions.insert(action).inserted else { return } }
        feedback()
    }
    func clearError() { error = nil; offerMakeOwn = false }
}

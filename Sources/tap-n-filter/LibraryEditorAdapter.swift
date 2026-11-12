import Foundation
import SoundModel
import PlaybackRenderBridge

enum LibraryEditorAdmissionError: Error, Sendable { case unavailable, staleSelection, gestureMismatch, capacity, oversized }
struct LibraryEditorToken: Equatable, Sendable {
    let epoch: UUID
    let handle: LibraryEditHandle
}
enum LibraryEditorOutcome: Sendable {
    case model(LibraryEditSnapshot)
    case reported(LibraryOptionEditResult)
    case publication(LibraryConsumerCommandResult, LibraryEditSnapshot?)
    case failure(LibraryEditorFailure)
    case closed
    case refused(String)
}
struct LibraryEditorReceipt {
    let command: UUID
    let gesture: UUID?
    let epoch: UUID?
    let handle: LibraryEditHandle?
    let sequence: UInt64
    let completion: Task<LibraryEditorOutcome, Never>
}
struct LibraryEditorState {
    let epoch: UUID?
    let target: LibraryEditTarget?
    let sequence: UInt64
    let edit: LibraryEditSnapshot?
    let coverage: LibrarySaveCoverage?
    let failure: String?
    var canEdit: Bool { edit != nil && failure == nil }
}

enum LibraryEditorFailure: Error, Sendable {
    case admission(LibraryEditorAdmissionError)
    case model(LibraryError)
    case option(LibraryOptionError)
    case other(String)
    init(_ error: Error) {
        if let e = error as? LibraryEditorAdmissionError { self = .admission(e) }
        else if let e = error as? LibraryError { self = .model(e) }
        else if let e = error as? LibraryOptionError { self = .option(e) }
        else { self = .other(String(describing: error)) }
    }
}
struct LibraryEditorRequest: Equatable, Sendable {
    let command: UUID
    let token: LibraryEditorToken
    let sequence: UInt64
    let generation: UInt64
}
enum LibraryEditorReply<Value: Sendable>: Sendable {
    case value(LibraryEditorRequest, Value)
    case superseded(LibraryEditorRequest)
    case refused(LibraryEditorRequest, LibraryEditorFailure)
}
struct LibraryEditorQuery<Value: Sendable> {
    let request: LibraryEditorRequest
    let completion: Task<LibraryEditorReply<Value>, Never>
}
struct LibraryEditorMappingRead: Sendable {
    let snapshot: LibraryEditSnapshot
    let mappings: LibraryMappingSnapshot
}
enum LibraryEditorSemanticReport: Sendable {
    case choice(LibraryChoiceReport)
    case update(LibraryUpdateReport)
}
struct LibraryEditorReportReceipt: Sendable {
    let request: LibraryEditorRequest
    let report: LibraryEditorSemanticReport
    let commit: UUID?
}
struct LibraryEditorPublicationState: Sendable {
    let request: LibraryEditorRequest
    let initial: LibraryConsumerCommandResult?
    let reconciliation: LibraryConsumerReconciliation?
    let snapshot: LibraryEditSnapshot?
}

@MainActor
final class LibraryEditorAdapter {
    private final class Context {
        let epoch = UUID()
        let target: LibraryEditTarget
        var snapshot: LibraryEditSnapshot?
        var plannedGesture: UUID?
        var activeGesture: UUID?
        var stoppedGesture: UUID?
        var drainFencedGesture: UUID?
        var invalidReason: String?
        init(_ target: LibraryEditTarget) { self.target = target }
    }
    enum Barrier { case begin(UUID), end(UUID), cancel(UUID), undo, redo, discard }
    private weak var coordinator: LibraryListeningCoordinator?
    private var context: Context?
    private var sequence: UInt64 = 0
    private var queued = 0
    private var reportReservations = Set<UUID>()
    private var previewLeases: [UUID: (LibraryEditorToken, LibraryUpdatePreview)] = [:]
    private(set) var reports: [UUID: LibraryEditorReportReceipt] = [:]
    private(set) var publications: [UUID: LibraryEditorPublicationState] = [:]
    private var accepting = true
    private(set) var drainFailure: String?
    private var displayTask: Task<Void, Never>?
    private var displayWanted = false
    private(set) var state = LibraryEditorState(epoch: nil, target: nil, sequence: 0, edit: nil, coverage: nil, failure: nil)
    var token: LibraryEditorToken? {
        guard let context, let snapshot = context.snapshot else { return nil }
        return LibraryEditorToken(epoch: context.epoch, handle: snapshot.handle)
    }
    init(coordinator: LibraryListeningCoordinator) { self.coordinator = coordinator }
    private func publish(_ selected: Context?, edit: LibraryEditSnapshot?, coverage: LibrarySaveCoverage? = nil, failure: String? = nil) {
        guard context?.epoch == selected?.epoch else { return }
        state = LibraryEditorState(epoch: selected?.epoch, target: selected?.target, sequence: sequence,
            edit: edit, coverage: coverage, failure: selected?.invalidReason ?? failure)
        coordinator?.publishEditor(state)
    }
    private func matchingContext(_ token: LibraryEditorToken) throws -> Context {
        guard accepting, coordinator?.lifecycle == .running else { throw LibraryEditorAdmissionError.unavailable }
        guard let context, context.epoch == token.epoch, context.snapshot?.handle == token.handle else {
            throw LibraryEditorAdmissionError.staleSelection
        }
        return context
    }
    private func check(_ token: LibraryEditorToken) throws -> Context {
        let selected = try matchingContext(token)
        guard selected.invalidReason == nil else { throw LibraryEditorAdmissionError.staleSelection }
        return selected
    }
    private func capacity(barrier: Bool, textBytes: Int = 0) throws {
        guard textBytes <= 8192 else { throw LibraryEditorAdmissionError.oversized }
        guard queued < (barrier ? 264 : 256) else { throw LibraryEditorAdmissionError.capacity }
    }
    private func queue(_ selected: Context?, barrier: Bool, gesture: UUID? = nil, reporting: Bool = false,
        operation: @escaping @MainActor @Sendable (SoundLibrarySession) async throws -> LibraryEditorOutcome) throws -> LibraryEditorReceipt {
        try capacity(barrier: barrier)
        guard let coordinator else { throw LibraryEditorAdmissionError.unavailable }
        let command = UUID()
        if reporting { try reserveReport(command) }
        queued += 1; sequence += 1
        let admittedSequence = sequence
        let handle = selected?.snapshot?.handle
        let task: Task<LibraryEditorOutcome, Error>
        do {
            task = try coordinator.enqueueMutation { [self] session in
                defer { queued -= 1 }
                do {
                    let result = try await operation(session)
                    sequence += 1
                    switch result {
                    case .model(let snapshot): acknowledge(snapshot, selected: selected, command: command)
                    case .reported(let value):
                        if let selected, let handle = selected.snapshot?.handle {
                            reports[command] = LibraryEditorReportReceipt(request: LibraryEditorRequest(command: command,
                                token: LibraryEditorToken(epoch: selected.epoch, handle: handle), sequence: admittedSequence,
                                generation: value.snapshot.generation), report: .choice(value.report), commit: nil)
                        }
                        acknowledge(value.snapshot, selected: selected, command: command)
                    default: publish(context, edit: context?.snapshot)
                    }
                    requestDisplay()
                    coordinator.requestRefresh()
                    return result
                } catch {
                    if reporting { reportReservations.remove(command) }
                    if let error = error as? LibraryError, error == .staleEdit || error == .staleBinding {
                        selected?.invalidReason = String(describing: error)
                        if let gesture { selected?.stoppedGesture = gesture }
                    }
                    sequence += 1
                    publish(selected, edit: selected?.snapshot, failure: String(describing: error))
                    coordinator.requestRefresh()
                    throw error
                }
            }
        } catch { queued -= 1; reportReservations.remove(command); throw error }
        publish(context, edit: context?.snapshot)
        let completion = Task {
            do { return try await task.value }
            catch { return LibraryEditorOutcome.failure(LibraryEditorFailure(error)) }
        }
        return LibraryEditorReceipt(command: command, gesture: gesture, epoch: selected?.epoch,
            handle: handle, sequence: admittedSequence, completion: completion)
    }
    private func acknowledge(_ snapshot: LibraryEditSnapshot, selected: Context?, command: UUID) {
        let prior = selected?.snapshot?.generation
        selected?.snapshot = snapshot
        publish(selected, edit: snapshot)
        if let prior, prior != snapshot.generation { coordinator?.editorAcknowledged(command) }
    }
    private func reserveReport(_ command: UUID) throws {
        guard reportReservations.count < 64 else { throw LibraryEditorAdmissionError.capacity }
        reportReservations.insert(command)
    }
    @discardableResult func acknowledgeReport(_ command: UUID) -> Bool {
        if let pending = publications[command] {
            guard let initial = pending.initial else { return false }
            if case .unresolved = initial.outcome {
                switch pending.reconciliation {
                case .accepted, .refused, .superseded: break
                default: return false
                }
            }
        }
        guard reports[command] != nil || publications[command] != nil else { return false }
        reports[command] = nil; publications[command] = nil; reportReservations.remove(command)
        return true
    }
    func isCurrent(_ request: LibraryEditorRequest) -> Bool {
        accepting && coordinator?.lifecycle == .running && request.sequence == sequence &&
            context?.epoch == request.token.epoch && context?.snapshot?.handle == request.token.handle &&
            context?.snapshot?.generation == request.generation && context?.invalidReason == nil
    }
    private func query<Value: Sendable>(_ token: LibraryEditorToken,
        discard: (@MainActor @Sendable (LibraryListeningCoordinator, Value) async -> Void)? = nil,
        received: (@MainActor @Sendable (LibraryEditorRequest, Value) -> Void)? = nil,
        operation: @escaping @Sendable (SoundLibrarySession, LibraryEditSnapshot) async throws -> Value) throws -> LibraryEditorQuery<Value> {
        let selected = try check(token); try capacity(barrier: false)
        guard let before = selected.snapshot, let coordinator else { throw LibraryEditorAdmissionError.unavailable }
        sequence += 1; queued += 1
        let request = LibraryEditorRequest(command: UUID(), token: token, sequence: sequence, generation: before.generation)
        let completion = Task { @MainActor in
            defer { queued -= 1 }
            do {
                let (value, version) = try await coordinator.editorQuery { session in try await operation(session, before) }
                guard isCurrent(request), coordinator.editorObservationIsCurrent(version) else {
                    if let discard { await discard(coordinator, value) }
                    return LibraryEditorReply<Value>.superseded(request)
                }
                received?(request, value)
                return .value(request, value)
            } catch {
                return isCurrent(request) ? .refused(request, LibraryEditorFailure(error)) : .superseded(request)
            }
        }
        return LibraryEditorQuery(request: request, completion: completion)
    }
    func mappings(_ token: LibraryEditorToken) throws -> LibraryEditorQuery<LibraryEditorMappingRead> {
        guard let coordinator else { throw LibraryEditorAdmissionError.unavailable }
        return try query(token, received: { [self] (_: LibraryEditorRequest, value: LibraryEditorMappingRead) in
            // Only an admitted authoritative read may restore availability after a refused
            // action. A stale/invalid owner is still fenced by query/isCurrent.
            if state.failure != nil || state.edit != value.snapshot {
                publish(context, edit: value.snapshot, coverage: state.coverage)
            }
        }) { session, before in
            let snapshot = try await coordinator.editorInspect(session, before.handle), mappings = try await session.mappings(before.handle)
            guard snapshot.generation == before.generation, mappings.generation == snapshot.generation else { throw LibraryError.staleEdit }
            return LibraryEditorMappingRead(snapshot: snapshot, mappings: mappings)
        }
    }
    func previewSelector(_ token: LibraryEditorToken, path: [UUID], source: UUID) throws -> LibraryEditorQuery<LibrarySelectorPreview> {
        try capacity(barrier: false, textBytes: path.count * 16)
        return try query(token) { try await $0.previewSameForAll($1.handle, expectedGeneration: $1.generation, path: path, source: source) }
    }
    func applySelector(_ request: LibraryEditorRequest, preview: LibrarySelectorPreview) throws -> LibraryEditorReceipt {
        guard isCurrent(request), preview.handle == request.token.handle, preview.generation == request.generation else {
            throw LibraryEditorAdmissionError.staleSelection
        }
        return try submit(request.token, command: .mapping(path: preview.path, .sameForAll(preview)))
    }
    func previewOption(_ token: LibraryEditorToken, address: LibraryControlAddress, mutation: LibraryOptionMutation) throws -> LibraryEditorQuery<LibraryOptionEditPreview> {
        if case .add(_, let title, _) = mutation { try capacity(barrier: false, textBytes: title.utf8.count + address.path.count * 16) }
        return try query(token) { try await $0.previewOptionEdit($1.handle, expectedGeneration: $1.generation, address: address, mutation: mutation) }
    }
    func applyOption(_ request: LibraryEditorRequest, preview: LibraryOptionEditPreview) throws -> LibraryEditorReceipt {
        let selected = try check(request.token)
        guard isCurrent(request), preview.handle == request.token.handle, preview.generation == request.generation else { throw LibraryEditorAdmissionError.staleSelection }
        guard selected.plannedGesture == nil else { throw LibraryEditorAdmissionError.gestureMismatch }
        return try queue(selected, barrier: true, reporting: true) { .reported(try await $0.applyOptionEdit(preview)) }
    }
    func previewUpdate(_ token: LibraryEditorToken, places: [LibraryUpdatePlace], replacements: [LibraryOptionReplacement] = []) throws -> LibraryEditorQuery<LibraryUpdatePreview> {
        try capacity(barrier: false, textBytes: places.count * 32 + replacements.count * 48)
        return try query(token, discard: { await $0.cancelEditorPreview($1) }, received: { [self] request, preview in
            previewLeases[preview.id] = (request.token, preview)
        }) {
            try await $0.previewUpdateLibrary($1.handle, expectedGeneration: $1.generation, places: places, replacements: replacements)
        }
    }
    func cancelUpdate(_ token: LibraryEditorToken, preview: LibraryUpdatePreview) throws -> LibraryEditorQuery<Bool> {
        guard let lease = previewLeases[preview.id], lease.0 == token, lease.1 == preview,
              let coordinator, coordinator.lifecycle != .closed else { throw LibraryEditorAdmissionError.staleSelection }
        previewLeases[preview.id] = nil
        sequence += 1
        let request = LibraryEditorRequest(command: UUID(), token: token, sequence: sequence, generation: preview.generation)
        let completion = Task { @MainActor in
            await coordinator.cancelEditorPreview(preview)
            return LibraryEditorReply<Bool>.value(request, true)
        }
        return LibraryEditorQuery(request: request, completion: completion)
    }
    func confirmUpdate(_ request: LibraryEditorRequest, preview: LibraryUpdatePreview) throws -> LibraryEditorReceipt {
        let selected = try check(request.token)
        guard isCurrent(request), preview.handle == request.token.handle, preview.generation == request.generation,
              previewLeases[preview.id]?.0 == request.token, selected.plannedGesture == nil, let coordinator else { throw LibraryEditorAdmissionError.staleSelection }
        try capacity(barrier: true)
        let command = UUID(); try reserveReport(command)
        previewLeases[preview.id] = nil
        sequence += 1
        let admitted = sequence
        let bound = LibraryEditorRequest(command: command, token: request.token, sequence: admitted, generation: request.generation)
        publications[command] = LibraryEditorPublicationState(request: bound, initial: nil, reconciliation: nil, snapshot: nil)
        let task = coordinator.submitUpdate(preview, commandID: command)
        let completion = Task { @MainActor in
            let result = await task.value
            await receivePublication(result)
            return LibraryEditorOutcome.publication(result, publications[command]?.snapshot)
        }
        return LibraryEditorReceipt(command: command, gesture: nil, epoch: selected.epoch,
            handle: request.token.handle, sequence: admitted, completion: completion)
    }
    func receivePublication(_ result: LibraryConsumerCommandResult) async {
        guard let old = publications[result.command], old.initial == nil else { return }
        publications[result.command] = LibraryEditorPublicationState(request: old.request, initial: result, reconciliation: nil, snapshot: nil)
        if let report = result.publication?.acceptedReport {
            reports[result.command] = LibraryEditorReportReceipt(request: old.request, report: .update(report), commit: result.publication?.commit.token)
        }
        await acknowledgePublication(result.command)
    }
    func receiveReconciliation(command: UUID, commit: UUID, result: LibraryConsumerReconciliation, report: LibraryUpdateReport?) async {
        guard let old = publications[command], let initial = old.initial,
              case .unresolved(let receipt) = initial.outcome, receipt.token == commit, old.reconciliation == nil else { return }
        publications[command] = LibraryEditorPublicationState(request: old.request, initial: initial, reconciliation: result, snapshot: old.snapshot)
        if let report { reports[command] = LibraryEditorReportReceipt(request: old.request, report: .update(report), commit: commit) }
        await acknowledgePublication(command)
    }
    private func acknowledgePublication(_ command: UUID) async {
        guard let record = publications[command], let coordinator else { return }
        let selected = context, requested = sequence
        let snapshot = try? await coordinator.editorRead(record.request.token.handle).0
        if let snapshot, requested == sequence, selected?.epoch == record.request.token.epoch,
           selected?.snapshot?.handle == snapshot.handle {
            acknowledge(snapshot, selected: selected, command: command)
        }
        if let current = publications[command] {
            publications[command] = LibraryEditorPublicationState(request: current.request, initial: current.initial,
                reconciliation: current.reconciliation, snapshot: snapshot)
        }
        publish(context, edit: context?.snapshot)
        requestDisplay(); coordinator.requestRefresh()
    }
    private func close(_ old: Context?, session: SoundLibrarySession) async throws {
        guard let old, let snapshot = old.snapshot else { return }
        let leases = previewLeases.filter { $0.value.0.epoch == old.epoch }
        for (id, lease) in leases { await session.cancelUpdateLibrary(lease.1); previewLeases[id] = nil }
        let current: LibraryEditSnapshot
        do { current = try await session.inspectEdit(snapshot.handle) }
        catch LibraryError.staleEdit { return }
        catch LibraryError.staleBinding { return }
        var end = current
        // Fresh inspection here closes only this exact old handle. It never rebases samples.
        if old.activeGesture != nil {
            end = try await session.endEditGesture(current.handle, expectedGeneration: current.generation)
            old.activeGesture = nil
        }
        _ = try await session.doneEdit(end.handle, expectedGeneration: end.generation)
    }
    @discardableResult
    func select(_ target: LibraryEditTarget) throws -> LibraryEditorReceipt {
        guard accepting, coordinator?.readyForEditing == true else { throw LibraryEditorAdmissionError.unavailable }
        try capacity(barrier: true)
        guard let coordinator else { throw LibraryEditorAdmissionError.unavailable }
        let old = context, next = Context(target)
        context = next
        let receipt = try queue(next, barrier: true) { [self] session in
            try await close(old, session: session)
            return .model(try await session.beginEdit(target, admission: RenderAssignmentMapper.admitParts))
        }
        if old != nil { _ = coordinator.submitCheckpoint() }
        return receipt
    }
    @discardableResult
    func submit(_ token: LibraryEditorToken, command: LibraryEditCommand, gesture: UUID? = nil) throws -> LibraryEditorReceipt {
        let selected = try check(token)
        guard selected.plannedGesture == gesture else { throw LibraryEditorAdmissionError.gestureMismatch }
        let bytes: Int
        switch command {
        case .showAtTop(_, let parameter, let title): bytes = parameter.utf8.count + title.utf8.count
        case .addPart(let type, _): bytes = type.utf8.count
        case .setPhysical(_, let parameter, _): bytes = parameter.utf8.count
        case .reorderParts(let ids): bytes = ids.count * 16
        case .moveControl(let address, _): bytes = (address.path.count + 1) * 16
        default: bytes = 16
        }
        try capacity(barrier: false, textBytes: bytes)
        return try queue(selected, barrier: false, gesture: gesture) { session in
            guard selected.invalidReason == nil else { throw LibraryError.staleEdit }
            if let gesture, selected.stoppedGesture == gesture { throw LibraryError.staleEdit }
            guard let before = selected.snapshot else { throw LibraryError.staleEdit }
            return .model(try await session.edit(before.handle, expectedGeneration: before.generation, command: command))
        }
    }
    @discardableResult
    func barrier(_ token: LibraryEditorToken, _ barrier: Barrier) throws -> LibraryEditorReceipt {
        let selected = try check(token)
        try capacity(barrier: true)
        let gesture: UUID?
        switch barrier {
        case .begin(let id):
            guard selected.plannedGesture == nil, selected.drainFencedGesture != id else { throw LibraryEditorAdmissionError.gestureMismatch }
            selected.plannedGesture = id; gesture = id
        case .end(let id), .cancel(let id):
            guard selected.plannedGesture == id else { throw LibraryEditorAdmissionError.gestureMismatch }
            selected.plannedGesture = nil; gesture = id
        default:
            guard selected.plannedGesture == nil else { throw LibraryEditorAdmissionError.gestureMismatch }
            gesture = nil
        }
        let reporting: Bool
        switch barrier { case .undo, .redo: reporting = true; default: reporting = false }
        return try queue(selected, barrier: true, gesture: gesture, reporting: reporting) { session in
            guard let before = selected.snapshot else { throw LibraryError.staleEdit }
            let result: LibraryEditSnapshot
            switch barrier {
            case .begin(let id):
                result = try await session.beginEditGesture(before.handle, expectedGeneration: before.generation)
                selected.activeGesture = id
            case .end(let id):
                guard selected.stoppedGesture != id else { throw LibraryError.staleEdit }
                result = try await session.endEditGesture(before.handle, expectedGeneration: before.generation)
                selected.activeGesture = nil; selected.stoppedGesture = nil
            case .cancel(let id):
                guard selected.stoppedGesture != id else { throw LibraryError.staleEdit }
                result = try await session.cancelEditGesture(before.handle, expectedGeneration: before.generation)
                selected.activeGesture = nil; selected.stoppedGesture = nil
            case .undo: return .reported(try await session.undoOptionEdit(before.handle, expectedGeneration: before.generation))
            case .redo: return .reported(try await session.redoOptionEdit(before.handle, expectedGeneration: before.generation))
            case .discard: result = try await session.discardEdit(before.handle, expectedGeneration: before.generation)
            }
            return .model(result)
        }
    }
    @discardableResult
    func done(_ token: LibraryEditorToken) throws -> LibraryEditorReceipt {
        let old = try matchingContext(token)
        guard let coordinator else { throw LibraryEditorAdmissionError.unavailable }
        try capacity(barrier: true)
        context = nil
        let receipt = try queue(nil, barrier: true) { [self] session in
            try await close(old, session: session)
            return .closed
        }
        _ = coordinator.submitCheckpoint()
        return receipt
    }
    func prepareDrain() {
        accepting = false; drainFailure = nil
        guard let coordinator else { return }
        // Drain must join every admitted sample even when the reserved UI barriers are full.
        if let selected = context {
            selected.drainFencedGesture = selected.plannedGesture ?? selected.activeGesture ?? selected.drainFencedGesture
            selected.plannedGesture = nil
            queued += 1; sequence += 1
            do {
                _ = try coordinator.enqueueMutation { [self] session in
                    defer { queued -= 1 }
                    do {
                        if selected.activeGesture != nil {
                            guard let before = selected.snapshot else { throw LibraryError.staleEdit }
                            let ended = try await session.endEditGesture(before.handle, expectedGeneration: before.generation)
                            selected.snapshot = ended
                            selected.activeGesture = nil
                        }
                        sequence += 1
                        publish(selected, edit: selected.snapshot)
                    } catch {
                        drainFailure = String(describing: error)
                        throw error
                    }
                }
            } catch {
                queued -= 1; drainFailure = String(describing: error)
            }
        }
    }
    func resume() { accepting = true }
    func retire() {
        accepting = false; context = nil; sequence += 1
        publish(nil, edit: nil)
    }
    func invalidateCoverage() {
        sequence += 1
        publish(context, edit: context?.snapshot)
        requestDisplay()
    }
    func displaySettled() async { await displayTask?.value }
    func requestDisplay() {
        displayWanted = true
        guard displayTask == nil, let coordinator else { return }
        displayTask = Task { @MainActor in
            repeat {
                displayWanted = false
                let selected = context, requested = sequence
                if let selected, let handle = selected.snapshot?.handle {
                    do {
                        let (edit, coverage) = try await coordinator.editorRead(handle)
                        if requested == sequence { publish(selected, edit: edit, coverage: coverage) }
                    } catch {
                        if requested == sequence {
                            if let error = error as? LibraryError, error == .staleEdit || error == .staleBinding {
                                selected.invalidReason = String(describing: error)
                            }
                            publish(selected, edit: selected.snapshot, failure: String(describing: error))
                        }
                    }
                }
            } while displayWanted && coordinator.lifecycle == .running
            displayTask = nil
        }
    }
}

import Foundation

struct DocumentContent: Equatable, Sendable {
    var definitions: [BlockDefinition] = []
    var uses: [RootSoundUse] = []
    var listening: [RootUseID: UseListeningState] = [:]
    var assignments: [PlaybackAssignment] = []
    var assignmentListening: [AssignmentID: UseListeningState] = [:]

    func definitionIndex(_ id: DefinitionID) throws -> Int {
        guard let index = definitions.firstIndex(where: { $0.id == id }) else {
            throw DocumentError.unknownDefinition(id)
        }
        guard definitions.filter({ $0.id == id }).count == 1 else { throw DocumentError.ambiguousDefinition(id) }
        return index
    }

    func definitionIndex(_ reference: DefinitionReference) throws -> Int {
        guard let index = definitions.firstIndex(where: { $0.reference == reference }) else {
            throw DocumentError.missingVersion(reference)
        }
        return index
    }

    func useIndex(_ id: RootUseID) throws -> Int {
        guard let index = uses.firstIndex(where: { $0.id == id }) else { throw DocumentError.unknownUse(id) }
        return index
    }

    func assignmentIndex(_ id: AssignmentID) throws -> Int {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else {
            throw DocumentError.unknownAssignment(id)
        }
        return index
    }
}

private struct ListeningArchive: Sendable {
    var roots: [RootUseID: UseListeningState]
    var assignments: [PlaybackAssignment] = []
    var positions: [AssignmentID: UseListeningState] = [:]
}

private struct AuthoredState: Sendable {
    let definitions: [BlockDefinition]
    let uses: [RootSoundUse]

    init(_ content: DocumentContent) {
        definitions = content.definitions
        uses = content.uses
    }
}

private struct GestureControl: Hashable { let root: RootUseID; let control: OccurrenceControlKey }

private struct PositionEdit: Sendable {
    let root: RootUseID
    let control: OccurrenceControlKey
    let before: ControlValue?
    let after: ControlValue?
}

private enum HistoryDirection { case undo, redo }

private enum HistoryEntry: Sendable {
    case authored(before: AuthoredState, after: AuthoredState, archived: ListeningArchive)
    case positions([PositionEdit])

    static func authored(from before: DocumentContent, to after: DocumentContent) -> HistoryEntry {
        let changedRoots = Set(before.uses.map(\.id)).symmetricDifference(after.uses.map(\.id))
        let archived = before.listening.merging(after.listening) { _, new in new }
            .filter { changedRoots.contains($0.key) }
        return .authored(
            before: AuthoredState(before), after: AuthoredState(after),
            archived: ListeningArchive(roots: archived))
    }

    static func positions(from before: DocumentContent, to after: DocumentContent, only: Set<GestureControl>? = nil) -> HistoryEntry {
        var changes: [PositionEdit] = []
        for root in Set(before.listening.keys).union(after.listening.keys) {
            let old = before.listening[root]?.values ?? [:]
            let new = after.listening[root]?.values ?? [:]
            for control in Set(old.keys).union(new.keys) where old[control] != new[control] {
                if let only, !only.contains(GestureControl(root: root, control: control)) { continue }
                changes.append(
                    PositionEdit(root: root, control: control, before: old[control], after: new[control]))
            }
        }
        return .positions(changes)
    }

    func applying(to state: DocumentContent, direction: HistoryDirection) throws -> (
        DocumentContent, HistoryEntry
    ) {
        var restored = state
        switch self {
        case .authored(let before, let after, var archived):
            let target = direction == .undo ? before : after
            let roots = Set(target.uses.map(\.id))
            for (root, listening) in state.listening where !roots.contains(root) {
                archived.roots[root] = listening
            }
            restored.definitions = target.definitions
            restored.uses = target.uses
            restored.listening = Dictionary(
                uniqueKeysWithValues: roots.map { root in
                    (root, state.listening[root] ?? archived.roots[root] ?? UseListeningState(positions: [:]))
                })
            for assignment in state.assignments where !roots.contains(assignment.root) {
                archived.assignments.removeAll { $0.id == assignment.id }
                archived.assignments.append(assignment)
                archived.positions[assignment.id] = state.assignmentListening[assignment.id]
            }
            restored.assignments = state.assignments.filter { roots.contains($0.root) }
            var spent = Set<AssignmentID>()
            for assignment in archived.assignments
            where roots.contains(assignment.root)
                && !state.uses.contains(where: { $0.id == assignment.root })
            {
                guard
                    !restored.assignments.contains(where: {
                        $0.id == assignment.id || $0.app == assignment.app
                    })
                else {
                    spent.insert(assignment.id)
                    continue
                }
                restored.assignments.append(assignment)
            }
            archived.assignments.removeAll { spent.contains($0.id) }
            for id in spent { archived.positions[id] = nil }
            restored.assignmentListening = Dictionary(
                uniqueKeysWithValues: restored.assignments.map {
                    (
                        $0.id,
                        state.assignmentListening[$0.id] ?? archived.positions[$0.id]
                            ?? UseListeningState(positions: [:])
                    )
                })
            return (restored, .authored(before: before, after: after, archived: archived))
        case .positions(let changes):
            var applied: [PositionEdit] = []
            for change in changes {
                _ = try state.useIndex(change.root)
                var positions = restored.listening[change.root]?.values ?? [:]
                let expected = direction == .undo ? change.after : change.before
                guard positions[change.control] == expected else { continue }
                positions[change.control] = direction == .undo ? change.before : change.after
                restored.listening[change.root] = UseListeningState(values: positions)
                applied.append(change)
            }
            return (restored, .positions(applied))
        }
    }
}

actor SoundDocument {
    private struct Gesture {
        let id: GestureID
        let context: ControlMoveContext
        let before: DocumentContent
        var controls: Set<GestureControl> = []
    }

    private let catalog: [PartDescriptor]
    private let historyLimit: UndoHistoryLimit
    var content = DocumentContent()
    var libraryPublicationPlans: [UUID: LibraryPublicationPlan] = [:]
    var libraryOwner: LibraryOwnerState?
    var libraryEdits: [UUID: LibraryEditContext] = [:]
    var libraryHistoryClock: UInt64 = 0
    var revision: UInt64 = 0
    var isEnabled = false
    private var undo: [HistoryEntry] = []
    private var redo: [HistoryEntry] = []
    private var gesture: Gesture?
    private var usedGestures = Set<GestureID>()

    init(catalog: [PartDescriptor], historyLimit: UndoHistoryLimit) throws {
        _ = try CompiledSound(
            block: SoundBlock(pieces: [], controls: [], mappings: []),
            root: RootUseID(), catalog: catalog)
        self.catalog = catalog
        self.historyLimit = historyLimit
    }

    func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(
            revision: revision, isEnabled: isEnabled,
            definitions: libraryOwner?.metadata.presentationDefinitions(content.definitions) ?? content.definitions, uses: content.uses,
            listening: content.listening,
            assignments: content.assignments, assignmentListening: content.assignmentListening,
            canUndo: gesture == nil && !undo.isEmpty, canRedo: gesture == nil && !redo.isEmpty,
            headReferences: Dictionary(uniqueKeysWithValues: (libraryOwner?.metadata.heads ?? []).map {
                ($0.definition, DefinitionReference(id: $0.definition, version: $0.revision))
            }))
    }

    func evaluate(root: RootUseID) throws -> DocumentEvaluation {
        DocumentEvaluation(revision: revision, sound: try compile(root: root, from: content))
    }

    func evaluate(assignment: AssignmentID) throws -> DocumentEvaluation {
        let binding = content.assignments[try content.assignmentIndex(assignment)]
        return DocumentEvaluation(
            revision: revision,
            sound: try compile(
                root: binding.root, from: content,
                positions: (libraryOwner == nil ? content.assignmentListening[assignment] : content.listening[binding.root]) ?? UseListeningState(positions: [:])))
    }

    func sessionData() throws -> Data {
        guard libraryOwner == nil else { throw DocumentError.libraryOwnedExportUnsupported }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(SoundSessionArchive(snapshot: snapshot()))
    }

    func restoreSession(_ data: Data) throws -> DocumentReceipt {
        guard gesture == nil else { throw DocumentError.gestureInProgress }
        let archive = try JSONDecoder().decode(SoundSessionArchive.self, from: data)
        guard archive.version == 1 else { throw DocumentError.unsupportedSessionVersion(archive.version) }
        var candidate = DocumentContent()
        for definition in archive.definitions {
            guard
                !candidate.definitions.contains(where: {
                    $0.id == definition.id || $0.version == definition.version
                })
            else {
                throw DocumentError.invalidSession
            }
            try validateName(definition.name)
            _ = try CompiledSound(block: definition.content, root: RootUseID(), catalog: catalog)
            candidate.definitions.append(definition)
        }
        for use in archive.uses {
            guard !candidate.uses.contains(where: { $0.id == use.id }) else {
                throw DocumentError.invalidSession
            }
            _ = try candidate.definitionIndex(use.definition)
            if case .own(let name) = use.name { try validateName(name) }
            candidate.uses.append(use)
        }
        func positions(_ saved: [SavedControlPosition], root: RootUseID) throws -> UseListeningState {
            var result: [ControlID: ControlValue] = [:]
            for value in saved {
                guard result[value.control] == nil else { throw DocumentError.invalidSession }
                let canonical = try canonicalValue(
                    value.value, control: value.control, root: root, from: candidate)
                guard canonical == value.value else { throw DocumentError.invalidSession }
                result[value.control] = value.value
            }
            return UseListeningState(positions: result)
        }
        for listening in archive.listening {
            _ = try candidate.useIndex(listening.root)
            guard candidate.listening[listening.root] == nil else { throw DocumentError.invalidSession }
            candidate.listening[listening.root] = try positions(listening.positions, root: listening.root)
        }
        guard candidate.listening.count == candidate.uses.count else { throw DocumentError.invalidSession }
        for saved in archive.assignments {
            let assignment = saved.assignment
            _ = try candidate.useIndex(assignment.root)
            guard
                !candidate.assignments.contains(where: { $0.id == assignment.id || $0.app == assignment.app })
            else {
                throw DocumentError.invalidSession
            }
            let listening = try positions(saved.positions, root: assignment.root)
            _ = try compile(root: assignment.root, from: candidate, positions: listening)
            candidate.assignments.append(assignment)
            candidate.assignmentListening[assignment.id] = listening
        }
        for use in candidate.uses { _ = try compile(root: use.id, from: candidate) }
        let enabled = archive.isEnabled ?? false
        guard candidate != content || enabled != isEnabled else { return receipt(didChange: false) }
        let next = try nextRevision()
        content = candidate
        isEnabled = enabled
        revision = next
        undo.removeAll()
        redo.removeAll()
        return receipt(didChange: true)
    }

    func beginGesture(_ id: GestureID, context: ControlMoveContext) throws {
        guard gesture == nil else { throw DocumentError.gestureInProgress }
        guard usedGestures.insert(id).inserted else { throw DocumentError.reusedGesture(id) }
        gesture = Gesture(id: id, context: context, before: content)
    }

    func endGesture(_ id: GestureID) throws -> DocumentReceipt {
        let active = try matchingGesture(id)
        if active.context == .editing {
            let entry = HistoryEntry.positions(from: active.before, to: content, only: active.controls)
            if case .positions(let changes) = entry, !changes.isEmpty {
                recordUndo(entry)
                redo.removeAll()
            }
        }
        gesture = nil
        return receipt(didChange: false)
    }

    func cancelGesture(_ id: GestureID) throws -> DocumentReceipt {
        let active = try matchingGesture(id)
        var restored = content
        for key in active.controls {
            restored.listening[key.root] = (restored.listening[key.root] ?? UseListeningState(positions: [:]))
                .setting(key.control, to: active.before.listening[key.root]?.values[key.control])
        }
        let changed = content != restored
        let next = changed ? try nextRevision() : revision
        content = restored
        if changed, var owner = libraryOwner {
            owner.liveGeneration &+= 1; libraryOwner = owner
        }
        revision = next
        gesture = nil
        return receipt(didChange: changed)
    }

    // No awaits inside a transaction: UI and agent callers share this one owner.
    func perform(_ command: DocumentCommand, gesture id: GestureID? = nil) throws -> DocumentReceipt {
        let previousListening = content.listening, previousAssignments = content.assignmentListening
        let previousEnabled = isEnabled
        defer {
            if (content.listening != previousListening || content.assignmentListening != previousAssignments || isEnabled != previousEnabled), var owner = libraryOwner {
                owner.liveGeneration &+= 1; libraryOwner = owner
            }
        }
        if case .setEnabled(let enabled) = command {
            guard id == nil else { throw DocumentError.gestureCommandNotAllowed }
            guard enabled != isEnabled else { return receipt(didChange: false) }
            let next = try nextRevision()
            isEnabled = enabled
            revision = next
            return receipt(didChange: true)
        }
        if let active = gesture {
            guard let id else { throw DocumentError.gestureInProgress }
            _ = try matchingGesture(id)
            guard case .moveControl(_, _, _, let context) = command else {
                throw DocumentError.gestureCommandNotAllowed
            }
            guard context == active.context else {
                throw DocumentError.gestureContextMismatch(expected: active.context, received: context)
            }
        } else if let id {
            throw DocumentError.wrongGesture(id)
        }

        switch command {
        case .undo:
            guard let entry = undo.last else { return receipt(didChange: false) }
            let (restored, inverse) = try entry.applying(to: content, direction: .undo)
            let changed = restored != content
            let next = changed ? try nextRevision() : revision
            redo.append(inverse)
            undo.removeLast()
            content = restored
            revision = next
            return receipt(didChange: changed)
        case .redo:
            guard let entry = redo.last else { return receipt(didChange: false) }
            let (restored, inverse) = try entry.applying(to: content, direction: .redo)
            let changed = restored != content
            let next = changed ? try nextRevision() : revision
            recordUndo(inverse)
            redo.removeLast()
            content = restored
            revision = next
            return receipt(didChange: changed)
        default:
            let candidate = try applying(command)
            if case .moveControl(let root, let control, _, _) = command, gesture != nil {
                gesture?.controls.insert(GestureControl(root: root, control: OccurrenceControlKey(path: [], control: control)))
            }
            guard candidate != content else { return receipt(didChange: false) }
            let next = try nextRevision()
            if gesture == nil {
                switch command {
                case .moveControl(_, _, _, .listening): break
                case .assign, .unassign, .reassign, .setAssignmentEnabled, .moveAssignmentControl:
                    break
                case .moveControl(_, _, _, .editing):
                    recordUndo(.positions(from: content, to: candidate))
                    redo.removeAll()
                default:
                    recordUndo(.authored(from: content, to: candidate))
                    redo.removeAll()
                }
            }
            content = candidate
            revision = next
        }
        return receipt(didChange: true)
    }

    private func matchingGesture(_ id: GestureID) throws -> Gesture {
        guard let gesture, gesture.id == id else { throw DocumentError.wrongGesture(id) }
        return gesture
    }

    private func receipt(didChange: Bool) -> DocumentReceipt {
        DocumentReceipt(revision: revision, didChange: didChange)
    }

    private func nextRevision() throws -> UInt64 {
        guard revision < UInt64.max else { throw DocumentError.revisionExhausted }
        return revision + 1
    }

    private func recordUndo(_ entry: HistoryEntry) {
        undo.append(entry)
        if undo.count > historyLimit.groups {
            undo.removeFirst(undo.count - historyLimit.groups)
        }
    }

    private func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentError.invalidName
        }
    }

    private func applying(_ command: DocumentCommand) throws -> DocumentContent {
        var candidate = content
        switch command {
        case .addDefinition(let definition):
            guard !candidate.definitions.contains(where: { $0.id == definition.id }) else {
                throw DocumentError.duplicateDefinition(definition.id)
            }
            guard !candidate.definitions.contains(where: { $0.version == definition.version }) else {
                throw DocumentError.duplicateVersion(definition.version)
            }
            try validateName(definition.name)
            _ = try CompiledSound(block: definition.content, root: RootUseID(), catalog: catalog)
            candidate.definitions.append(definition)
        case .instantiate(let definition, let root):
            let index = try candidate.definitionIndex(definition)
            guard !candidate.uses.contains(where: { $0.id == root }) else {
                throw DocumentError.duplicateUse(root)
            }
            candidate.uses.append(
                RootSoundUse(
                    id: root, definition: candidate.definitions[index].reference,
                    name: .library))
            candidate.listening[root] = UseListeningState(positions: [:])
        case .moveControl(let root, let id, let value, _):
            let key = OccurrenceControlKey(path: [], control: id)
            candidate.listening[root] = try (candidate.listening[root] ?? UseListeningState(positions: [:]))
                .setting(key, to: canonicalValue(value, control: id, root: root, from: candidate))
            _ = try compile(root: root, from: candidate)
        case .assign(let assignment, let initial):
            _ = try candidate.useIndex(assignment.root)
            guard !candidate.assignments.contains(where: { $0.id == assignment.id }) else {
                throw DocumentError.duplicateAssignment(assignment.id)
            }
            guard !candidate.assignments.contains(where: { $0.app == assignment.app }) else {
                throw DocumentError.appAlreadyAssigned(assignment.app)
            }
            var listening = initial
            for (id, value) in initial.positions {
                listening = try listening.setting(OccurrenceControlKey(path: [], control: id),
                    to: canonicalValue(value, control: id, root: assignment.root, from: candidate))
            }
            _ = try compile(root: assignment.root, from: candidate, positions: listening)
            candidate.assignments.append(assignment)
            candidate.assignmentListening[assignment.id] = listening
        case .reassign(let id, let root):
            _ = try candidate.useIndex(root)
            let index = try candidate.assignmentIndex(id)
            if candidate.assignments[index].root == root { return candidate }
            _ = try compile(
                root: root, from: candidate, positions: UseListeningState(positions: [:]))
            let old = candidate.assignments[index]
            candidate.assignments[index] = PlaybackAssignment(
                id: old.id, root: root, app: old.app, isEnabled: old.isEnabled)
            candidate.assignmentListening[id] = UseListeningState(positions: [:])
        case .unassign(let id):
            let index = try candidate.assignmentIndex(id)
            candidate.assignments.remove(at: index)
            candidate.assignmentListening[id] = nil
        case .setAssignmentEnabled(let id, let enabled):
            let index = try candidate.assignmentIndex(id)
            candidate.assignments[index].isEnabled = enabled
        case .moveAssignmentControl(let id, let control, let value):
            let assignment = candidate.assignments[try candidate.assignmentIndex(id)]
            let oldListening = libraryOwner == nil ? candidate.assignmentListening[id] : candidate.listening[assignment.root]
            let listening = try (oldListening ?? UseListeningState(positions: [:])).setting(
                OccurrenceControlKey(path: [], control: control), to: canonicalValue(value, control: control, root: assignment.root, from: candidate))
            if libraryOwner == nil { candidate.assignmentListening[id] = listening }
            else { candidate.listening[assignment.root] = listening }
            _ = try compile(root: assignment.root, from: candidate, positions: listening)
        case .renameDefinition(let id, let name):
            try validateName(name)
            let index = try candidate.definitionIndex(id)
            let old = candidate.definitions[index]
            candidate.definitions[index] = BlockDefinition(
                id: old.id, version: old.version,
                name: name, content: old.content, inTheMenu: old.inTheMenu)
        case .renameUse(let root, let name):
            try validateName(name)
            let index = try candidate.useIndex(root)
            let old = candidate.uses[index]
            candidate.uses[index] = RootSoundUse(
                id: old.id, definition: old.definition,
                name: .own(name))
        case .useLibraryName(let root):
            let index = try candidate.useIndex(root)
            let old = candidate.uses[index]
            candidate.uses[index] = RootSoundUse(
                id: old.id, definition: old.definition,
                name: .library)
        case .undo, .redo, .setEnabled:
            // History is handled before reducing a normal command.
            return candidate
        }
        return candidate
    }

    func putEveryday(on app: ApplicationKey, root: RootUseID) throws -> DocumentReceipt {
        if let existing = content.assignments.first(where: { $0.app == app }) {
            guard existing.root == root else { throw DocumentError.appAlreadyAssigned(app) }
            return receipt(didChange: false)
        }
        return try perform(
            .assign(
                PlaybackAssignment(id: AssignmentID(), root: root, app: app, isEnabled: true),
                initial: UseListeningState(positions: [:])))
    }

    func selectBuiltin(on app: ApplicationKey, root: RootUseID?) throws -> DocumentReceipt {
        if let root { _ = try content.useIndex(root) }
        if let assignment = content.assignments.first(where: { $0.app == app }) {
            if let root { return try perform(.reassign(assignment.id, root: root)) }
            return try perform(.unassign(assignment.id))
        }
        guard let root else { return receipt(didChange: false) }
        return try perform(
            .assign(
                PlaybackAssignment(id: AssignmentID(), root: root, app: app, isEnabled: true),
                initial: UseListeningState(positions: [:])))
    }

    func listeningSnapshot(recipes: BuiltinSounds) throws -> ListeningSnapshot {
        let state = snapshot()
        let assignments = try state.assignments.map { assignment in
            let use = state.uses[try content.useIndex(assignment.root)]
            let definition = state.definitions[try content.definitionIndex(use.definition)]
            let recipe = try recipes.recipe(id: definition.id)
            let sound = try evaluate(assignment: assignment.id).sound
            let controls = try definition.content.controls.map { control in
                let value =
                    state.assignmentListening[assignment.id]?.positions[control.id]
                    ?? control.position
                guard case .scalar(let position) = value else { throw SoundModelError.invalidControl }
                return ListeningControlState(id: control.id.rawValue, position: position.value)
            }
            let parts = try sound.parts.map { part in
                let parameters = try sound.targets.filter { $0.key.part == part.address }.map { target in
                    ListeningParameter(
                        key: target.key.parameter.rawValue,
                        value: try recipe.nativeValue(
                            type: part.type, parameter: target.key.parameter, position: target.value
                        ))
                }.sorted { $0.key < $1.key }
                return ListeningRenderPart(
                    id: part.address.part.rawValue,
                    path: part.address.occurrence.path.map(\.rawValue), type: part.type,
                    parameters: parameters)
            }
            return ListeningAssignment(
                block: recipe.kind, definitionID: definition.id.rawValue,
                id: assignment.id.rawValue, bundleIdentifier: assignment.app.bundleIdentifier,
                isEnabled: assignment.isEnabled, controls: controls, parts: parts)
        }
        let builtins = try recipes.all.map { recipe in
            try recipes.summary(
                state.definitions[try content.definitionIndex(recipe.definition.id)])
        }
        return ListeningSnapshot(
            revision: revision, isEnabled: isEnabled, assignments: assignments, builtins: builtins)
    }

    func listeningCheckpoint(recipes: BuiltinSounds) throws -> ListeningCheckpoint {
        try ListeningCheckpoint(snapshot: listeningSnapshot(recipes: recipes), data: sessionData())
    }

    private func canonicalValue(
        _ value: ControlValue, control id: ControlID, root: RootUseID,
        from state: DocumentContent
    ) throws -> ControlValue {
        let use = state.uses[try state.useIndex(root)]
        let definition = state.definitions[try state.definitionIndex(use.definition)]
        guard let control = definition.content.controls.first(where: { $0.id == id }) else {
            throw DocumentError.unknownControl(id)
        }
        let probe = SoundControl(id: id, face: control.face, position: value, waypoints: control.waypoints)
        try probe.validate()
        if case (.choice(let choice), .scalar(let position)) = (control.face, value) {
            return .scalar(try choice.position(of: choice.option(at: position)))
        }
        return value
    }

    private func compile(
        root: RootUseID, from state: DocumentContent,
        positions: UseListeningState? = nil
    ) throws -> CompiledSound {
        let use = state.uses[try state.useIndex(root)]
        let definition = state.definitions[try state.definitionIndex(use.definition)]
        if let owner = libraryOwner {
            return try owner.effectiveMetadata.compile(root: root, listening: positions ?? state.listening[root] ?? UseListeningState(positions: [:]), profiles: owner.profiles, limits: owner.limits)
        }
        let block = definition.content
        let controls = block.controls.map { control in
            SoundControl(
                id: control.id, face: control.face,
                position: (positions ?? state.listening[root])?.positions[control.id] ?? control.position,
                waypoints: control.waypoints)
        }
        return try CompiledSound(
            block: SoundBlock(pieces: block.pieces, controls: controls, mappings: block.mappings),
            root: root, catalog: catalog)
    }
}

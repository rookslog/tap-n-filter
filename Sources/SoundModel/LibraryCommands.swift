import Foundation

extension SoundDocument {
    func openLibrary(content: DocumentContent, metadata: LibraryMetadata, enabled: Bool,
                     profiles: LibraryProfiles, persistence: any LibraryPersistence,
                     limits: LibraryLimits, committed: Data?) {
        self.content = content; isEnabled = enabled
        libraryOwner = LibraryOwnerState(port: persistence, limits: limits, profiles: profiles,
                                        metadata: metadata, committed: committed.map { LibraryCommittedBytes(data: $0) })
    }

    func owner() throws -> LibraryOwnerState {
        guard let state = libraryOwner else { throw LibraryError.invalidArchive }
        return state
    }
    private func active(_ target: ApplicationKey) throws -> PlaybackAssignment {
        guard let binding = content.assignments.first(where: { $0.app == target }) else {
            throw LibraryError.unknownTarget
        }
        return binding
    }
    func settleWriter() async throws {
        while let pending = try owner().pending {
            let outcome = await pending.task.value
            try finish(pending, outcome: outcome)
        }
        guard try owner().uncertain == nil else { throw LibraryError.durableStateUnresolved }
    }
    private func compatiblePositions(_ newer: UseListeningState, from source: [OccurrenceControlKey: SoundControl],
                                     onto captured: UseListeningState, schema: [OccurrenceControlKey: SoundControl]) -> UseListeningState {
        func valid(_ value: ControlValue, _ control: SoundControl) -> Bool { (try? libraryValue(value, control: control)) == value }
        var values = captured.values.filter { key, value in schema[key].map { valid(value, $0) } ?? false }
        for (key, value) in newer.values {
            guard let target = schema[key], source[key]?.face == target.face, valid(value, target) else { continue }
            values[key] = value
        }
        var dormant = Dictionary(uniqueKeysWithValues: captured.dormant.map { ($0.key, $0) })
        for item in newer.dormant { dormant[item.key] = item }
        for (key, value) in newer.values where schema[key] == nil {
            if let control = source[key] ?? dormant[key]?.retiredControl, valid(value, control) {
                var item = LibrarySavedPosition(id: key.control, value: value, path: key.path)
                item.dormant = true; item.retiredControl = control
                item.adjustments = newer.adjustments.filter { $0.key.controlKey == key }.map { MappingAxisDelta(axis: $0.key.axis, value: $0.value) }
                dormant[key] = item
            }
        }
        var adjustments = captured.adjustments
        for (key, control) in source where schema[key]?.face == control.face {
            adjustments.removeAll { $0.key.controlKey == key }
            adjustments += newer.adjustments.filter { $0.key.controlKey == key && schema[key] != nil }
        }
        return UseListeningState(values: values, adjustments: adjustments, dormant: dormant.values.sorted { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) })
    }
    private func acceptedContent(_ pending: LibraryPending, state: LibraryOwnerState, original: LibraryOwnerState) throws -> DocumentContent {
        var accepted = pending.candidate
        let destination = state.overlay(on: pending.metadata)
        if state.liveGeneration != pending.generation {
            for index in accepted.assignments.indices {
                let binding = accepted.assignments[index]
                if let live = content.assignments.first(where: { $0.id == binding.id && $0.app == binding.app }) {
                    accepted.assignments[index].isEnabled = live.isEnabled
                }
            }
            let empty = UseListeningState(positions: [:])
            for root in accepted.uses.map(\.id) {
                guard var live = content.listening[root] else { continue }
                let schema = try destination.compile(root: root, listening: empty, profiles: state.profiles, limits: state.limits).controlSchemas
                var source = try original.effectiveMetadata.compile(root: root, listening: empty, profiles: state.profiles, limits: state.limits).controlSchemas
                if let publication = pending.publication {
                    let oldPayload = try original.effectiveMetadata.payload(root: root)
                    let newPayload = try destination.payload(root: root)
                    let transitions = publication.places.filter { $0.use == root.rawValue }.flatMap { place in publication.transitions.map { $0.prefixed(place.path) } }
                        .filter { source[$0.address.key]?.face == $0.before.face && schema[$0.address.key]?.face == $0.after.face }
                    if !transitions.isEmpty {
                        live = try optionMemory(live, from: oldPayload, to: newPayload, transitions: transitions, root: root,
                            context: destination.context(profiles: state.profiles, limits: state.limits))
                    }
                    // Unchanged controls retain their original schema. Only actually transitioned schemas become compatible.
                    for t in transitions where source[t.address.key]?.face == t.before.face { source[t.address.key] = t.after }
                }
                accepted.listening[root] = compatiblePositions(live, from: source, onto: accepted.listening[root] ?? empty, schema: schema)
            }
            for (root, sourceRoot) in pending.carryPositions {
                guard let live = content.listening[sourceRoot] else { continue }
                let schema = try destination.compile(root: root, listening: empty, profiles: state.profiles, limits: state.limits).controlSchemas
                let source = try state.effectiveMetadata.compile(root: sourceRoot, listening: empty, profiles: state.profiles, limits: state.limits).controlSchemas
                accepted.listening[root] = compatiblePositions(live, from: source, onto: accepted.listening[root] ?? empty, schema: schema)
            }
        }
        _ = try destination.archive(content: accepted, enabled: isEnabled, token: pending.token)
            .validated(profiles: state.profiles, limits: state.limits)
        return accepted
    }
    private func publicationRootPayload(_ local: LibraryPayload, previous: LibraryPayload,
                                        accepted: LibraryPayload) throws -> LibraryPayload {
        if local == previous { return accepted }
        // Genuine structural work stays an unpublished local draft of the new base.
        if local.structurallyDiffers(from: previous) { return local }
        // The existing field merge owns only root part values, authored fields and presentation.
        // Any other genuine local content (including nested payload metadata) stays local.
        let resetParts = zip(local.block.pieces, previous.block.pieces).map { current, prior -> BlockPiece in
            if case .part = current { return prior }
            return current
        }
        let remainder = LibraryPayload(profile: local.profile, block: try local.block.replacing(pieces: resetParts),
            presentation: previous.presentation, canonicalVersion: local.canonicalVersion,
            descendantDefaults: local.descendantDefaults, authored: previous.authored)
        if remainder != previous { return local }
        // A late edit to a removed target cannot be carried onto the published shape.
        // Retain that real local draft, as for other structural conflicts, rather than lose it.
        let parts = accepted.block.pieces.compactMap { if case .part(let p) = $0 { return p }; return nil }
        let oldParts = previous.block.pieces.compactMap { if case .part(let p) = $0 { return p }; return nil }
        for piece in local.block.pieces {
            guard case .part(let part) = piece, let old = oldParts.first(where: { $0.id == part.id }) else { continue }
            for setting in part.settings where old.settings.first(where: { $0.key == setting.key }) != setting {
                guard parts.contains(where: { $0.id == part.id && $0.settings.contains(where: { $0.key == setting.key }) }) else { return local }
            }
        }
        for id in Set(previous.authored.bypassed).union(local.authored.bypassed)
            where previous.authored.bypassed.contains(id) != local.authored.bypassed.contains(id) {
            guard parts.contains(where: { $0.id == id }) else { return local }
        }
        for key in Set(previous.authored.adjustments.map(\.address)).union(local.authored.adjustments.map(\.address))
            where previous.authored.adjustments.first(where: { $0.address == key }) != local.authored.adjustments.first(where: { $0.address == key }) {
            guard parts.contains(where: { $0.id == key.part && $0.settings.contains(where: { $0.key == key.parameter }) }) else { return local }
        }
        for item in local.presentation where previous.presentation.first(where: { $0.id == item.id }) != item {
            guard accepted.presentation.contains(where: { $0.id == item.id }) else { return local }
        }
        let merged = try accepted.preservingLocalChanges(from: previous, local: local)
        let presentation = accepted.presentation.map { item -> LibraryControl in
            guard let before = previous.presentation.first(where: { $0.id == item.id }),
                  let newer = local.presentation.first(where: { $0.id == item.id }) else { return item }
            let face: LibraryFace
            switch (before.face, newer.face, item.face) {
            case (.choice(let old), .choice(let own), .choice(let current)):
                face = .choice(current.map { option in
                    let a = old.first { $0.id == option.id }, b = own.first { $0.id == option.id }
                    return LibraryOption(id: option.id, title: a != nil && b != nil && a!.title != b!.title ? b!.title : option.title,
                        position: option.position)
                })
            case (.slider(let a, let b), .slider(let x, let y), .slider(let left, let right)):
                face = .slider(a == x ? left : x, b == y ? right : y)
            default: face = item.face
            }
            return LibraryControl(id: item.id, title: newer.title == before.title ? item.title : newer.title, face: face,
                placement: newer.placement == before.placement ? item.placement : newer.placement,
                readout: newer.readout == before.readout ? item.readout : newer.readout)
        }
        return try merged.replacing(presentation: presentation)
    }
    private func rebaseRootHistory(_ patch: LibraryEditPatch, previous: LibraryPayload,
                                   accepted: LibraryPayload) throws -> LibraryEditPatch {
        // An option inverse owns exact source/destination schemas, including removal intent.
        guard patch.optionHistory == nil else { return patch }
        var result = patch
        let before = try publicationRootPayload(patch.before, previous: previous, accepted: accepted)
        let after = try publicationRootPayload(patch.after, previous: previous, accepted: accepted)
        result = LibraryEditPatch(order: patch.order, before: before, after: after,
            beforeStructural: before.structurallyDiffers(from: accepted),
            afterStructural: after.structurallyDiffers(from: accepted), positions: patch.positions,
            beforeAdjustments: patch.beforeAdjustments, afterAdjustments: patch.afterAdjustments,
            beforeDormant: patch.beforeDormant, afterDormant: patch.afterDormant, optionHistory: patch.optionHistory)
        return result
    }
    private func capturedDraftIsCurrent(_ key: LibraryDraftOwner, info: LibraryDraftCapture,
                                        pending: LibraryPending, state: LibraryOwnerState) -> Bool {
        guard let draft = state.drafts[key], draft.info == info.info,
              positions(draft) == info.positions else { return false }
        return pending.capturedEdits.contains { id, handle in
            libraryEdits[id]?.handle == handle && libraryEdits[id]?.owner == key
        }
    }
    private func markCapturedRefusal(_ pending: LibraryPending, reason: LibraryWriteRefusal,
                                     state: inout LibraryOwnerState) throws {
        for (key, info) in pending.capturedDrafts {
            guard capturedDraftIsCurrent(key, info: info, pending: pending, state: state),
                  let draft = state.drafts[key] else { continue }
            // A failed publication is not a failed local save of an already-saved draft.
            if let data = state.committed?.data, try durableMatches(draft, data: data) { continue }
            state.drafts[key]?.refusal = reason
        }
    }
    private func finish(_ pending: LibraryPending, outcome: LibraryWriteOutcome, resolving: Bool = false) throws {
        guard var state = libraryOwner,
              state.pending?.token == pending.token || (resolving && state.uncertain?.token == pending.token) else { return }
        switch outcome {
        case .committed, .identical:
            let original = state
            let beforeChoices = pending.publication == nil ? [] : try publicationObservations(content: content, state: original)
            var editedContexts = libraryEdits
            // Nothing accepted/live is installed until the complete merged candidate validates.
            if let publication = pending.publication {
                for place in publication.places where !place.path.isEmpty {
                    let key = LibraryDraftOwner.use(RootUseID(place.use))
                    if var draft = state.drafts[key] {
                        draft.payload = try draft.payload.updatingReference(at: place.path, old: publication.placeBases[place] ?? publication.old, new: publication.new,
                            previous: publication.previous, replacement: publication.replacement)
                        draft.info = LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation + 1, structural: true)
                        for t in publication.transitions.map({ $0.prefixed(place.path) }) { draft.payload = try draft.payload.changingOptions(t) }
                        state.drafts[key] = draft
                        for id in editedContexts.keys where editedContexts[id]?.owner == key {
                            guard var edit = editedContexts[id] else { continue }
                            func rebased(_ patch: LibraryEditPatch) throws -> LibraryEditPatch {
                                var patch = patch
                                func payload(_ value: LibraryPayload) throws -> LibraryPayload {
                                    var result = try value.updatingReference(at: place.path, old: publication.placeBases[place] ?? publication.old, new: publication.new, previous: publication.previous, replacement: publication.replacement)
                                    for t in publication.transitions.map({ $0.prefixed(place.path) }) { result = try result.changingOptions(t) }
                                    return result
                                }
                                patch = LibraryEditPatch(order: patch.order,
                                    before: try payload(patch.before), after: try payload(patch.after),
                                    beforeStructural: true, afterStructural: true, positions: patch.positions,
                                    beforeAdjustments: patch.beforeAdjustments, afterAdjustments: patch.afterAdjustments, beforeDormant: patch.beforeDormant, afterDormant: patch.afterDormant, optionHistory: patch.optionHistory)
                                return patch
                            }
                            edit.undo = try edit.undo.map(rebased); edit.redo = try edit.redo.map(rebased)
                            editedContexts[id] = edit
                        }
                    }
                }
                for (key, base) in publication.bases {
                    if let draft = state.drafts[key] {
                        guard let payload = pending.metadata.revisions.first(where: { $0.definition.reference == base })?.payload else { throw LibraryError.missingReference }
                        var merged = draft.payload
                        if case .use(let root) = key, key != publication.source,
                           let place = publication.places.first(where: { $0.use == root.rawValue && $0.path.isEmpty }) {
                            guard let oldBase = publication.placeBases[place], draft.base == oldBase,
                                  let previous = original.metadata.revisions.first(where: { $0.definition.reference == oldBase })?.payload,
                                  let target = pending.metadata.owned.first(where: { $0.use.id == root }) else { throw LibraryError.staleEdit }
                            let accepted = target.draft ?? payload
                            merged = try publicationRootPayload(draft.payload, previous: previous, accepted: accepted)
                            for id in editedContexts.keys where editedContexts[id]?.owner == key {
                                guard var edit = editedContexts[id] else { continue }
                                edit.undo = try edit.undo.map { try rebaseRootHistory($0, previous: previous, accepted: accepted) }
                                edit.redo = try edit.redo.map { try rebaseRootHistory($0, previous: previous, accepted: accepted) }
                                editedContexts[id] = edit
                            }
                        }
                        state.drafts[key] = LibraryWorkingDraft(owner: key, base: base, payload: merged,
                            info: LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation, structural: merged.structurallyDiffers(from: payload)),
                            positions: draft.positions, refusal: draft.refusal,
                            optionRemovals: try publicationRebasedRemovals(draft.optionRemovals.filter { !publication.capturedRemovals.contains($0) }, base: base, original: payload, payload: merged,
                                context: pending.metadata.context(profiles: state.profiles, limits: state.limits)))
                    }
                }
            }
            var mergingState = state
            if pending.publication != nil { mergingState.metadata = pending.metadata }
            let accepted = try acceptedContent(pending, state: mergingState, original: original)
            state.pending = nil
            if resolving { state.uncertain = nil }
            state.metadata = pending.metadata
            if let publication = pending.publication {
                for id in editedContexts.keys {
                    if let edit = editedContexts[id], let base = publication.bases[edit.owner] {
                        editedContexts[id]?.priorHandles.append(edit.handle)
                        editedContexts[id]?.handle = LibraryEditHandle(id: edit.handle.id, target: edit.handle.target,
                            base: LibraryReference(definition: base.id.rawValue, revision: base.version.rawValue))
                    }
                }
            }
            if let publication = pending.publication {
                var finalState = state; finalState.metadata = pending.metadata
                let afterChoices = try publicationObservations(content: accepted, state: finalState)
                let report = LibraryUpdateReport(token: pending.token, capturedDigest: libraryDigest(pending.data),
                    carriedNewerState: original.liveGeneration != pending.generation || original.drafts.contains { key, draft in
                        if let saved = pending.metadata.workspaces.first(where: { .definition($0.definition) == key }) { return saved.info != draft.info }
                        if case .use(let root) = key { return pending.metadata.owned.first(where: { $0.use.id == root })?.authoring != draft.info }
                        return false
                    },
                    choices: LibraryChoiceReport(operation: pending.token, liveGeneration: original.liveGeneration,
                        changes: publicationChoiceChanges(beforeChoices, afterChoices, transitions: publication.transitions, places: publication.places)))
                guard state.updateReports.count < 16,
                      try publicationCacheBytes(state) + report.retainedBytes <= state.limits.maximumBytes else { throw LibraryOptionError.reportCapacity }
                state.updateReports[pending.token] = report
            }
            state.committed = LibraryCommittedBytes(data: pending.data, token: pending.token)
            for (key, info) in pending.capturedDrafts
                where capturedDraftIsCurrent(key, info: info, pending: pending, state: original) {
                state.drafts[key]?.refusal = nil
            }
            content = accepted
            libraryEdits = editedContexts
        case .refused(let reason):
            try markCapturedRefusal(pending, reason: reason, state: &state)
            state.pending = nil
        case .unresolved: state.pending = nil; state.uncertain = pending
        }
        libraryOwner = state
    }
    func persist(_ candidate: DocumentContent, metadata: LibraryMetadata,
                         carryPositions: [RootUseID: RootUseID] = [:], capturedGeneration: UInt64? = nil, publication: LibraryPublicationMigration? = nil) async throws -> LibraryCommit {
        var state = try owner()
        guard state.pending == nil, state.uncertain == nil else { throw LibraryError.durableStateUnresolved }
        for old in state.metadata.revisions {
            guard metadata.revisions.contains(old) else { throw LibraryError.invalidArchive }
        }
        let token = UUID()
        let effectiveMetadata = publication == nil ? state.overlay(on: metadata) : metadata
        let archive = effectiveMetadata.archive(content: candidate, enabled: isEnabled, token: token)
        _ = try archive.validated(profiles: state.profiles, limits: state.limits)
        let data = try archive.encoded(limits: state.limits)
        if let committed = state.committed?.data {
            var comparable = archive
            let old = try JSONDecoder().decode(LibraryArchive.self, from: committed)
            comparable = LibraryArchive(format: archive.format, schema: archive.schema, commit: old.commit,
                provenance: archive.provenance, revisions: archive.revisions, heads: archive.heads,
                uses: archive.uses, assignments: archive.assignments, enabled: archive.enabled, workspaces: archive.workspaces)
            if try comparable.encoded(limits: state.limits) == committed {
                return LibraryCommit(token: old.commit, digest: libraryDigest(committed), outcome: .identical)
            }
        }
        let port = state.port
        let task = Task { await port.commit(data) }
        let committedArchive = try state.committed.map { try JSONDecoder().decode(LibraryArchive.self, from: $0.data) }
        let captured = try state.drafts.filter { key, draft in
            // Opening an untouched owner creates an ephemeral generation-zero context,
            // not unsaved authored work. Do not label it for another operation's failure.
            if draft.info.generation == 0 && !draft.info.structural {
                guard case .use(let root) = key,
                      candidate.uses.contains(where: { $0.id == root && $0.definition == draft.base }),
                      candidate.listening[root] == positions(draft) else { return false }
                let saved = try committedArchive?.uses.first(where: { $0.use.id == root }).map { try UseListeningState(saved: $0.positions) }
                return positions(draft) != (saved ?? draft.positions)
            }
            if publication?.bases[key] != nil { return true }
            switch key {
            case .use(let root): return effectiveMetadata.owned.first { $0.use.id == root }?.authoring == draft.info
            case .definition(let id): return effectiveMetadata.workspaces.first { $0.definition == id }?.info == draft.info
            }
        }.mapValues { LibraryDraftCapture(info: $0.info, positions: positions($0)) }
        let pending = LibraryPending(capturedDrafts: captured, capturedEdits: libraryEdits.mapValues(\.handle), token: token, data: data, candidate: candidate, metadata: effectiveMetadata,
            enabled: isEnabled, generation: capturedGeneration ?? state.liveGeneration, carryPositions: carryPositions, task: task, publication: publication)
        state.pending = pending; libraryOwner = state
        let outcome = await task.value
        try finish(pending, outcome: outcome)
        return LibraryCommit(token: token, digest: libraryDigest(data), outcome: outcome)
    }

    func libraryCheckpoint() async throws -> LibraryCommit {
        try await settleWriter()
        return try await persist(content, metadata: owner().metadata)
    }
    func libraryReconcile() async throws -> LibraryWriteOutcome {
        let state = try owner()
        guard let uncertain = state.uncertain else { return .identical }
        let observed: Data?
        do { observed = try await state.port.load() }
        catch {
            guard libraryOwner?.uncertain?.token == uncertain.token else { return .identical }
            return .unresolved("readback unavailable: \(error)")
        }
        guard var current = libraryOwner, current.uncertain?.token == uncertain.token else {
            return .identical
        }
        if observed == uncertain.data {
            try finish(uncertain, outcome: .committed, resolving: true)
            return .committed
        }
        if observed == current.committed?.data {
            try markCapturedRefusal(uncertain, reason: .previousRetained, state: &current)
            current.uncertain = nil; libraryOwner = current
            return .refused(.previousRetained)
        }
        return .unresolved("readback matches neither candidate nor previous committed bytes")
    }
    func librarySelect(_ definition: DefinitionID?, target: ApplicationKey) async throws -> LibraryCommit {
        try await settleWriter()
        var state = try owner(), candidate = content
        let old = candidate.assignments.first(where: { $0.app == target })
        if let definition {
            guard let head = state.metadata.heads.first(where: { $0.definition == definition }) else {
                throw LibraryError.unknownDefinition
            }
            let root: RootUseID
            if let owned = state.metadata.owned.first(where: { $0.target == target && $0.use.definition.id == definition }) {
                root = owned.use.id
            } else {
                root = RootUseID()
                let use = RootSoundUse(id: root, definition: DefinitionReference(id: definition, version: head.revision), name: .library)
                candidate.uses.append(use); candidate.listening[root] = UseListeningState(positions: [:])
                state.metadata.owned.append(LibraryOwnedUse(target: target, use: use, draft: nil, positions: []))
            }
            let binding = PlaybackAssignment(id: old?.id ?? AssignmentID(), root: root, app: target,
                                             isEnabled: old?.isEnabled ?? true)
            if let index = candidate.assignments.firstIndex(where: { $0.app == target }) {
                candidate.assignments[index] = binding
            } else {
                candidate.assignments.append(binding)
            }
        } else {
            candidate.assignments.removeAll { $0.app == target }
        }
        return try await persist(candidate, metadata: state.metadata)
    }
    func libraryCreate(target: ApplicationKey, name: String) async throws -> DefinitionID {
        let binding = try active(target)
        let result = try await libraryCreate(expected: LibraryBinding(assignment: binding.id.rawValue,
            use: binding.root.rawValue, target: target.bundleIdentifier), name: name)
        switch result.commit.outcome {
        case .committed, .identical: return DefinitionID(result.candidate.definition)
        case .refused(let reason): throw LibraryError.persistenceRefused(reason)
        case .unresolved: throw LibraryError.durableStateUnresolved
        }
    }
    func libraryCreate(expected: LibraryBinding, name: String) async throws -> LibraryCreationResult {
        try libraryName(name)
        guard matches(expected) else { throw LibraryError.staleBinding }
        let initial = try owner(), binding = try active(ApplicationKey(expected.target))
        let capturedGeneration = initial.liveGeneration
        let source = try initial.effectiveMetadata.payload(root: binding.root)
        let captureContext = try initial.effectiveMetadata.context(profiles: initial.profiles, limits: initial.limits)
        guard !captureContext.containsOptionControls(source.block) else { throw LibraryError.unsupportedEdit }
        let block = source.block.withPositions(content.listening[binding.root]?.positions ?? [:])
        var defaults = Dictionary(uniqueKeysWithValues: source.descendantDefaults.map { ($0.key, $0.value) })
        for (key, value) in content.listening[binding.root]?.values ?? [:] where !key.path.isEmpty { defaults[key] = value }
        let captured = defaults.sorted { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) }
            .map { LibrarySavedPosition(id: $0.key.control, value: $0.value, path: $0.key.path) }
        let payload = LibraryPayload(profile: source.profile, block: block, presentation: source.presentation,
            canonicalVersion: captured.isEmpty ? source.canonicalVersion : max(2, source.canonicalVersion), descendantDefaults: captured, authored: source.authored)
        try await settleWriter()
        guard matches(expected) else { throw LibraryError.staleBinding }
        var state = try owner(), candidate = content
        let target = try ApplicationKey(expected.target)
        let definition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: name, content: block)
        _ = try CompiledSound(payload: payload, root: RootUseID(), reference: definition.reference,
            context: state.metadata.context(profiles: state.profiles, limits: state.limits), listening: UseListeningState(positions: [:]))
        let record = try LibraryRevision(definition: definition, origin: "custom", payload: payload,
                                     contentHash: payload.contentHash)
        state.metadata.revisions.append(record)
        state.metadata.heads.append(LibraryDefinitionRecord(record))
        candidate.definitions.append(definition)
        let use = RootSoundUse(id: RootUseID(), definition: definition.reference, name: .library)
        candidate.uses.append(use)
        candidate.listening[use.id] = content.listening[binding.root] ?? UseListeningState(positions: [:])
        state.metadata.owned.append(LibraryOwnedUse(target: target, use: use, draft: nil, positions: []))
        let index = try candidate.assignmentIndex(binding.id)
        candidate.assignments[index] = PlaybackAssignment(id: binding.id, root: use.id, app: target,
                                                         isEnabled: binding.isEnabled)
        let result = try await persist(candidate, metadata: state.metadata, carryPositions: [use.id: binding.root],
            capturedGeneration: capturedGeneration)
        return LibraryCreationResult(candidate: LibraryReference(definition: definition.id.rawValue,
            revision: definition.version.rawValue), commit: result)
    }

    private func unchangedMetadataReceipt(_ state: LibraryOwnerState) throws -> LibraryCommit? {
        guard let data = state.committed?.data else { return nil }
        let archive = try JSONDecoder().decode(LibraryArchive.self, from: data)
        guard archive.heads == state.metadata.heads else { return nil }
        return LibraryCommit(token: archive.commit, digest: libraryDigest(data), outcome: .identical)
    }
    func libraryRenameDefinition(_ id: DefinitionID, name: String) async throws -> LibraryCommit {
        try await settleWriter(); try libraryName(name)
        var state = try owner()
        guard let index = state.metadata.heads.firstIndex(where: { $0.definition == id }) else { throw LibraryError.unknownDefinition }
        guard state.metadata.heads[index].origin == "custom" else { throw LibraryError.protectedBuiltin }
        if state.metadata.heads[index].name == name, let unchanged = try unchangedMetadataReceipt(state) { return unchanged }
        state.metadata.heads[index].name = name
        return try await persist(content, metadata: state.metadata)
    }
    func librarySetInMenu(_ id: DefinitionID, visible: Bool) async throws -> LibraryCommit {
        try await settleWriter()
        var state = try owner()
        guard let index = state.metadata.heads.firstIndex(where: { $0.definition == id }) else { throw LibraryError.unknownDefinition }
        if state.metadata.heads[index].inTheMenu == visible, let unchanged = try unchangedMetadataReceipt(state) { return unchanged }
        state.metadata.heads[index].inTheMenu = visible
        return try await persist(content, metadata: state.metadata)
    }
    private func createUnassigned(_ payload: LibraryPayload, name: String) async throws -> LibraryCreationResult {
        var state = try owner(), candidate = content
        let definition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: name, content: payload.block)
        let record = try LibraryRevision(definition: definition, origin: "custom", payload: payload, contentHash: payload.contentHash)
        state.metadata.revisions.append(record); state.metadata.heads.append(LibraryDefinitionRecord(record))
        candidate.definitions.append(definition)
        let receipt = try await persist(candidate, metadata: state.metadata)
        return LibraryCreationResult(candidate: LibraryReference(definition: definition.id.rawValue,
            revision: definition.version.rawValue), commit: receipt)
    }
    func libraryCreateEmpty(name: String) async throws -> LibraryCreationResult {
        try await settleWriter(); try libraryName(name)
        return try await createUnassigned(LibraryPayload(profile: LibraryProfiles.everyday,
            block: SoundBlock(pieces: [], controls: [], mappings: []), presentation: []), name: name)
    }
    func libraryDuplicate(_ reference: DefinitionReference, name: String) async throws -> LibraryCreationResult {
        try await settleWriter(); try libraryName(name)
        guard let record = try owner().metadata.revisions.first(where: { $0.definition.reference == reference }) else { throw LibraryError.missingReference }
        return try await createUnassigned(record.payload, name: name)
    }

    func libraryNameUse(target: ApplicationKey, name: String?) async throws -> LibraryCommit {
        try await settleWriter()
        if let name { try libraryName(name) }
        var state = try owner(), candidate = content
        let binding = try active(target), index = try candidate.useIndex(binding.root)
        let old = candidate.uses[index]
        candidate.uses[index] = RootSoundUse(id: old.id, definition: old.definition,
                                           name: name.map(UseName.own) ?? .library)
        for i in state.metadata.owned.indices where state.metadata.owned[i].use.id == old.id {
            state.metadata.owned[i].use = candidate.uses[index]
        }
        return try await persist(candidate, metadata: state.metadata)
    }
    func libraryRenameControl(target: ApplicationKey, control: ControlID, title: String) async throws -> LibraryCommit {
        try await settleWriter(); try libraryName(title)
        var state = try owner()
        let binding = try active(target)
        let payload = try state.effectiveMetadata.payload(root: binding.root)
        guard payload.presentation.contains(where: { $0.id == control.rawValue }) else {
            throw DocumentError.unknownControl(control)
        }
        let draft = LibraryPayload(profile: payload.profile, block: payload.block,
            presentation: payload.presentation.map { $0.id == control.rawValue ? $0.renamed(title) : $0 },
            canonicalVersion: payload.canonicalVersion, descendantDefaults: payload.descendantDefaults, authored: payload.authored)
        if state.drafts[.use(binding.root)] != nil {
            try libraryUpdateLabelDraft(draft, root: binding.root)
            state = try owner()
        } else {
            for i in state.metadata.owned.indices where state.metadata.owned[i].use.id == binding.root { state.metadata.owned[i].draft = draft }
        }
        return try await persist(content, metadata: state.metadata)
    }
    func matches(_ expected: LibraryBinding) -> Bool {
        content.assignments.contains {
            $0.id.rawValue == expected.assignment && $0.root.rawValue == expected.use
                && $0.app.bundleIdentifier == expected.target
        }
    }
    func libraryMove(expected: LibraryBinding, key: OccurrenceControlKey, value: LibraryPosition) throws -> LibraryLiveMutation {
        guard matches(expected) else { return .superseded }
        let old = content.listening[RootUseID(expected.use)]
        try libraryMove(target: ApplicationKey(expected.target), key: key, value: value.validated())
        return old == content.listening[RootUseID(expected.use)] ? .noChange : .changed
    }
    func libraryEnabled(_ enabled: Bool, expected: LibraryBinding) throws -> LibraryLiveMutation {
        guard matches(expected) else { return .superseded }
        let target = try ApplicationKey(expected.target), old = try active(target).isEnabled
        try libraryEnabled(enabled, target: target)
        return old == enabled ? .noChange : .changed
    }
    func libraryLiveState() throws -> LibraryLiveState {
        let state = try owner()
        return LibraryLiveState(isEnabled: isEnabled, compareOriginal: state.compareOriginal,
            assignments: content.assignments.map {
                LibraryLiveAssignment(binding: LibraryBinding(assignment: $0.id.rawValue, use: $0.root.rawValue,
                    target: $0.app.bundleIdentifier), isEnabled: $0.isEnabled)
            }, pendingCommit: state.uncertain?.token ?? state.pending?.token,
            unresolved: state.uncertain != nil, writing: state.pending != nil)
    }
    private func builtinDecoration(_ record: LibraryRevision, profiles: LibraryProfiles) -> BuiltinBlock? {
        guard record.origin == "builtin", (try? profiles.profile(for: record.definition)) != nil else { return nil }
        return try? profiles.recipes.recipe(id: record.definition.id).kind
    }
    func libraryMove(target: ApplicationKey, control: ControlID, value: ControlValue) throws {
        try libraryMove(target: target, key: OccurrenceControlKey(path: [], control: control), value: value)
    }
    func libraryMove(target: ApplicationKey, key: OccurrenceControlKey, value: ControlValue) throws {
        var state = try owner()
        let metadata = state.effectiveMetadata
        let binding = try active(target)
        let listening = content.listening[binding.root] ?? UseListeningState(positions: [:])
        let sound = try metadata.compile(root: binding.root, listening: listening, profiles: state.profiles, limits: state.limits)
        guard let control = sound.controlSchemas[key] else { throw DocumentError.unknownControl(key.control) }
        let canonical = try libraryValue(value, control: control)
        let payload = try metadata.payload(root: binding.root)
        let transient = LibraryWorkingDraft(owner: .use(binding.root), base: content.uses[try content.useIndex(binding.root)].definition,
            payload: payload, info: LibraryDraftInfo(id: UUID(), generation: 0, structural: false), positions: listening)
        let next: UseListeningState
        if metadata.owned.first(where: { $0.use.id == binding.root })?.use.definition == transient.base {
            let graph = try mappingGraph(transient, listening: listening)
            next = try movedMappingValue(canonical, key: key, current: listening, graph: graph, schema: control)
        } else {
            next = try mappingMove(transient, key: key, value: canonical)
        }
        guard next != listening else { return }
        _ = try metadata.compile(root: binding.root, listening: next, profiles: state.profiles, limits: state.limits)
        content.listening[binding.root] = next
        state.liveGeneration &+= 1; libraryOwner = state
    }
    func libraryCreateLinked(name: String, children: [DefinitionReference], target: ApplicationKey) async throws -> DefinitionID {
        try await settleWriter(); try libraryName(name)
        guard !children.isEmpty else { throw LibraryError.invalidArchive }
        var state = try owner(), candidate = content
        let block = SoundBlock(pieces: children.map { .reference(ReferencedBlockUse(site: UseSiteID(), definition: $0)) }, controls: [], mappings: [])
        let payload = LibraryPayload(profile: LibraryProfiles.everyday, block: block, presentation: [], canonicalVersion: 2)
        let definition = BlockDefinition(id: DefinitionID(), version: DefinitionVersionID(), name: name, content: block)
        let root = RootUseID()
        _ = try CompiledSound(payload: payload, root: root, reference: definition.reference,
            context: state.metadata.context(profiles: state.profiles, limits: state.limits), listening: UseListeningState(positions: [:]))
        let record = try LibraryRevision(definition: definition, origin: "custom", payload: payload, contentHash: payload.contentHash)
        state.metadata.revisions.append(record)
        state.metadata.heads.append(LibraryDefinitionRecord(record))
        let use = RootSoundUse(id: root, definition: definition.reference, name: .library)
        state.metadata.owned.append(LibraryOwnedUse(target: target, use: use, draft: nil, positions: []))
        candidate.definitions.append(definition); candidate.uses.append(use)
        candidate.listening[root] = UseListeningState(positions: [:])
        if let index = candidate.assignments.firstIndex(where: { $0.app == target }) {
            let old = candidate.assignments[index]
            candidate.assignments[index] = PlaybackAssignment(id: old.id, root: root, app: target, isEnabled: old.isEnabled)
        } else { candidate.assignments.append(PlaybackAssignment(id: AssignmentID(), root: root, app: target, isEnabled: true)) }
        let receipt = try await persist(candidate, metadata: state.metadata)
        switch receipt.outcome {
        case .committed, .identical: return definition.id
        case .refused(let reason): throw LibraryError.persistenceRefused(reason)
        case .unresolved: throw LibraryError.durableStateUnresolved
        }
    }
    func libraryEnabled(_ enabled: Bool) {
        guard var state = libraryOwner, enabled != isEnabled else { return }
        isEnabled = enabled; state.liveGeneration &+= 1; libraryOwner = state
    }
    func libraryEnabled(_ enabled: Bool, target: ApplicationKey) throws {
        var state = try owner()
        let binding = try active(target)
        guard binding.isEnabled != enabled else { return }
        content.assignments[try content.assignmentIndex(binding.id)].isEnabled = enabled
        state.liveGeneration &+= 1; libraryOwner = state
    }
    func libraryCompare(_ comparing: Bool) {
        guard var state = libraryOwner else { return }
        state.compareOriginal = comparing; libraryOwner = state
    }
    private func libraryUnsaved(_ state: LibraryOwnerState) throws -> Bool {
        var unsaved = true
        if var committed = state.committed {
            let wasCached = committed.cachedToken != nil
            let token = try committed.token()
            if !wasCached { libraryOwner?.committed = committed }
            let current = state.effectiveMetadata.archive(content: content, enabled: isEnabled, token: token)
            unsaved = try current.encoded() != committed.data
        }
        return unsaved
    }
    func librarySaveCoverage() throws -> LibrarySaveCoverage {
        let state = try owner()
        return LibrarySaveCoverage(isSaved: try !libraryUnsaved(state) && state.pending == nil && state.uncertain == nil,
                                   liveGeneration: state.liveGeneration)
    }
    func librarySnapshot() throws -> LibrarySnapshot {
        let state = try owner()
        let definitions = try state.metadata.heads.map { head in
            let record = try state.metadata.head(head.definition)
            return LibraryDefinitionSummary(id: record.definition.id.rawValue, revision: record.definition.version.rawValue,
                name: head.name, origin: head.origin, profile: record.payload.profile,
                contentHash: record.contentHash, inTheMenu: head.inTheMenu, controls: record.payload.presentation,
                builtin: builtinDecoration(record, profiles: state.profiles))
        }
        let uses = try state.effectiveMetadata.owned.map { owned in
            let payload = try state.effectiveMetadata.payload(root: owned.use.id)
            let use = content.uses[try content.useIndex(owned.use.id)]
            let name: String, own: Bool
            switch use.name {
            case .own(let value): name = value; own = true
            case .library:
                name = try state.metadata.definition(use.definition.id).name; own = false
            }
            let sound = try state.effectiveMetadata.compile(root: use.id, listening: content.listening[use.id] ?? UseListeningState(positions: [:]), profiles: state.profiles, limits: state.limits)
            return LibraryUseSummary(id: use.id.rawValue, target: owned.target.bundleIdentifier,
                definition: use.definition.id.rawValue, baseRevision: use.definition.version.rawValue,
                name: name, hasOwnName: own, hasLocalDraft: owned.draft != nil,
                controls: payload.presentation, positions: sound.occurrences.first(where: { $0.path.isEmpty })?.positions ?? [:],
                occurrences: sound.occurrences,
                defaults: try state.effectiveMetadata.compile(root: use.id, listening: UseListeningState(positions: [:]),
                    profiles: state.profiles, limits: state.limits).occurrences,
                builtin: state.metadata.revisions.first(where: { $0.definition.reference == use.definition })
                    .flatMap { builtinDecoration($0, profiles: state.profiles) },
                optionControls: sound.optionControls, directSliderControls: sound.directSliderControls)
        }
        let assignments = try content.assignments.map { binding in
            let sound = try state.effectiveMetadata.compile(root: binding.root, listening: content.listening[binding.root] ?? UseListeningState(positions: [:]), profiles: state.profiles, limits: state.limits)
            let use = content.uses[try content.useIndex(binding.root)]
            return LibraryAssignmentSummary(isEnabled: binding.isEnabled, id: binding.id.rawValue, target: binding.app.bundleIdentifier,
                use: binding.root.rawValue, definition: use.definition.id.rawValue, parts: try state.profiles.native(sound))
        }
        let unsaved = try libraryUnsaved(state)
        return LibrarySnapshot(isEnabled: isEnabled, compareOriginal: state.compareOriginal,
            unsaved: unsaved, unresolved: state.uncertain != nil, writing: state.pending != nil,
            definitions: definitions, uses: uses, assignments: assignments,
            pendingCommit: state.uncertain?.token ?? state.pending?.token)
    }
}

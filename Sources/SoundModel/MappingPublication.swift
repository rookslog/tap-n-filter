import Foundation

public struct LibraryUpdatePlace: Hashable, Sendable {
    public let use: UUID
    public let path: [UUID]
    public init(use: UUID, path: [UUID] = []) { self.use = use; self.path = path }
}
public struct LibraryUpdatePreview: Equatable, Sendable {
    public let id: UUID
    public let handle: LibraryEditHandle
    public let generation: UInt64
    public let old: LibraryReference
    public let new: LibraryReference
    public let places: [LibraryUpdatePlace]
    public let brokenBindings: [UUID]
    public let fingerprint: String
    public let removals: [LibraryOptionRemovalSummary]
    public let choices: LibraryChoiceReport
}
struct LibraryPublicationPlan: Sendable {
    let preview: LibraryUpdatePreview
    let content: DocumentContent
    let metadata: LibraryMetadata
    let migrations: [LibraryDraftOwner: DefinitionReference]
    let sourcePayload: LibraryPayload
    let reportReserve: Int
    let placeBases: [LibraryUpdatePlace: DefinitionReference]
}
struct LibraryPublicationMigration: Sendable {
    let bases: [LibraryDraftOwner: DefinitionReference]
    let places: [LibraryUpdatePlace]
    let old: DefinitionReference
    let new: DefinitionReference
    let previous: LibraryPayload
    let replacement: LibraryPayload
    let transitions: [ChoiceOptionTransition]
    let source: LibraryDraftOwner
    let capturedRemovals: [LibraryOptionRemoval]
    let placeBases: [LibraryUpdatePlace: DefinitionReference]
}

extension LibraryPayload {
    func reference(at path: [UUID]) throws -> DefinitionReference {
        guard let site = path.first else { throw LibraryError.unsupportedEdit }
        for piece in block.pieces {
            if case .reference(let c) = piece, c.site.rawValue == site, path.count == 1 { return c.definition }
            if case .block(let c) = piece, c.site.rawValue == site, let payload = c.payload { return try payload.reference(at: Array(path.dropFirst())) }
        }
        throw LibraryError.staleEdit
    }
    func preservingLocalChanges(from previous: LibraryPayload, local: LibraryPayload) throws -> LibraryPayload {
        guard !local.structurallyDiffers(from: previous), local.profile == profile else { throw LibraryError.unsupportedEdit }
        let oldParts = previous.block.pieces.compactMap { if case .part(let p) = $0 { return p }; return nil }
        let localParts = local.block.pieces.compactMap { if case .part(let p) = $0 { return p }; return nil }
        let pieces = block.pieces.map { piece -> BlockPiece in
            guard case .part(let part) = piece, let old = oldParts.first(where: { $0.id == part.id }), let own = localParts.first(where: { $0.id == part.id }) else { return piece }
            return .part(SoundPart(id: part.id, type: part.type, settings: part.settings.map { setting in
                if let a = old.settings.first(where: { $0.key == setting.key }), let b = own.settings.first(where: { $0.key == setting.key }), a != b { return b }
                return setting
            }))
        }
        var fields = authored
        for id in Set(previous.authored.bypassed).union(local.authored.bypassed) where previous.authored.bypassed.contains(id) != local.authored.bypassed.contains(id) {
            guard pieces.contains(where: { if case .part(let p) = $0 { return p.id == id }; return false }) else { throw LibraryError.unsupportedEdit }
            fields.bypassed.removeAll { $0 == id }; if local.authored.bypassed.contains(id) { fields.bypassed.append(id) }
        }
        for key in Set(previous.authored.adjustments.map(\.address)).union(local.authored.adjustments.map(\.address)) {
            let before = previous.authored.adjustments.first { $0.address == key }, own = local.authored.adjustments.first { $0.address == key }
            if before != own {
                guard pieces.contains(where: { if case .part(let p) = $0 { return p.id == key.part && p.settings.contains { $0.key == key.parameter } }; return false }) else { throw LibraryError.unsupportedEdit }
                fields.adjustments.removeAll { $0.address == key }; if let own { fields.adjustments.append(own) }
            }
        }
        for original in previous.presentation {
            if let own = local.presentation.first(where: { $0.id == original.id }), own != original,
               !presentation.contains(where: { $0.id == original.id }) { throw LibraryError.unsupportedEdit }
        }
        let display = presentation.map { item in
            if let a = previous.presentation.first(where: { $0.id == item.id }), let b = local.presentation.first(where: { $0.id == item.id }), a != b { return b }
            return item
        }
        return try replacing(block: block.replacing(pieces: pieces), presentation: display, fields: fields)
    }
    func updatingReference(at path: [UUID], old: DefinitionReference, new: DefinitionReference,
                           previous: LibraryPayload, replacement: LibraryPayload) throws -> LibraryPayload {
        guard let site = path.first else { throw LibraryError.unsupportedEdit }
        var pieces = block.pieces
        guard let index = pieces.firstIndex(where: {
            switch $0 { case .reference(let c): return c.site.rawValue == site; case .block(let c): return c.site.rawValue == site; default: return false }
        }) else { throw LibraryError.unknownTarget }
        if path.count == 1 {
            guard case .reference(let child) = pieces[index], child.definition == old else { throw LibraryError.staleEdit }
            pieces[index] = .reference(ReferencedBlockUse(site: child.site, definition: new))
        } else {
            guard case .block(let child) = pieces[index], let payload = child.payload, let original = child.original else { throw LibraryError.unsupportedEdit }
            pieces[index] = .block(BlockUse(site: child.site, payload: try payload.updatingReference(at: Array(path.dropFirst()), old: old, new: new, previous: previous, replacement: replacement), original: original))
        }
        var changed = try replacing(block: block.replacing(pieces: pieces))
        if path.count == 1, let bindings = block.bindings {
            let controls = Set(replacement.block.controls.map(\.id))
            changed = try changed.replacing(block: changed.block.replacing(bindings: bindings.map { binding in
                var b = binding
                if case .control(let targetSite, let id, _) = b.target, targetSite == site, !controls.contains(ControlID(id)) {
                    b.status = .broken(.targetRemoved)
                }
                return b
            }))
        }
        return changed
    }
}

extension SoundDocument {
    func publicationFingerprint() throws -> String {
        let state = try owner()
        let data = try state.effectiveMetadata.archive(content: content, enabled: isEnabled,
            token: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).encoded()
        return libraryDigest(data + Data(String(state.liveGeneration).utf8))
    }
    func libraryPreviewUpdate(_ handle: LibraryEditHandle, generation: UInt64, places: [LibraryUpdatePlace], replacements: [LibraryOptionReplacement] = []) throws -> LibraryUpdatePreview {
        let (edit, draft) = try editContext(handle, generation: generation)
        guard edit.gesture == nil else { throw LibraryError.unsupportedEdit }
        let state = try owner(), old = draft.base
        let roots = Set(places.map { RootUseID($0.use) })
        guard !libraryEdits.values.contains(where: { context in
            if case .use(let root) = context.owner { return roots.contains(root) && context.gesture != nil }; return false
        }) else { throw LibraryError.unsupportedEdit }
        guard state.pending == nil, state.uncertain == nil else { throw LibraryError.durableStateUnresolved }
        guard libraryPublicationPlans.count + state.updateReports.count < 16 else { throw LibraryOptionError.reportCapacity }
        let transitions = try publicationTransitions(draft, replacements: replacements)
        let head = try state.metadata.definition(old.id)
        guard head.origin == "custom", head.revision == old.version else { throw LibraryError.protectedBuiltin }
        guard Set(places.map { $0.use.uuidString + $0.path.map(\.uuidString).joined() }).count == places.count else { throw LibraryError.invalidArchive }
        let ref = DefinitionReference(id: old.id, version: DefinitionVersionID())
        let definition = BlockDefinition(id: old.id, version: ref.version, name: head.name, content: draft.payload.block, inTheMenu: head.inTheMenu)
        let record = try LibraryRevision(definition: definition, origin: head.origin, payload: draft.payload, contentHash: draft.payload.contentHash)
        var metadata = state.effectiveMetadata, candidate = content, migrations: [LibraryDraftOwner: DefinitionReference] = [:]
        metadata.revisions.append(record)
        guard let h = metadata.heads.firstIndex(where: { $0.definition == old.id }) else { throw LibraryError.unknownDefinition }
        metadata.heads[h] = LibraryDefinitionRecord(record)
        candidate.definitions.append(definition)
        var placeBases: [LibraryUpdatePlace: DefinitionReference] = [:]
        var broken: [UUID] = []
        var observationsBefore: [LibraryChoiceObservation] = [], observationsAfter: [LibraryChoiceObservation] = []
        let previous = try state.metadata.head(old.id).payload
        for place in places {
            let root = RootUseID(place.use)
            guard let i = metadata.owned.firstIndex(where: { $0.use.id == root }) else { throw LibraryError.unknownTarget }
            let owned = metadata.owned[i], payload = try metadata.payload(root: root)
            let listening = candidate.listening[root] ?? UseListeningState(positions: [:])
            let placeBase = try place.path.isEmpty ? owned.use.definition : payload.reference(at: place.path)
            guard placeBase == old || draft.optionRemovals.contains(where: { $0.base == placeBase }) else { throw LibraryError.staleEdit }
            guard let placePrevious = metadata.revisions.first(where: { $0.definition.reference == placeBase })?.payload else { throw LibraryError.missingReference }
            placeBases[place] = placeBase
            let beforeSound = try MappingEvaluation(payload: payload, root: root, context: metadata.context(profiles: state.profiles, limits: state.limits), listening: listening)
            var changed: LibraryPayload
            if place.path.isEmpty {
                guard (owned.authoring?.structural != true && (owned.optionRemovals ?? []).isEmpty) || .use(root) == draft.owner else { throw LibraryError.unsupportedEdit }
                if let local = owned.draft, .use(root) != draft.owner, local != placePrevious {
                    changed = try draft.payload.preservingLocalChanges(from: placePrevious, local: local)
                } else { changed = draft.payload }
                let use = RootSoundUse(id: root, definition: ref, name: owned.use.name)
                metadata.owned[i].use = use; candidate.uses[try candidate.useIndex(root)] = use
                migrations[.use(root)] = ref
                metadata.owned[i].draft = changed
                metadata.owned[i].authoring = LibraryDraftInfo(id: owned.authoring?.id ?? UUID(), generation: owned.authoring?.generation ?? 0, structural: false)
            } else {
                guard let originalOwned = state.effectiveMetadata.owned.first(where: { $0.use.id == root }) else { throw LibraryError.unknownTarget }
                if .use(root) != draft.owner && (originalOwned.authoring?.structural == true || !(originalOwned.optionRemovals ?? []).isEmpty) { throw LibraryError.unsupportedEdit }
                changed = try payload.updatingReference(at: place.path, old: placeBase, new: ref, previous: previous, replacement: draft.payload)
                metadata.owned[i].draft = changed
                metadata.owned[i].authoring = LibraryDraftInfo(id: owned.authoring?.id ?? UUID(), generation: (owned.authoring?.generation ?? 0) + 1, structural: true)
            }
            let qualified = transitions.map { $0.prefixed(place.path) }
            if !place.path.isEmpty {
                for t in qualified { changed = try changed.changingOptions(t) }
                metadata.owned[i].draft = changed
            }
            metadata.owned[i].optionRemovals = nil
            let placeID = LibraryChoicePlace.use(app: owned.target.bundleIdentifier, use: root.rawValue)
            observationsBefore += try choiceObservations(payload, memory: listening, root: root, place: placeID,
                context: metadata.context(profiles: state.profiles, limits: state.limits))
            let schemas = try CompiledSound(payload: changed, root: root, reference: metadata.owned[i].use.definition,
                context: metadata.context(profiles: state.profiles, limits: state.limits), listening: UseListeningState(positions: [:])).controlSchemas
            var values = listening.values, adjustments = listening.adjustments, dormant = listening.dormant
            for key in values.keys where schemas[key] == nil {
                var item = LibrarySavedPosition(id: key.control, value: values.removeValue(forKey: key)!, path: key.path); item.dormant = true
                item.retiredControl = try CompiledSound(payload: payload, root: root, reference: owned.use.definition,
                    context: metadata.context(profiles: state.profiles, limits: state.limits), listening: UseListeningState(positions: [:])).controlSchemas[key]
                item.adjustments = adjustments.filter { $0.key.controlKey == key }.map { MappingAxisDelta(axis: $0.key.axis, value: $0.value) }
                dormant.removeAll { $0.key == key }; dormant.append(item); adjustments.removeAll { $0.key.controlKey == key }
            }
            var memory = UseListeningState(values: values, adjustments: adjustments, dormant: dormant)
            memory = try optionMemory(memory, from: payload, to: changed, transitions: qualified, root: root,
                context: metadata.context(profiles: state.profiles, limits: state.limits))
            let after = try MappingEvaluation(payload: changed, root: root, context: metadata.context(profiles: state.profiles, limits: state.limits), listening: memory)
            for key in beforeSound.incoming.subtracting(after.incoming) where schemas[key.controlKey] != nil {
                guard let effective = beforeSound.effective.values[key.controlKey], let manual = memory.values[key.controlKey] ?? after.manual[key.controlKey] else { throw LibraryError.invalidCanonical }
                memory = memory.setting(key.controlKey, to: try foldingMappingAxis(key.axis, manual: manual, effective: effective))
                memory.adjustments.removeAll { $0.key == key }
            }
            candidate.listening[root] = memory
            observationsAfter += try choiceObservations(changed, memory: memory, root: root, place: placeID,
                context: metadata.context(profiles: state.profiles, limits: state.limits))
            broken += after.bindings.compactMap { if case .broken = $0.binding.status { return $0.binding.id }; return nil }
        }
        if case .use(let root) = draft.owner, !places.contains(where: { $0.use == root.rawValue && $0.path.isEmpty }) { throw LibraryError.unsupportedEdit }
        if case .definition(let id) = draft.owner {
            migrations[.definition(id)] = ref
            metadata.workspaces.removeAll { $0.definition == id }
            metadata.workspaces.append(LibraryWorkspace(definition: id, base: ref, payload: draft.payload,
                info: LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation, structural: false), positions: positions(draft).saved))
        }
        let archive = metadata.archive(content: candidate, enabled: isEnabled, token: UUID())
        _ = try archive.validated(profiles: state.profiles, limits: state.limits); _ = try archive.encoded(limits: state.limits)
        let previewID = UUID()
        let preview = LibraryUpdatePreview(id: previewID, handle: handle, generation: generation,
            old: LibraryReference(definition: old.id.rawValue, revision: old.version.rawValue), new: LibraryReference(definition: ref.id.rawValue, revision: ref.version.rawValue),
            places: places, brokenBindings: Array(Set(broken)).sorted { $0.uuidString < $1.uuidString }, fingerprint: try publicationFingerprint(), removals: draft.optionRemovals.map { removal in
                var r = removal
                if let override = replacements.first(where: { $0.address == removal.summary.address && $0.removed == removal.removed }) { r.replacement = override.replacement }
                return r.summary
            }, choices: LibraryChoiceReport(operation: previewID, liveGeneration: state.liveGeneration,
                changes: publicationChoiceChanges(observationsBefore, observationsAfter, transitions: transitions, places: places)))
        let reserve = try publicationReportReserve(content: content, state: state)
        let plan = LibraryPublicationPlan(preview: preview, content: candidate, metadata: metadata, migrations: migrations,
            sourcePayload: draft.payload, reportReserve: reserve, placeBases: placeBases)
        let cost = try archive.encoded(limits: state.limits).count + draft.payload.canonicalData.count + preview.retainedBytes + reserve
        guard try publicationCacheBytes(state) + cost <= state.limits.maximumBytes else { throw LibraryOptionError.reportCapacity }
        libraryPublicationPlans[preview.id] = plan
        return preview
    }
    func libraryCancelUpdate(_ preview: LibraryUpdatePreview) {
        libraryPublicationPlans[preview.id] = nil }
    func libraryConfirmUpdate(_ preview: LibraryUpdatePreview) async throws -> LibraryUpdateResult {
        guard let plan = libraryPublicationPlans.removeValue(forKey: preview.id), plan.preview == preview,
              preview.fingerprint == (try publicationFingerprint()) else { throw LibraryError.staleEdit }
        _ = try editContext(preview.handle, generation: preview.generation)
        let roots = Set(preview.places.map { RootUseID($0.use) })
        guard !libraryEdits.values.contains(where: { context in
            if case .use(let root) = context.owner { return roots.contains(root) && context.gesture != nil }; return false
        }) else { throw LibraryError.unsupportedEdit }
        // The planned metadata already contains every captured draft. Normal overlay must not restore its old references.
        let (_, draft) = try editContext(preview.handle, generation: preview.generation)
        let transitions = try publicationTransitions(draft, replacements: preview.removals.map { LibraryOptionReplacement(address: $0.address, removed: $0.removed, replacement: $0.replacement) })
        let commit = try await persist(plan.content, metadata: plan.metadata, publication: LibraryPublicationMigration(bases: plan.migrations, places: preview.places,
            old: preview.old.reference, new: preview.new.reference,
            previous: try owner().metadata.head(preview.old.reference.id).payload, replacement: plan.sourcePayload,
            transitions: transitions, source: draft.owner, capturedRemovals: draft.optionRemovals, placeBases: plan.placeBases))
        return LibraryUpdateResult(commit: commit, acceptedReport: commit.outcome.isAccepted ? try libraryTakeUpdateReport(commit.token) : nil)
    }
}
extension SoundLibrarySession {
    public func previewUpdateLibrary(_ handle: LibraryEditHandle, expectedGeneration: UInt64, places: [LibraryUpdatePlace], replacements: [LibraryOptionReplacement] = []) async throws -> LibraryUpdatePreview {
        try await document.libraryPreviewUpdate(handle, generation: expectedGeneration, places: places, replacements: replacements)
    }
    public func cancelUpdateLibrary(_ preview: LibraryUpdatePreview) async { await document.libraryCancelUpdate(preview) }
    public func confirmUpdateLibrary(_ preview: LibraryUpdatePreview) async throws -> LibraryUpdateResult { try await document.libraryConfirmUpdate(preview) }
}

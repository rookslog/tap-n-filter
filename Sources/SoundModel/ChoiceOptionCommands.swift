import Foundation

extension SoundDocument {
    func optionRoot(_ draft: LibraryWorkingDraft) -> RootUseID {
        if case .use(let id) = draft.owner { return id }; return RootUseID(draft.info.id)
    }
    func optionContext() throws -> LibraryCompileContext {
        let state = try owner(); return try state.effectiveMetadata.context(profiles: state.profiles, limits: state.limits)
    }
    func prepareOption(_ handle: LibraryEditHandle, generation: UInt64, address: LibraryControlAddress,
                       mutation: LibraryOptionMutation) throws -> (LibraryWorkingDraft, LibraryWorkingDraft, ChoiceOptionTransition) {
        let (context, initial) = try editContext(handle, generation: generation)
        guard context.gesture == nil else { throw LibraryError.unsupportedEdit }
        var before = initial; before.positions = positions(initial)
        let state = try owner(), compile = try optionContext()
        let localized = try before.payload.localizing(address.path, context: compile)
        let local = try localized.localPayload(at: address.path)
        guard !compile.containsOptionControls(before.payload.block) else { throw LibraryError.unsupportedEdit }
        guard let old = local.block.controls.first(where: { $0.id.rawValue == address.control }),
              case .choice(let choice) = old.face else { throw LibraryOptionError.invalidMutation }
        guard let presentation = local.presentation.first(where: { $0.id == address.control }),
              case .choice(var options) = presentation.face else { throw LibraryOptionError.invalidMutation }
        var replacements: [UUID: UUID] = [:], neighbor: UUID?
        switch mutation {
        case .add(let id, let title, let at):
            try libraryName(title)
            guard options.count < 64, (0...options.count).contains(at), !choice.options.contains(OptionID(id)),
                  !before.optionRemovals.contains(where: { $0.path == address.path && $0.control == address.control && $0.removed == id }) else { throw LibraryOptionError.invalidMutation }
            for revision in state.metadata.revisions where revision.definition.id == before.base.id {
                let schemas = try CompiledSound(payload: revision.payload, root: optionRoot(before), reference: revision.definition.reference,
                    context: compile, listening: UseListeningState(positions: [:])).controlSchemas
                if let c = schemas[address.key], case .choice(let historical) = c.face, historical.options.contains(OptionID(id)) { throw LibraryOptionError.invalidMutation }
            }
            neighbor = options[at == 0 ? 0 : at - 1].id
            options.insert(LibraryOption(id: id, title: title, position: 0), at: at)
        case .remove(let id, let replacement):
            guard options.count > 2, id != replacement,
                  options.contains(where: { $0.id == id }), options.contains(where: { $0.id == replacement }) else { throw LibraryOptionError.invalidMutation }
            replacements[id] = replacement; options.removeAll { $0.id == id }
        }
        let changedChoice = try Choice(options: options.map { OptionID($0.id) })
        options = zip(options,changedChoice.positions).map { LibraryOption(id: $0.0.id, title: $0.0.title, position: $0.1.value) }
        let selected = choice.option(at: try old.position(on: .value)).rawValue
        let desired = replacements[selected] ?? selected
        let new = SoundControl(id: old.id, face: .choice(changedChoice),
            position: .scalar(try changedChoice.position(of: OptionID(desired))), waypoints: .scalar(changedChoice.positions))
        let transition = ChoiceOptionTransition(address: address, before: old, after: new, replacements: replacements, copyNeighbor: neighbor)
        var changed = try next(before)
        changed.payload = try localized.changingOptions(transition, options: options)
        changed.positions = try optionMemory(before.positions, from: before.payload, to: changed.payload,
            transitions: [transition], root: optionRoot(before), context: compile)
        if case .remove(let removed, let replacement) = mutation {
            for i in changed.optionRemovals.indices where changed.optionRemovals[i].path == address.path && changed.optionRemovals[i].control == address.control && changed.optionRemovals[i].replacement == removed {
                changed.optionRemovals[i].replacement = replacement
            }
            changed.optionRemovals.append(LibraryOptionRemoval(base: before.base, path: address.path, control: address.control,
                schema: choice.options.map(\.rawValue), removed: removed, replacement: replacement))
        }
        let base = state.metadata.revisions.first { $0.definition.reference == changed.base }?.payload
        guard let base else { throw LibraryError.missingReference }
        changed.info = LibraryDraftInfo(id: changed.info.id, generation: changed.info.generation, structural: changed.payload.structurallyDiffers(from: base))
        try validateDraft(changed, admit: context.admit)
        if try optionPatch(before,changed,transition:transition).approximateBytes > min(state.limits.maximumBytes,8*1024*1024) { throw LibraryError.limitExceeded }
        return (before,changed,transition)
    }
    func optionPatch(_ before: LibraryWorkingDraft, _ changed: LibraryWorkingDraft, transition t: ChoiceOptionTransition) throws -> LibraryEditPatch {
        guard var inverse = patch(before, changed) else { throw LibraryOptionError.invalidMutation }
        let compile = try optionContext(), root = optionRoot(before)
        let old = try MappingEvaluation(payload:before.payload,root:root,context:compile,listening:before.positions)
        let new = try MappingEvaluation(payload:changed.payload,root:root,context:compile,listening:changed.positions)
        guard let beforeManual=old.manual[t.address.key], let afterManual=new.manual[t.address.key] else { throw LibraryError.unknownTarget }
        inverse.optionHistory = LibraryOptionHistory(transition:t,beforeRemovals:before.optionRemovals,afterRemovals:changed.optionRemovals,
            beforeManual:beforeManual,afterManual:afterManual,
            beforeHands:try handChoices(before.payload,memory:before.positions,root:root,context:compile),
            afterHands:try handChoices(changed.payload,memory:changed.positions,root:root,context:compile))
        return inverse
    }
    func optionReport(_ before: LibraryWorkingDraft, _ after: LibraryWorkingDraft, transition: ChoiceOptionTransition,
                      operation: UUID, explicitPairs: [UUID: UUID]? = nil) throws -> LibraryChoiceReport {
        let compile = try optionContext(), root = optionRoot(before), place = try choicePlace(before)
        return LibraryChoiceReport(operation: operation, liveGeneration: try owner().liveGeneration,
            changes: choiceChanges(try choiceObservations(before.payload,memory:before.positions,root:root,place:place,context:compile),
                try choiceObservations(after.payload,memory:after.positions,root:root,place:place,context:compile),
                replacements: [:]).map { change in
                    LibraryChoiceChange(place: change.place, address: change.address, before: change.before, after: change.after,
                        reason: change.address == transition.address && (explicitPairs ?? transition.replacements)[change.before] == change.after ? .explicitReplacement : .redistribution)
                })
    }
    func libraryPreviewOption(_ handle: LibraryEditHandle, generation: UInt64, address: LibraryControlAddress,
                              mutation: LibraryOptionMutation) throws -> LibraryOptionEditPreview {
        let (before,after,t) = try prepareOption(handle,generation:generation,address:address,mutation:mutation)
        let id = UUID()
        return LibraryOptionEditPreview(id:id,handle:handle,generation:generation,address:address,mutation:mutation,
            fingerprint:try publicationFingerprint(),report:try optionReport(before,after,transition:t,operation:id))
    }
    func libraryApplyOption(_ preview: LibraryOptionEditPreview) throws -> LibraryOptionEditResult {
        guard preview.fingerprint == (try publicationFingerprint()) else { throw LibraryError.staleEdit }
        let (before,changed,t) = try prepareOption(preview.handle,generation:preview.generation,address:preview.address,mutation:preview.mutation)
        var (context,_) = try editContext(preview.handle,generation:preview.generation)
        guard var inverse = patch(before,changed) else { throw LibraryOptionError.invalidMutation }
        inverse = try optionPatch(before, changed, transition: t)
        context.undo.append(try ordered(inverse));context.redo.removeAll();try trim(&context)
        try install(changed);libraryEdits[context.handle.id]=context
        return LibraryOptionEditResult(snapshot:try libraryInspectEdit(context.handle),report:try optionReport(before,changed,transition:t,operation:preview.id))
    }
    func libraryEditHistory(_ handle: LibraryEditHandle, generation: UInt64, undoing: Bool) throws -> LibraryEditSnapshot {
        try walkLibraryHistory(handle, generation: generation, undoing: undoing, reporting: false).snapshot
    }
    func libraryOptionHistory(_ handle: LibraryEditHandle, generation: UInt64, undoing: Bool) throws -> LibraryOptionEditResult {
        try walkLibraryHistory(handle, generation: generation, undoing: undoing, reporting: true)
    }
    private func walkLibraryHistory(_ handle: LibraryEditHandle, generation: UInt64, undoing: Bool,
                                    reporting: Bool) throws -> LibraryOptionEditResult {
        var (context, draft) = try editContext(handle, generation: generation)
        guard context.gesture == nil else { throw LibraryError.unsupportedEdit }
        guard !(undoing ? context.undo : context.redo).isEmpty else { throw LibraryError.noEditHistory }
        var applied = false
        while let patch = undoing ? context.undo.last : context.redo.last {
            if let history = patch.optionHistory {
                guard reporting else { throw LibraryOptionError.reportingHistoryRequired }
                return try applyOptionHistory(context: context, draft: draft, patch: patch, history: history, undoing: undoing)
            }
            if undoing { context.undo.removeLast() } else { context.redo.removeLast() }
            if let inverse = try applyPatch(patch, undoing: undoing, draft: draft, context: context) {
                if undoing { context.redo.append(inverse) } else { context.undo.append(inverse) }
                applied = true; break
            }
        }
        if !applied { try advance(draft, context: context) }
        libraryEdits[handle.id] = context
        return LibraryOptionEditResult(snapshot: try libraryInspectEdit(handle), report: LibraryChoiceReport(
            operation: UUID(), liveGeneration: try owner().liveGeneration, changes: []))
    }
    private func applyOptionHistory(context suppliedContext: LibraryEditContext, draft suppliedDraft: LibraryWorkingDraft,
                                    patch: LibraryEditPatch, history: LibraryOptionHistory, undoing: Bool) throws -> LibraryOptionEditResult {
        var context = suppliedContext, draft = suppliedDraft
        draft.positions=positions(draft)
        let t=undoing ? history.transition.reversed() : history.transition
        let compile=try optionContext(),root=optionRoot(draft)
        var changed=try next(draft);changed.payload=undoing ? patch.before:patch.after
        let memory=draft.positions
        var manualOverride: ControlValue?
        let graph=try MappingEvaluation(payload:draft.payload,root:root,context:compile,listening:memory)
        if let manual=graph.manual[t.address.key],case .scalar(let p)=manual,
           case .scalar(let expected)=undoing ? history.afterManual:history.beforeManual {
            if t.oldChoice.option(at:p)==t.oldChoice.option(at:expected) {
                manualOverride=undoing ? history.beforeManual:history.afterManual
            }
        }
        var hands=try handChoices(draft.payload,memory:draft.positions,root:root,context:compile)
        let expectedHands=undoing ? history.afterHands:history.beforeHands
        let desiredHands=undoing ? history.beforeHands:history.afterHands
        for (key,desired) in desiredHands where hands[key]==expectedHands[key] {
            // optionMemory translates source-schema IDs; retain a direct destination override below.
            hands[key]=desired
        }
        changed.positions=try optionMemory(memory,from:draft.payload,to:changed.payload,transitions:[t],root:root,context:compile,desiredHands:hands)
        if let manualOverride {
            changed.positions=changed.positions.setting(t.address.key,to:manualOverride)
            let solved=try MappingEvaluation(payload:changed.payload,root:root,context:compile,listening:changed.positions,preservingHands:hands)
            changed.positions.adjustments=solved.resolvedAdjustments
        }
        changed.optionRemovals=undoing ? history.beforeRemovals:history.afterRemovals
        // After publication, an inverse is a new unpublished edit of the current base.
        guard let currentBase = try owner().metadata.revisions.first(where: { $0.definition.reference == changed.base })?.payload else { throw LibraryError.missingReference }
        let publishedSchema = try CompiledSound(payload: currentBase, root: root, reference: changed.base, context: compile, listening: UseListeningState(positions: [:])).controlSchemas[t.address.key]
        for (removed,replacement) in t.replacements where !changed.optionRemovals.contains(where: { $0.path == t.address.path && $0.control == t.address.control && $0.removed == removed }) {
            guard let publishedSchema, case .choice(let publishedChoice) = publishedSchema.face, publishedChoice.options.contains(OptionID(removed)) else { continue }
            changed.optionRemovals.append(LibraryOptionRemoval(base: changed.base, path: t.address.path, control: t.address.control,
                schema: t.oldChoice.options.map(\.rawValue), removed: removed, replacement: replacement))
        }
        changed.optionRemovals=try rebasedOptionRemovals(changed.optionRemovals,base:changed.base,payload:changed.payload)
        guard let base=try owner().metadata.revisions.first(where:{$0.definition.reference==changed.base})?.payload else {throw LibraryError.missingReference}
        changed.info=LibraryDraftInfo(id:changed.info.id,generation:changed.info.generation,structural:changed.payload.structurallyDiffers(from:base))
        try validateDraft(changed,admit:context.admit)
        if undoing {context.undo.removeLast();context.redo.append(patch)}else{context.redo.removeLast();context.undo.append(patch)}
        try trim(&context);try install(changed);libraryEdits[context.handle.id]=context
        var reportPairs = t.replacements
        if undoing {
            for (removed, replacement) in history.transition.replacements { reportPairs[replacement] = removed }
        }
        return LibraryOptionEditResult(snapshot:try libraryInspectEdit(context.handle),report:try optionReport(draft,changed,transition:t,operation:UUID(),explicitPairs:reportPairs))
    }
    func rebasedOptionRemovals(_ removals:[LibraryOptionRemoval],base:DefinitionReference,payload:LibraryPayload) throws -> [LibraryOptionRemoval] {
        let state=try owner()
        guard let original=state.metadata.revisions.first(where:{$0.definition.reference==base})?.payload else {throw LibraryError.missingReference}
        let compile=try optionContext(),root=RootUseID()
        let schemas=try CompiledSound(payload:original,root:root,reference:base,context:compile,listening:UseListeningState(positions:[:])).controlSchemas
        let current=try CompiledSound(payload:payload,root:root,reference:base,context:compile,listening:UseListeningState(positions:[:])).controlSchemas
        return removals.compactMap { r in
            let key=LibraryControlAddress(path:r.path,control:r.control).key
            guard let old=schemas[key],case .choice(let a)=old.face,let new=current[key],case .choice(let b)=new.face,
                  !b.options.contains(OptionID(r.removed)), b.options.contains(OptionID(r.replacement)) else{return nil}
            if !a.options.contains(OptionID(r.removed)) { return r }
            return LibraryOptionRemoval(base:base,path:r.path,control:r.control,schema:a.options.map(\.rawValue),removed:r.removed,replacement:r.replacement)
        }
    }
    func libraryTakeUpdateReport(_ token: UUID) throws -> LibraryUpdateReport? {
        var state=try owner();let result=state.updateReports.removeValue(forKey:token);libraryOwner=state;return result
    }
}

extension SoundDocument {
    func publicationTransitions(_ draft: LibraryWorkingDraft, replacements: [LibraryOptionReplacement]) throws -> [ChoiceOptionTransition] {
        let state = try owner(), context = try optionContext(), root = optionRoot(draft)
        let new = try CompiledSound(payload: draft.payload, root: root, reference: draft.base, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        var result: [ChoiceOptionTransition] = [], used = Set<Int>()
        let references = Set([draft.base] + draft.optionRemovals.map(\.base)).sorted { $0.version.rawValue.uuidString < $1.version.rawValue.uuidString }
        for reference in references {
            guard let previous = state.metadata.revisions.first(where: { $0.definition.reference == reference })?.payload else { throw LibraryError.missingReference }
            let old = try CompiledSound(payload: previous, root: root, reference: reference, context: context, listening: UseListeningState(positions: [:])).controlSchemas
            for (key, before) in old.sorted(by: { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) }) {
                guard case .choice(let a) = before.face, let after = new[key], case .choice(let b) = after.face, a != b else { continue }
                let address = LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue)
                var relation: [UUID: UUID] = [:]
                for id in a.options where !b.options.contains(id) {
                    guard let saved = draft.optionRemovals.first(where: { $0.path == address.path && $0.control == address.control && $0.removed == id.rawValue }) else { throw LibraryOptionError.replacementRequired(address, id.rawValue) }
                    let matching = replacements.indices.filter { replacements[$0].address == address && replacements[$0].removed == id.rawValue }
                    guard matching.count <= 1 else { throw LibraryOptionError.invalidMutation }
                    let chosen = matching.first.map { replacements[$0].replacement } ?? saved.replacement
                    guard chosen != id.rawValue, b.options.contains(OptionID(chosen)) else { throw LibraryOptionError.invalidMutation }
                    if let i = matching.first { used.insert(i) }; relation[id.rawValue] = chosen
                }
                let transition = ChoiceOptionTransition(address: address, before: before, after: after, replacements: relation, copyNeighbor: nil)
                if !result.contains(where: { $0.address == address && $0.before.face == before.face }) { result.append(transition) }
            }
        }
        for i in replacements.indices where !used.contains(i) {
            let r = replacements[i]
            guard draft.optionRemovals.contains(where: { $0.summary.address == r.address && $0.removed == r.removed && $0.replacement == r.replacement }) else { throw LibraryOptionError.invalidMutation }
        }
        return result
    }
    func publicationChoiceChanges(_ before: [LibraryChoiceObservation], _ after: [LibraryChoiceObservation],
                                  transitions: [ChoiceOptionTransition], places: [LibraryUpdatePlace]) -> [LibraryChoiceChange] {
        choiceChanges(before, after).map { change in
            let explicit = places.contains { place in
                guard case .use(_, let id) = change.place, id == place.use else { return false }
                return transitions.contains { t in t.prefixed(place.path).address == change.address && t.replacements[change.before] == change.after }
            }
            return LibraryChoiceChange(place: change.place, address: change.address, before: change.before, after: change.after,
                reason: explicit ? .explicitReplacement : .redistribution)
        }
    }
    func publicationObservations(content: DocumentContent, state: LibraryOwnerState) throws -> [LibraryChoiceObservation] {
        let metadata = state.effectiveMetadata, context = try metadata.context(profiles: state.profiles, limits: state.limits)
        var result: [LibraryChoiceObservation] = []
        for use in metadata.owned {
            result += try choiceObservations(metadata.payload(root: use.use.id), memory: content.listening[use.use.id] ?? UseListeningState(positions: [:]),
                root: use.use.id, place: .use(app: use.target.bundleIdentifier, use: use.use.id.rawValue), context: context)
        }
        for workspace in metadata.workspaces {
            result += try choiceObservations(workspace.payload, memory: workspace.listening(), root: RootUseID(workspace.info.id),
                place: .workspace(definition: workspace.definition.rawValue), context: context)
        }
        return result
    }
    func publicationRebasedRemovals(_ removals: [LibraryOptionRemoval], base: DefinitionReference,
                                    original: LibraryPayload, payload: LibraryPayload, context: LibraryCompileContext) throws -> [LibraryOptionRemoval] {
        let root = RootUseID()
        let old = try CompiledSound(payload: original, root: root, reference: base, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        let new = try CompiledSound(payload: payload, root: root, reference: base, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        return removals.compactMap { r in
            let key = LibraryControlAddress(path: r.path, control: r.control).key
            guard let a = old[key], case .choice(let x) = a.face, let b = new[key], case .choice(let y) = b.face,
                  !y.options.contains(OptionID(r.removed)), y.options.contains(OptionID(r.replacement)) else { return nil }
            if !x.options.contains(OptionID(r.removed)) { return r }
            return LibraryOptionRemoval(base: base, path: r.path, control: r.control, schema: x.options.map(\.rawValue), removed: r.removed, replacement: r.replacement)
        }
    }
}

extension SoundDocument {
    func publicationCacheBytes(_ state: LibraryOwnerState) throws -> Int {
        try libraryPublicationPlans.values.reduce(state.updateReports.values.reduce(0) { $0 + $1.retainedBytes }) { total, plan in
            total + (try plan.metadata.archive(content: plan.content, enabled: false, token: plan.preview.id).encoded(limits: state.limits).count)
                + (try plan.sourcePayload.canonicalData.count) + plan.preview.retainedBytes + plan.reportReserve
        }
    }
    func publicationReportReserve(content: DocumentContent, state: LibraryOwnerState) throws -> Int {
        // An actual report is a subset of the BEFORE addresses. Fixed-width UUIDs and the longest reason reserve each row.
        let rows = try publicationObservations(content: content, state: state).map {
            LibraryChoiceChange(place: $0.place, address: $0.address, before: $0.option, after: $0.option, reason: .explicitReplacement)
        }
        return LibraryChoiceReport(operation: UUID(), liveGeneration: UInt64.max, changes: rows).retainedBytes + 192
    }
}

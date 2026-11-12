import Foundation

extension SoundDocument {
    func editContext(_ handle: LibraryEditHandle, generation: UInt64? = nil) throws -> (LibraryEditContext, LibraryWorkingDraft) {
        guard let context = libraryEdits[handle.id], (context.handle == handle || context.priorHandles.contains(handle)),
              let draft = try owner().drafts[context.owner], draft.base == context.handle.base.reference,
              generation == nil || generation == draft.info.generation else { throw LibraryError.staleEdit }
        if case .use(let binding) = handle.target, !matches(binding) { throw LibraryError.staleBinding }
        return (context, draft)
    }
    func positions(_ draft: LibraryWorkingDraft) -> UseListeningState {
        if case .use(let root) = draft.owner { return content.listening[root] ?? UseListeningState(positions: [:]) }
        return draft.positions
    }
    func compileDraft(_ draft: LibraryWorkingDraft, listening: UseListeningState) throws -> CompiledSound {
        let state = try owner()
        let root: RootUseID
        if case .use(let id) = draft.owner { root = id } else { root = RootUseID(draft.info.id) }
        return try CompiledSound(payload: draft.payload, root: root, reference: draft.base,
            context: state.effectiveMetadata.context(profiles: state.profiles, limits: state.limits), listening: listening)
    }
    func validateDraft(_ draft: LibraryWorkingDraft, admit: LibraryPartsAdmission) throws {
        var state = try owner()
        let starting = try compileDraft(draft, listening: UseListeningState(positions: [:]))
        let current = try compileDraft(draft, listening: draft.positions)
        for sound in [starting, current] {
            // Validate retained bypassed pieces too; bypass is emission, not an admission escape.
            try admit(state.profiles.native(sound, includingBypassed: true))
            try admit(state.profiles.native(sound))
        }
        state.drafts[draft.owner] = draft
        let archive = state.effectiveMetadata.archive(content: candidateContent(draft), enabled: isEnabled, token: UUID())
        _ = try archive.validated(profiles: state.profiles, limits: state.limits)
        _ = try archive.encoded(limits: state.limits)
        if state.pending?.publication != nil || state.uncertain?.publication != nil {
            guard try publicationCacheBytes(state) + publicationReportReserve(content: candidateContent(draft), state: state) <= state.limits.maximumBytes else { throw LibraryOptionError.reportCapacity }
        }
    }
    func candidateContent(_ draft: LibraryWorkingDraft) -> DocumentContent {
        var result = content
        if case .use(let root) = draft.owner { result.listening[root] = draft.positions }
        return result
    }
    func install(_ draft: LibraryWorkingDraft) throws {
        var state = try owner()
        state.drafts[draft.owner] = draft
        if case .use(let root) = draft.owner { content.listening[root] = draft.positions }
        state.liveGeneration &+= 1
        libraryOwner = state
    }
    func next(_ draft: LibraryWorkingDraft) throws -> LibraryWorkingDraft {
        guard draft.info.generation < UInt64.max - 1 else { throw LibraryError.limitExceeded }
        var result = draft
        result.positions = positions(draft)
        result.info = LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation + 1, structural: draft.info.structural)
        result.refusal = nil
        return result
    }
    func patch(_ before: LibraryWorkingDraft, _ after: LibraryWorkingDraft, only: Set<OccurrenceControlKey>? = nil) -> LibraryEditPatch? {
        let old = before.positions.values, new = after.positions.values
        let changes = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] && (only?.contains($0) ?? true) }.map {
            LibraryPositionPatch(key: $0, before: old[$0], after: new[$0])
        }
        guard before.payload != after.payload || before.info.structural != after.info.structural || !changes.isEmpty || before.positions.adjustments != after.positions.adjustments || before.positions.dormant != after.positions.dormant else { return nil }
        return LibraryEditPatch(before: before.payload, after: after.payload,
            beforeStructural: before.info.structural, afterStructural: after.info.structural, positions: changes,
            beforeAdjustments: before.positions.adjustments, afterAdjustments: after.positions.adjustments,
            beforeDormant: before.positions.dormant, afterDormant: after.positions.dormant)
    }
    func stage(_ changes: [LibraryPositionPatch], from draft: LibraryWorkingDraft,
                       context: inout LibraryEditContext) throws {
        guard let start = context.gesture else { throw LibraryError.unsupportedEdit }
        for change in changes {
            let prior = context.gesturePositions[change.key]
            let before = prior?.after == change.before ? prior?.before : change.before
            if before == change.after { context.gesturePositions[change.key] = nil }
            else { context.gesturePositions[change.key] = LibraryPositionPatch(key: change.key, before: before, after: change.after) }
        }
        let starting = try compileDraft(start, listening: UseListeningState(positions: [:])).controlSchemas
        let current = try compileDraft(draft, listening: UseListeningState(positions: [:])).controlSchemas
        context.gesturePositions = context.gesturePositions.filter { starting[$0.key] != nil || current[$0.key] != nil }
        let positions = Array(context.gesturePositions.values)
        if start.payload == draft.payload && start.info.structural == draft.info.structural && positions.isEmpty && start.positions.adjustments == draft.positions.adjustments && start.positions.dormant == draft.positions.dormant { context.staged = nil }
        else {
            context.staged = try ordered(LibraryEditPatch(before: start.payload, after: draft.payload,
                beforeStructural: start.info.structural, afterStructural: draft.info.structural, positions: positions,
                beforeAdjustments: start.positions.adjustments, afterAdjustments: draft.positions.adjustments,
                beforeDormant: start.positions.dormant, afterDormant: draft.positions.dormant))
        }
    }
    func advance(_ draft: LibraryWorkingDraft, context: LibraryEditContext) throws {
        let changed = try next(draft)
        try validateDraft(changed, admit: context.admit)
        try install(changed)
    }
    func ordered(_ patch: LibraryEditPatch) throws -> LibraryEditPatch {
        guard libraryHistoryClock < UInt64.max else { throw LibraryError.limitExceeded }
        libraryHistoryClock += 1
        var result = patch; result.order = libraryHistoryClock
        return result
    }
    func trim(_ context: inout LibraryEditContext) throws {
        let maximum = min(try owner().limits.maximumBytes, 8 * 1024 * 1024)
        guard (context.undo + context.redo + (context.staged.map { [$0] } ?? [])).allSatisfy({ $0.approximateBytes <= maximum }) else { throw LibraryError.limitExceeded }
        var contexts = libraryEdits; contexts[context.handle.id] = context
        func groups() -> [LibraryEditPatch] {
            contexts.values.flatMap { $0.undo + $0.redo + ($0.staged.map { [$0] } ?? []) }
        }
        while groups().count > 64 || groups().reduce(0, { $0 + $1.approximateBytes }) > maximum {
            let oldest = contexts.flatMap { id, context in
                context.undo.map { (id, true, $0.order) } + context.redo.map { (id, false, $0.order) }
            }.min { $0.2 < $1.2 }
            guard let oldest else { throw LibraryError.limitExceeded }
            if oldest.1 { contexts[oldest.0]?.undo.removeAll { $0.order == oldest.2 } }
            else { contexts[oldest.0]?.redo.removeAll { $0.order == oldest.2 } }
        }
        guard let retained = contexts[context.handle.id] else { throw LibraryError.staleEdit }
        context = retained; libraryEdits = contexts
    }
    func libraryBeginEdit(_ target: LibraryEditTarget, admit: @escaping LibraryPartsAdmission) throws -> LibraryEditSnapshot {
        var state = try owner()
        let key: LibraryDraftOwner, base: DefinitionReference, payload: LibraryPayload, info: LibraryDraftInfo
        var memory = UseListeningState(positions: [:])
        switch target {
        case .use(let binding):
            guard matches(binding) else { throw LibraryError.staleBinding }
            let root = RootUseID(binding.use)
            guard let owned = state.metadata.owned.first(where: { $0.use.id == root }) else { throw LibraryError.unknownTarget }
            key = .use(root); base = owned.use.definition
            payload = try state.effectiveMetadata.payload(root: root)
            info = owned.authoring ?? LibraryDraftInfo(id: UUID(), generation: 0, structural: false)
            memory = content.listening[root] ?? memory
        case .definition(let uuid):
            let id = DefinitionID(uuid), head = try state.metadata.definition(id)
            guard head.origin == "custom" else { throw LibraryError.protectedBuiltin }
            let saved = state.effectiveMetadata.workspaces.first { $0.definition == id }
            let record = try state.metadata.head(id)
            key = .definition(id); base = saved?.base ?? record.definition.reference
            payload = saved?.payload ?? record.payload
            info = saved?.info ?? LibraryDraftInfo(id: UUID(), generation: 0, structural: false)
            memory = try saved?.listening() ?? memory
        }
        var draft = state.drafts[key] ?? LibraryWorkingDraft(owner: key, base: base, payload: payload, info: info, positions: memory)
        if state.drafts[key] == nil {
            switch key {
            case .use(let root): draft.optionRemovals = state.metadata.owned.first(where: { $0.use.id == root })?.optionRemovals ?? []
            case .definition(let id): draft.optionRemovals = state.metadata.workspaces.first(where: { $0.definition == id })?.optionRemovals ?? []
            }
        }
        draft.positions = positions(draft)
        try validateDraft(draft, admit: admit)
        // Only one handle/history owns this context. Opening doesn't publish or move its head.
        libraryEdits = libraryEdits.filter { $0.value.owner != key }
        let handle = LibraryEditHandle(id: UUID(), target: target,
            base: LibraryReference(definition: base.id.rawValue, revision: base.version.rawValue))
        state.drafts[key] = draft; libraryOwner = state
        libraryEdits[handle.id] = LibraryEditContext(handle: handle, owner: key, admit: admit)
        return try libraryInspectEdit(handle)
    }
    func libraryInspectEdit(_ handle: LibraryEditHandle) throws -> LibraryEditSnapshot {
        let (context, draft) = try editContext(handle)
        let state = try owner(), sound = try compileDraft(draft, listening: positions(draft))
        let root: RootUseID
        if case .use(let id) = draft.owner { root = id } else { root = RootUseID(draft.info.id) }
        guard let retained = state.metadata.revisions.first(where: { $0.definition.reference == draft.base })?.payload else {
            throw LibraryError.missingReference
        }
        let retainedParts = retained.block.pieces.compactMap { piece -> SoundPart? in
            if case .part(let part) = piece { return part }; return nil
        }
        let parts = try draft.payload.block.pieces.compactMap { piece -> LibraryEditPart? in
            guard case .part(let part) = piece else { return nil }
            let spec = try state.profiles.descriptor(draft.payload.profile, type: part.type)
            let address = PartAddress(occurrence: Occurrence(root: root, path: []), part: part.id)
            let settings = try part.settings.map { setting -> LibraryEditSetting in
                let target = TargetAddress(part: address, parameter: setting.key)
                guard let descriptor = spec.parameters.first(where: { $0.key == setting.key }),
                      let position = sound.targets[target], let raw = sound.unadjusted[target] else { throw LibraryError.invalidArchive }
                let sources = draft.payload.presentation.filter { control in
                    draft.payload.block.mappings.contains {
                        $0.control.rawValue == control.id && $0.part == part.id && $0.parameter == setting.key
                    }
                }.map(\.id)
                let pinned = draft.payload.block.controls.contains { control in
                    guard case .slider = control.face,
                          draft.payload.presentation.contains(where: { $0.id == control.id.rawValue && $0.placement == .primary }) else { return false }
                    let mappings = draft.payload.block.mappings.filter { $0.control == control.id }
                    return mappings.count == 1 && mappings[0].part == part.id && mappings[0].parameter == setting.key
                }
                let original = retainedParts.first(where: { $0.id == part.id })?.settings.first(where: { $0.key == setting.key })
                let changedHere: Bool
                if case .use = draft.owner {
                    changedHere = original?.position != setting.position ||
                        retained.authored.adjustment(part.id, setting.key) != draft.payload.authored.adjustment(part.id, setting.key)
                } else { changedHere = false }
                return LibraryEditSetting(parameter: setting.key.rawValue, physicalValue: descriptor.domain.value(position),
                    unit: descriptor.unit, base: setting.position.value,
                    adjustment: draft.payload.authored.adjustment(part.id, setting.key), unadjustedSum: raw, specification: descriptor.specification,
                    sourceControls: sources, isChangedHere: changedHere, isShownAtTop: pinned)
            }
            return LibraryEditPart(id: part.id.rawValue, type: part.type,
                bypassed: draft.payload.authored.bypassed.contains(part.id), settings: settings)
        }
        let pieces = draft.payload.block.pieces.map { piece -> LibraryEditPiece in
            switch piece {
            case .part(let part): return .part(part.id.rawValue)
            case .block(let use):
                return .embedded(site: use.site.rawValue, retainedParts: sound.parts.filter { $0.address.occurrence.path.first == use.site }.count)
            case .reference(let use):
                return .reference(site: use.site.rawValue,
                    exact: LibraryReference(definition: use.definition.id.rawValue, revision: use.definition.version.rawValue),
                    retainedParts: sound.parts.filter { $0.address.occurrence.path.first == use.site }.count)
            }
        }
        let kinds = try LibraryProfiles.authoringKinds.map { type -> LibraryEditKind in
            let descriptor = try state.profiles.descriptor(draft.payload.profile, type: type)
            let failure: String?
            do {
                var candidate = try next(draft)
                candidate.info = LibraryDraftInfo(id: candidate.info.id, generation: candidate.info.generation, structural: true)
                let block = draft.payload.block
                candidate.payload = try draft.payload.replacing(block: block.replacing(pieces: block.pieces + [.part(try descriptor.seed())]))
                try validateDraft(candidate, admit: context.admit); failure = nil
            }
            catch { failure = String(describing: error) }
            return LibraryEditKind(type: type, seed: descriptor.parameters.map {
                LibraryEditSeed(parameter: $0.key.rawValue, value: $0.seed, unit: $0.unit, specification: $0.specification)
            }, insertionFailure: failure)
        }
        let durability: LibraryDraftDurability
        if let uncertain = state.uncertain { durability = .unresolved(token: uncertain.token, digest: libraryDigest(uncertain.data)) }
        else if let reason = draft.refusal { durability = .refused(reason) }
        else if let data = state.committed?.data, try durableMatches(draft, data: data) {
            let archive = try JSONDecoder().decode(LibraryArchive.self, from: data)
            durability = .saved(token: archive.commit, digest: libraryDigest(data))
        } else { durability = .unsaved }
        let coordinate = sound.controlSchemas.map { key, control in
            (LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue), LibraryPosition(control.position))
        }
        return LibraryEditSnapshot(occurrences: sound.occurrences, handle: context.handle, generation: draft.info.generation,
            pendingStructural: draft.info.structural, durability: durability,
            canUndo: context.gesture == nil && !context.undo.isEmpty, canRedo: context.gesture == nil && !context.redo.isEmpty,
            parts: parts, pieces: pieces, kinds: kinds, controls: draft.payload.presentation, positions: Dictionary(uniqueKeysWithValues: coordinate))
    }
    func durableMatches(_ draft: LibraryWorkingDraft, data: Data) throws -> Bool {
        let archive = try JSONDecoder().decode(LibraryArchive.self, from: data)
        switch draft.owner {
        case .use(let id):
            guard let old = archive.uses.first(where: { $0.use.id == id }) else { return false }
            let saved = try UseListeningState(saved: old.positions)
            return old.authoring == draft.info && old.draft == draft.payload && (old.optionRemovals ?? []) == draft.optionRemovals
                && saved == positions(draft)
        case .definition(let id):
            guard let old = archive.workspaces.first(where: { $0.definition == id }) else { return false }
            let saved = try old.listening()
            return old.info == draft.info && old.payload == draft.payload && saved == positions(draft) && (old.optionRemovals ?? []) == draft.optionRemovals
        }
    }
    func libraryEdit(_ handle: LibraryEditHandle, generation: UInt64, command: LibraryEditCommand) throws -> LibraryEditSnapshot {
        if case .mapping(let path, let edit) = command { return try libraryMappingEdit(handle, generation: generation, path: path, command: edit) }
        var (context, before) = try editContext(handle, generation: generation)
        before.positions = positions(before)
        var draft = try next(before), block = draft.payload.block, fields = draft.payload.authored
        var pieces = block.pieces, controls = block.controls, mappings = block.mappings, presentation = draft.payload.presentation
        var structural = draft.info.structural, payloadChanged = true
        func direct(_ uuid: UUID) throws -> SoundPart {
            guard let part = pieces.compactMap({ if case .part(let part) = $0, part.id.rawValue == uuid { return part }; return nil }).first else { throw LibraryError.unsupportedEdit }
            return part
        }
        switch command {
        case .mapping: throw LibraryError.unsupportedEdit
        case .setPhysical(let uuid, let name, let value):
            let part = try direct(uuid), key = try ParameterKey(name)
            guard let descriptor = try owner().profiles.descriptor(draft.payload.profile, type: part.type).parameters.first(where: { $0.key == key }) else { throw LibraryError.unsupportedEdit }
            let q = try descriptor.position(value)
            let sound = try compileDraft(before, listening: before.positions)
            guard let target = sound.unadjusted.first(where: { $0.key.part.occurrence.path.isEmpty && $0.key.part.part == part.id && $0.key.parameter == key }) else { throw LibraryError.unsupportedEdit }
            let adjustment = q.value - target.value
            guard adjustment.isFinite else { throw LibraryError.invalidCanonical }
            fields.adjustments.removeAll { $0.address.part == part.id && $0.address.parameter == key }
            fields.adjustments.append(LibraryAdjustment(address: LibrarySettingAddress(part: part.id, parameter: key), value: adjustment))
        case .addPart(let type, let index):
            guard (0...pieces.count).contains(index) else { throw LibraryError.unsupportedEdit }
            let part = try owner().profiles.descriptor(draft.payload.profile, type: type).seed()
            pieces.insert(.part(part), at: index); structural = true
        case .removePart(let uuid):
            let part = try direct(uuid)
            let incident = Set(mappings.filter { $0.part == part.id }.map(\.control))
            pieces.removeAll { if case .part(let p) = $0 { return p.id == part.id }; return false }
            mappings.removeAll { $0.part == part.id }
            let removed = incident.filter { id in !mappings.contains { $0.control == id } }
            controls.removeAll { removed.contains($0.id) }; presentation.removeAll { removed.contains(ControlID($0.id)) }
            fields.bypassed.removeAll { $0 == part.id }; fields.adjustments.removeAll { $0.address.part == part.id }
            var memory = draft.positions.values
            for key in memory.keys where key.path.isEmpty && removed.contains(key.control) { memory[key] = nil }
            draft.positions = UseListeningState(values: memory); structural = true
        case .reorderParts(let ids):
            let parts = pieces.compactMap { piece -> SoundPart? in if case .part(let part) = piece { return part }; return nil }
            guard Set(ids).count == ids.count, Set(ids) == Set(parts.map { $0.id.rawValue }) else { throw LibraryError.unsupportedEdit }
            var iterator = try ids.map { try direct($0) }.makeIterator()
            pieces = pieces.map { if case .part = $0, let part = iterator.next() { return .part(part) }; return $0 }
            structural = structural || pieces != block.pieces
        case .bypassPart(let uuid, let bypass):
            let part = try direct(uuid)
            fields.bypassed.removeAll { $0 == part.id }; if bypass { fields.bypassed.append(part.id) }
        case .showAtTop(let uuid, let name, let title):
            try libraryName(title)
            let part = try direct(uuid), key = try ParameterKey(name)
            guard let descriptor = try owner().profiles.descriptor(draft.payload.profile, type: part.type).parameters.first(where: { $0.key == key }),
                  !descriptor.discrete, let setting = part.settings.first(where: { $0.key == key }) else { throw LibraryError.unsupportedEdit }
            if let control = controls.first(where: { control in
                guard case .slider = control.face else { return false }
                let targets = mappings.filter { $0.control == control.id }
                return targets.count == 1 && targets[0].part == part.id && targets[0].parameter == key
            }), let index = presentation.firstIndex(where: { $0.id == control.id.rawValue }) {
                let old = presentation[index]
                if old.placement == .primary { return try libraryInspectEdit(handle) }
                structural = true
                presentation[index] = LibraryControl(id: old.id, title: old.title, face: old.face, placement: .primary, readout: old.readout)
            } else {
                let b = setting.position, id = ControlID()
                var points: [Position] = [.start]
                if b != .start && b != .end { points.append(b) }; points.append(.end)
                controls.append(SoundControl(id: id, face: .slider, position: .scalar(b), waypoints: .scalar(points)))
                mappings.append(ParameterMapping(control: id, axis: .value, part: part.id, parameter: key,
                    curve: try MappingCurve(waypoints: points.map { Waypoint(position: $0, value: $0) }, shapes: Array(repeating: .straight, count: points.count - 1))))
                presentation.append(LibraryControl(id: id.rawValue, title: title, face: .slider("", ""), placement: .primary, readout: nil))
                draft.positions = draft.positions.setting(OccurrenceControlKey(path: [], control: id), to: .scalar(b))
                structural = true
            }
        case .moveControl(let address, let value):
            let key = address.key, sound = try compileDraft(before, listening: before.positions)
            guard sound.controlSchemas[key] != nil else { throw LibraryError.unsupportedEdit }
            draft.positions = try mappingMove(before, key: key, value: value.validated())
            payloadChanged = false
        }
        if payloadChanged {
            if block.bindings != nil {
                guard mappings.isEmpty else { throw LibraryError.unsupportedEdit }
                block = block.replacing(pieces: pieces, controls: controls)
            } else { block = SoundBlock(pieces: pieces, controls: controls, mappings: mappings) }
            draft.payload = try draft.payload.replacing(block: block, presentation: presentation, fields: fields)
        }
        draft.info = LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation, structural: structural)
        try validateDraft(draft, admit: context.admit)
        let inverse = patch(before, draft)
        if context.gesture != nil {
            var changes = inverse?.positions ?? []
            if case .moveControl(let address, _) = command, !changes.contains(where: { $0.key == address.key }) {
                changes.append(LibraryPositionPatch(key: address.key, before: before.positions.values[address.key], after: draft.positions.values[address.key]))
            }
            try stage(changes, from: draft, context: &context)
        } else {
            guard let inverse else { return try libraryInspectEdit(handle) }
            context.undo.append(try ordered(inverse)); context.redo.removeAll()
        }
        try trim(&context)
        try install(draft)
        libraryEdits[handle.id] = context
        return try libraryInspectEdit(handle)
    }
    func libraryEditGesture(_ handle: LibraryEditHandle, generation: UInt64, action: Int) throws -> LibraryEditSnapshot {
        var (context, draft) = try editContext(handle, generation: generation)
        draft.positions = positions(draft)
        if action == 0 {
            guard try owner().pending?.publication == nil else { throw LibraryError.unsupportedEdit }
            guard context.gesture == nil else { throw LibraryError.unsupportedEdit }
            context.gesture = draft; context.gesturePositions = [:]; context.staged = nil
        } else {
            guard context.gesture != nil else { throw LibraryError.unsupportedEdit }
            if action == 2 {
                if let inverse = context.staged {
                    if try applyPatch(inverse, undoing: true, draft: draft, context: context) == nil { try advance(draft, context: context) }
                } else { try advance(draft, context: context) }
            } else if let inverse = context.staged {
                context.staged = nil; context.undo.append(inverse); context.redo.removeAll(); try trim(&context)
            }
            context.gesture = nil; context.gesturePositions = [:]; context.staged = nil
        }
        libraryEdits[handle.id] = context
        return try libraryInspectEdit(handle)
    }
    func applyPatch(_ patch: LibraryEditPatch, undoing: Bool, draft: LibraryWorkingDraft,
                            context: LibraryEditContext) throws -> LibraryEditPatch? {
        var changed = try next(draft)
        changed.payload = undoing ? patch.before : patch.after
        changed.info = LibraryDraftInfo(id: changed.info.id, generation: changed.info.generation,
            structural: undoing ? patch.beforeStructural : patch.afterStructural)
        var memory = positions(draft).values
        var applied: [LibraryPositionPatch] = []
        for item in patch.positions {
            let expected = undoing ? item.after : item.before
            if memory[item.key] == expected { memory[item.key] = undoing ? item.before : item.after; applied.append(item) }
        }
        let schema = try compileDraft(changed, listening: UseListeningState(positions: [:])).controlSchemas
        memory = memory.filter { schema[$0.key] != nil }
        var adjustments = positions(draft).adjustments
        let expectedAdjustments = undoing ? patch.afterAdjustments : patch.beforeAdjustments
        let desiredAdjustments = undoing ? patch.beforeAdjustments : patch.afterAdjustments
        let keys = Set(expectedAdjustments.map(\.key)).union(desiredAdjustments.map(\.key))
        for key in keys {
            if adjustments.first(where: { $0.key == key }) == expectedAdjustments.first(where: { $0.key == key }) {
                adjustments.removeAll { $0.key == key }
                if let item = desiredAdjustments.first(where: { $0.key == key }) { adjustments.append(item) }
            }
        }
        adjustments = adjustments.filter { schema[$0.key.controlKey] != nil }
        let dormant = positions(draft).dormant == (undoing ? patch.afterDormant : patch.beforeDormant)
            ? (undoing ? patch.beforeDormant : patch.afterDormant) : positions(draft).dormant
        changed.positions = UseListeningState(values: memory, adjustments: adjustments, dormant: dormant)
        guard changed.payload != draft.payload || changed.info.structural != draft.info.structural || changed.positions != positions(draft) else { return nil }
        try validateDraft(changed, admit: context.admit)
        try install(changed)
        return LibraryEditPatch(order: patch.order, before: patch.before, after: patch.after, beforeStructural: patch.beforeStructural, afterStructural: patch.afterStructural, positions: applied,
            beforeAdjustments: patch.beforeAdjustments, afterAdjustments: patch.afterAdjustments, beforeDormant: patch.beforeDormant, afterDormant: patch.afterDormant)
    }
    func libraryCheckpointEdit(_ handle: LibraryEditHandle, generation: UInt64) async throws -> LibraryCommit {
        _ = try editContext(handle, generation: generation)
        try await settleWriter()
        _ = try editContext(handle)
        // The central captured-token path owns refusal/acceptance bookkeeping for
        // both checkpoint callers; a late wrapper must not restamp a newer draft.
        return try await persist(content, metadata: owner().metadata)
    }

    func libraryUpdateLabelDraft(_ payload: LibraryPayload, root: RootUseID) throws {
        guard var before = try owner().drafts[.use(root)] else { throw LibraryError.staleEdit }
        before.positions = positions(before)
        var changed = try next(before); changed.payload = payload
        if var context = libraryEdits.values.first(where: { $0.owner == before.owner }) {
            try validateDraft(changed, admit: context.admit)
            if let inverse = patch(before, changed) {
                if context.gesture != nil {
                    try stage(inverse.positions, from: changed, context: &context)
                } else { context.undo.append(try ordered(inverse)); context.redo.removeAll() }
                try trim(&context)
                libraryEdits[context.handle.id] = context
            }
        } else {
            var state = try owner(); state.drafts[before.owner] = changed
            let archive = state.effectiveMetadata.archive(content: candidateContent(changed), enabled: isEnabled, token: UUID())
            _ = try archive.validated(profiles: state.profiles, limits: state.limits)
            _ = try archive.encoded(limits: state.limits)
        }
        try install(changed)
    }
    func libraryDiscardEdit(_ handle: LibraryEditHandle, generation: UInt64) throws -> LibraryEditSnapshot {
        var (context, draft) = try editContext(handle, generation: generation)
        let state = try owner()
        guard state.pending == nil, state.uncertain == nil else { throw LibraryError.durableStateUnresolved }
        guard let committed = state.committed?.data else { throw LibraryError.unsupportedEdit }
        let durable = try JSONDecoder().decode(LibraryArchive.self, from: committed)
        var restored = try next(draft)
        let base = state.metadata.revisions.first { $0.definition.reference == draft.base }
        guard let base else { throw LibraryError.missingReference }
        let structural: Bool
        let durableMemory: UseListeningState
        switch draft.owner {
        case .use(let root):
            let saved = durable.uses.first { $0.use.id == root }
            restored.payload = saved?.draft ?? base.payload; restored.optionRemovals = saved?.optionRemovals ?? []
            structural = saved?.authoring?.structural ?? false
            durableMemory = try UseListeningState(saved: saved?.positions ?? [])
        case .definition(let id):
            let saved = durable.workspaces.first { $0.definition == id }
            restored.payload = saved?.payload ?? base.payload; restored.optionRemovals = saved?.optionRemovals ?? []
            structural = saved?.info.structural ?? false
            durableMemory = try saved?.listening() ?? UseListeningState(positions: [:])
        }
        restored.info = LibraryDraftInfo(id: draft.info.id, generation: restored.info.generation, structural: structural)
        let schema = try compileDraft(restored, listening: UseListeningState(positions: [:])).controlSchemas
        let priorSchema = try compileDraft(draft, listening: UseListeningState(positions: [:])).controlSchemas
        var memory = positions(draft).values.filter { schema[$0.key] != nil }
        for (key, value) in durableMemory.values where memory[key] == nil && schema[key] != nil && priorSchema[key] == nil { memory[key] = value }
        restored.positions = UseListeningState(values: memory, adjustments: positions(draft).adjustments.filter { schema[$0.key.controlKey] != nil }, dormant: positions(draft).dormant)
        let compile = try optionContext(), root = optionRoot(draft)
        var transitions: [ChoiceOptionTransition] = []
        for (key,c) in priorSchema {
            guard case .choice(let a) = c.face, let target = schema[key], case .choice(let b) = target.face, a != b else { continue }
            let fallback = b.option(at: try target.position(on: .value)).rawValue
            let replacements = Dictionary(uniqueKeysWithValues: a.options.filter { !b.options.contains($0) }.map { option in
                let saved = restored.optionRemovals.first { $0.path == key.path.map(\.rawValue) && $0.control == key.control.rawValue && $0.removed == option.rawValue && b.options.contains(OptionID($0.replacement)) }
                return (option.rawValue, saved?.replacement ?? fallback)
            })
            transitions.append(ChoiceOptionTransition(address: LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue), before: c, after: target, replacements: replacements, copyNeighbor: nil))
        }
        if !transitions.isEmpty {
            let remapped = try optionMemory(positions(draft), from: draft.payload, to: restored.payload, transitions: transitions, root: root, context: compile)
            var values = remapped.values.filter { schema[$0.key] != nil }
            for (key, value) in memory where values[key] == nil { values[key] = value }
            restored.positions = UseListeningState(values: values, adjustments: remapped.adjustments,
                dormant: remapped.dormant.filter { item in positions(draft).dormant.contains { $0.key == item.key } })
        }
        try validateDraft(restored, admit: context.admit); try install(restored)
        context.undo.removeAll(); context.redo.removeAll(); context.gesture = nil; context.staged = nil; context.gesturePositions = [:]; libraryEdits[handle.id] = context
        return try libraryInspectEdit(handle)
    }
    func libraryDoneEdit(_ handle: LibraryEditHandle, generation: UInt64) throws -> LibraryEditSnapshot {
        let (context, _) = try editContext(handle, generation: generation)
        guard context.gesture == nil else { throw LibraryError.unsupportedEdit }
        let result = try libraryInspectEdit(handle); libraryEdits[handle.id] = nil
        return result
    }
}

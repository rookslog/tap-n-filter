import Foundation

extension ChoiceOptionTransition {
    func transfer(_ transfer: MappingTransfer, source: Bool, target: Bool) throws -> MappingTransfer {
        switch transfer {
        case .choices(let entries):
            var values = entries
            if source {
                values = try newChoice.options.map { option in
                    let id = oldChoice.options.contains(option) ? option.rawValue : copyNeighbor
                    guard let id, let value = entries.first(where: { $0.option == id }) else { throw LibraryError.invalidCanonical }
                    return LibrarySourceOptionValue(option: option.rawValue, value: value.value)
                }
            }
            return .choices(try values.map { LibrarySourceOptionValue(option: $0.option,
                value: target ? try anchor(Position($0.value)).value : $0.value) })
        case .continuous(let curve):
            guard target else { return transfer }
            var changed = curve
            for p in curve.waypoints {
                let desired = try anchor(p.value)
                if desired != p.value { changed = try changed.settingValue(desired, at: p.position) }
            }
            return .continuous(changed)
        }
    }
    func binding(_ binding: MappingBinding, at path: [UUID]) throws -> MappingBinding {
        func same(_ c: SoundControl?) -> Bool { c?.face == before.face && c?.waypoints == before.waypoints }
        let source = path == address.path && binding.source.control == address.control && same(binding.provenance.source)
        let selector = path == address.path && binding.response.selector?.rawValue == address.control && same(binding.provenance.selector)
        let target: Bool
        if case .control(let site, let control, _) = binding.target {
            target = path + (site.map { [$0] } ?? []) == address.path && control == address.control && same(binding.provenance.target)
        } else { target = false }
        guard source || selector || target else { return binding }
        let response: MappingResponse
        switch binding.response {
        case .lane(let lane): response = .lane(try transfer(lane, source: source, target: target))
        case .options(let id, let original):
            let cases: [MappingCase]
            if selector {
                cases = try newChoice.options.map { option in
                    let copied = oldChoice.options.contains(option) ? option.rawValue : copyNeighbor
                    guard let copied, let item = original.first(where: { $0.option.rawValue == copied }) else { throw LibraryError.invalidCanonical }
                    return MappingCase(option: option, lane: item.lane)
                }
            } else { cases = original }
            response = .options(selector: id, cases: try cases.map {
                MappingCase(option: $0.option, lane: try transfer($0.lane, source: source, target: target))
            })
        }
        return MappingBinding(id: binding.id, source: binding.source, target: binding.target,
            reference: target ? try anchor(binding.reference) : binding.reference, response: response,
            status: binding.status, provenance: MappingProvenance(source: source ? after : binding.provenance.source,
                selector: selector ? after : binding.provenance.selector, target: target ? after : binding.provenance.target,
                setting: binding.provenance.setting))
    }
}

extension LibraryPayload {
    func changingOptions(_ transition: ChoiceOptionTransition, options: [LibraryOption]? = nil,
                         path: [UUID] = []) throws -> LibraryPayload {
        let own = path == transition.address.path && block.controls.contains { $0.id.rawValue == transition.address.control && $0.face == transition.before.face }
        let incoming = block.bindings?.contains { b in
            if case .control(let site, let id, _) = b.target {
                return path + (site.map { [$0] } ?? []) == transition.address.path && id == transition.address.control
            }; return false
        } ?? false
        let legacySource = own && block.mappings.contains { $0.control.rawValue == transition.address.control }
        var changed = legacySource || incoming ? try block.promoted() : block
        var pieces: [BlockPiece] = []
        for piece in changed.pieces {
            if case .block(let child) = piece, let p = child.payload, let original = child.original {
                pieces.append(.block(BlockUse(site: child.site,
                    payload: try p.changingOptions(transition, options: options, path: path + [child.site.rawValue]), original: original)))
            } else { pieces.append(piece) }
        }
        let controls = changed.controls.map { c in own && c.id.rawValue == transition.address.control ? transition.after : c }
        changed = changed.replacing(pieces: pieces, controls: controls)
        if let bindings = changed.bindings { changed = changed.replacing(bindings: try bindings.map { try transition.binding($0, at: path) }) }
        let display = presentation.map { item -> LibraryControl in
            guard own, item.id == transition.address.control, let options else { return item }
            return LibraryControl(id: item.id, title: item.title, face: .choice(options), placement: item.placement, readout: item.readout)
        }
        let defaults = try descendantDefaults.map { item -> LibrarySavedPosition in
            guard path + item.path.map(\.rawValue) == transition.address.path, item.id.rawValue == transition.address.control else { return item }
            var item = item
            item = LibrarySavedPosition(id: item.id, value: try transition.value(item.value), path: item.path)
            return item
        }
        guard changed != block || display != presentation || defaults != descendantDefaults else { return self }
        return LibraryPayload(profile: profile, block: changed, presentation: display,
            canonicalVersion: changed.needsVersion5 ? 5 : (changed.needsVersion4 ? max(4, canonicalVersion) : max(3, canonicalVersion)), descendantDefaults: defaults, authored: authored)
    }
}

func validateOptionRemovals(_ optional: [LibraryOptionRemoval]?, base: DefinitionReference,
                           payload: LibraryPayload, context: LibraryCompileContext) throws {
    guard let removals = optional else { return }
    guard !removals.isEmpty else { throw LibraryError.invalidArchive }
    let schemas = try CompiledSound(payload: payload, root: RootUseID(), reference: base,
        context: context, listening: UseListeningState(positions: [:])).controlSchemas
    var seen = Set<String>()
    for r in removals {
        let key = LibraryControlAddress(path: r.path, control: r.control).key
        guard r.base.id == base.id, context.revisions[r.base] != nil, (2...64).contains(r.schema.count), Set(r.schema).count == r.schema.count,
              r.schema.contains(r.removed), r.removed != r.replacement,
              let control = schemas[key], case .choice(let choice) = control.face,
              !choice.options.contains(OptionID(r.removed)), choice.options.contains(OptionID(r.replacement)),
              r.schema.allSatisfy({ id in choice.options.contains(OptionID(id)) || removals.contains(where: { $0.path == r.path && $0.control == r.control && $0.removed == id }) }),
              seen.insert(r.path.map(\.uuidString).joined()+r.control.uuidString+r.removed.uuidString).inserted
        else { throw LibraryError.invalidArchive }
    }
}

struct LibraryChoiceObservation: Equatable, Sendable {
    let place: LibraryChoicePlace
    let address: LibraryControlAddress
    let option: UUID
}
extension SoundDocument {
    func choicePlace(_ draft: LibraryWorkingDraft) throws -> LibraryChoicePlace {
        switch draft.owner {
        case .definition(let id): return .workspace(definition: id.rawValue)
        case .use(let root):
            guard let use = try owner().metadata.owned.first(where: { $0.use.id == root }) else { throw LibraryError.unknownTarget }
            return .use(app: use.target.bundleIdentifier, use: root.rawValue)
        }
    }
    func choiceObservations(_ payload: LibraryPayload, memory: UseListeningState, root: RootUseID,
                            place: LibraryChoicePlace, context: LibraryCompileContext) throws -> [LibraryChoiceObservation] {
        let graph = try MappingEvaluation(payload: payload, root: root, context: context, listening: memory)
        let schemas = try CompiledSound(payload: payload, root: root, reference: nil, context: context,
            listening: UseListeningState(positions: [:])).controlSchemas
        return schemas.compactMap { key,c in
            guard case .choice(let choice) = c.face, case .scalar(let value) = graph.effective.values[key] else { return nil }
            return LibraryChoiceObservation(place: place, address: LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue), option: choice.option(at: value).rawValue)
        }.sorted { ($0.address.path.map(\.uuidString).joined()+$0.address.control.uuidString) < ($1.address.path.map(\.uuidString).joined()+$1.address.control.uuidString) }
    }
    func choiceChanges(_ before: [LibraryChoiceObservation], _ after: [LibraryChoiceObservation],
                       replacements: [UUID: UUID] = [:]) -> [LibraryChoiceChange] {
        before.compactMap { a in
            guard let b = after.first(where: { $0.place == a.place && $0.address == a.address }), a.option != b.option else { return nil }
            return LibraryChoiceChange(place: a.place, address: a.address, before: a.option, after: b.option,
                reason: replacements[a.option] == b.option ? .explicitReplacement : .redistribution)
        }
    }
    func handChoices(_ payload: LibraryPayload, memory: UseListeningState, root: RootUseID,
                     context: LibraryCompileContext) throws -> [MappingAxisKey: OptionID] {
        let graph = try MappingEvaluation(payload: payload, root: root, context: context, listening: memory)
        let schemas = try CompiledSound(payload: payload, root: root, reference: nil, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        var result: [MappingAxisKey: OptionID] = [:]
        for a in memory.adjustments {
            if let c = schemas[a.key.controlKey], case .choice(let choice) = c.face,
               case .scalar(let p) = graph.effective.values[a.key.controlKey] { result[a.key] = choice.option(at: p) }
        }
        return result
    }
    func optionMemory(_ memory: UseListeningState, from old: LibraryPayload, to new: LibraryPayload,
                      transitions: [ChoiceOptionTransition], root: RootUseID, context: LibraryCompileContext,
                      desiredHands: [MappingAxisKey: OptionID]? = nil) throws -> UseListeningState {
        let oldSchema = try CompiledSound(payload: old, root: root, reference: nil, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        var changed = memory
        let applicable = transitions.filter { oldSchema[$0.address.key]?.face == $0.before.face }
        for t in applicable {
            if let v = changed.values[t.address.key] { changed = changed.setting(t.address.key, to: try t.value(v)) }
            changed.dormant = try changed.dormant.map { item in
                guard item.key == t.address.key, item.retiredControl?.face == t.before.face else { return item }
                var x = LibrarySavedPosition(id: item.id, value: try t.value(item.value), path: item.path)
                x.dormant = true; x.retiredControl = t.after; x.adjustments = item.adjustments; return x
            }
        }
        var hands = try desiredHands ?? handChoices(old, memory: memory, root: root, context: context)
        for (key,option) in hands {
            if let t = applicable.first(where: { $0.address.key == key.controlKey }) { hands[key] = OptionID(try t.destination(option.rawValue)) }
        }
        let newSchema = try CompiledSound(payload: new, root: root, reference: nil, context: context, listening: UseListeningState(positions: [:])).controlSchemas
        for key in changed.values.keys where newSchema[key] == nil {
            guard let retired = oldSchema[key], let value = changed.values[key] else { throw LibraryError.invalidCanonical }
            changed = changed.setting(key, to: nil)
            var item = LibrarySavedPosition(id: key.control, value: value, path: key.path)
            item.dormant = true; item.retiredControl = retired
            item.adjustments = changed.adjustments.filter { $0.key.controlKey == key }.map { MappingAxisDelta(axis: $0.key.axis, value: $0.value) }
            changed.dormant.removeAll { $0.key == key }; changed.dormant.append(item)
            changed.adjustments.removeAll { $0.key.controlKey == key }
        }
        let solved = try MappingEvaluation(payload: new, root: root, context: context, listening: changed, preservingHands: hands)
        changed.adjustments = solved.resolvedAdjustments
        return changed
    }
}

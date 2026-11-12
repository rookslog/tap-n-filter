import Foundation

public enum LibraryControlCreation: Sendable {
    case slider(id: UUID, title: String, initial: Double, waypoints: [Double])
    case xy(id: UUID, title: String, initialX: Double, initialY: Double,
        xWaypoints: [Double], yWaypoints: [Double])
    case choice(id: UUID, title: String, options: [LibraryOption], initial: UUID)
}
public struct LibrarySelectorPreview: Equatable, Sendable {
    public let handle: LibraryEditHandle
    public let generation: UInt64
    public let path: [UUID]
    public let source: UUID
    public let selector: UUID
    public let option: UUID
    public let fingerprint: String
}
public enum LibraryMappingCommand: Sendable {
    case create(LibraryControlCreation)
    case settingBase(part: UUID, parameter: String, normalized: Double)
    case connectLegacy(source: LibraryMappingSource, part: UUID, parameter: String)
    case connectOptions(id: UUID, source: LibraryMappingSource, target: LibraryMappingTarget, selector: UUID)
    case connect(id: UUID, source: LibraryMappingSource, target: LibraryMappingTarget)
    case sourceValue(binding: UUID, selectorOption: UUID?, sourceOption: UUID, value: Double)
    case lane(binding: UUID, option: UUID?, lane: LibraryMappingLane)
    case point(binding: UUID, option: UUID?, position: Double, value: Double)
    case insertPoint(binding: UUID, option: UUID?, position: Double)
    case stretch(binding: UUID, option: UUID?, index: Int, shape: LibraryStretch, jump: Double)
    case differentForOptions(source: UUID, selector: UUID)
    case sameForAll(LibrarySelectorPreview)
    case choiceOptions(control: UUID, options: [LibraryOption], tables: [UUID: [UUID: LibraryMappingLane]])
    case rename(control: UUID, title: String)
    case removeBinding(UUID)
    case removeControl(UUID)
    case repair(binding: UUID, target: LibraryMappingTarget)
    case makeLocal(path: [UUID])
    case makeLocalAndForward(source: LibraryMappingSource, target: LibraryControlAddress, axis: ControlAxis)
}

extension LibraryPayload {
    func localPayload(at path: [UUID]) throws -> LibraryPayload {
        guard let site = path.first else { return self }
        guard let child = block.pieces.compactMap({ if case .block(let c) = $0, c.site.rawValue == site { return c.payload }; return nil }).first else { throw LibraryError.unsupportedEdit }
        return try child.localPayload(at: Array(path.dropFirst()))
    }
    func replacingLocal(at path: [UUID], transform: (LibraryPayload) throws -> LibraryPayload) throws -> LibraryPayload {
        guard let site = path.first else { return try transform(self) }
        var pieces = block.pieces
        guard let index = pieces.firstIndex(where: { if case .block(let c) = $0 { return c.site.rawValue == site }; return false }),
              case .block(let child) = pieces[index], let payload = child.payload, let original = child.original else { throw LibraryError.unsupportedEdit }
        pieces[index] = .block(BlockUse(site: child.site, payload: try payload.replacingLocal(at: Array(path.dropFirst()), transform: transform), original: original))
        return try replacing(block: block.replacing(pieces: pieces))
    }
    func localizing(_ path: [UUID], context: LibraryCompileContext) throws -> LibraryPayload {
        guard let site = path.first else { return self }
        var pieces = block.pieces
        guard let index = pieces.firstIndex(where: {
            switch $0 { case .reference(let c): return c.site.rawValue == site; case .block(let c): return c.site.rawValue == site; default: return false }
        }) else { throw LibraryError.unsupportedEdit }
        let child: LibraryPayload, original: DefinitionReference
        switch pieces[index] {
        case .reference(let c): guard let p = context.revisions[c.definition] else { throw LibraryError.missingReference }; child = p; original = c.definition
        case .block(let c): guard let p = c.payload, let ref = c.original else { throw LibraryError.unsupportedEdit }; child = p; original = ref
        default: throw LibraryError.unsupportedEdit
        }
        pieces[index] = .block(BlockUse(site: UseSiteID(site), payload: try child.localizing(Array(path.dropFirst()), context: context), original: original))
        return try replacing(block: block.replacing(pieces: pieces))
    }
}

extension SoundDocument {
    func mappingGraph(_ draft: LibraryWorkingDraft, listening: UseListeningState) throws -> MappingEvaluation {
        let state = try owner()
        let root: RootUseID
        if case .use(let id) = draft.owner { root = id } else { root = RootUseID(draft.info.id) }
        return try MappingEvaluation(payload: draft.payload, root: root,
            context: state.effectiveMetadata.context(profiles: state.profiles, limits: state.limits), listening: listening)
    }
    func libraryMappings(_ handle: LibraryEditHandle) throws -> LibraryMappingSnapshot {
        let (_, draft) = try editContext(handle)
        let memory = positions(draft), graph = try mappingGraph(draft, listening: memory)
        let compile = try optionContext()
        let schemas = try compileDraft(draft, listening: UseListeningState(positions: [:])).controlSchemas
        var rows: [(path: [UseSiteID], binding: MappingBinding, storage: LibraryMappingStorageKind)] = []
        var presentation: [OccurrenceControlKey: LibraryControl] = [:]
        var storage: [[UseSiteID]: LibraryMappingStorageKind] = [:]
        func visit(_ block: SoundBlock, payload: LibraryPayload?, path: [UseSiteID]) throws {
            let kind: LibraryMappingStorageKind = block.bindings == nil ? .legacy : .bindings
            storage[path] = kind
            for control in payload?.presentation ?? [] { presentation[OccurrenceControlKey(path: path, control: ControlID(control.id))] = control }
            for binding in try block.promoted().bindings ?? [] { rows.append((path, binding, kind)) }
            for piece in block.pieces {
                switch piece {
                case .part: break
                case .reference(let child):
                    guard let p = compile.revisions[child.definition] else { throw LibraryError.missingReference }
                    try visit(p.block, payload: p, path: path + [child.site])
                case .block(let child): try visit(child.content, payload: child.payload, path: path + [child.site])
                }
            }
        }
        try visit(draft.payload.block, payload: draft.payload, path: [])
        let bindings = try rows.map { path, b, kind in
            let lane: LibraryMappingLane?, cases: [UUID: LibraryMappingLane]
            switch b.response {
            case .lane(let c): lane = c.curve.map(LibraryMappingLane.init); cases = [:]
            case .options(_, let cs): lane = nil; cases = Dictionary(uniqueKeysWithValues: cs.compactMap { item in item.lane.curve.map { (item.option.rawValue, LibraryMappingLane(curve: $0)) } })
            }
            let broken: LibraryMappingBreak?
            if case .broken(let why) = b.status { broken = why } else { broken = nil }
            return LibraryMappingSummary(id: b.id, path: path.map(\.rawValue), source: b.source, target: b.target,
                reference: b.reference.value, selector: b.response.selector?.rawValue, lane: lane, cases: cases,
                sourceValues: { if case .lane(let t) = b.response { return t.values }; return [:] }(),
                caseSourceValues: { if case .options(_, let cs) = b.response { return Dictionary(uniqueKeysWithValues: cs.map { ($0.option.rawValue, $0.lane.values) }) }; return [:] }(), broken: broken, storage: kind,
                sourceWaypoints: try b.provenance.source.waypoints.positions(on: b.source.axis).map(\.value))
        }
        let descriptors = try graph.manual.keys.map { key in
            guard let control = schemas[key], let kind = storage[key.path] else { throw LibraryError.invalidCanonical }
            let waypoints: [ControlAxis: [Double]]
            switch control.waypoints {
            case .scalar(let points): waypoints = [.value: points.map(\.value)]
            case .xy(let x, let y): waypoints = [.x: x.map(\.value), .y: y.map(\.value)]
            }
            return LibraryMappingControlDescriptor(address: LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue),
                waypoints: waypoints, presentation: presentation[key], storage: kind)
        }.sorted { $0.address.key.orderBytes.lexicographicallyPrecedes($1.address.key.orderBytes) }
        return LibraryMappingSnapshot(generation: draft.info.generation, bindings: bindings.sorted { ($0.path.map(\.uuidString).joined() + $0.id.uuidString) < ($1.path.map(\.uuidString).joined() + $1.id.uuidString) }, controls: graph.manual.map { key, manual in
            LibraryMappingControl(address: LibraryControlAddress(path: key.path.map(\.rawValue), control: key.control.rawValue),
                manual: LibraryPosition(manual), effective: LibraryPosition(graph.effective.values[key]!),
                adjustments: Dictionary(uniqueKeysWithValues: memory.adjustments.filter { $0.key.controlKey == key }.map { ($0.key.axis, $0.value) }))
        }.sorted { $0.address.key.orderBytes.lexicographicallyPrecedes($1.address.key.orderBytes) }, descriptors: descriptors)
    }
    func librarySelectorPreview(_ handle: LibraryEditHandle, generation: UInt64, path: [UUID], source: UUID) throws -> LibrarySelectorPreview {
        let (context, draft) = try editContext(handle, generation: generation)
        let payload = try draft.payload.localPayload(at: path)
        let bindings = payload.block.bindings?.filter { $0.source.control == source } ?? []
        guard let selector = bindings.compactMap({ $0.response.selector }).first,
              let choiceControl = payload.block.controls.first(where: { $0.id == selector }), case .choice(let choice) = choiceControl.face,
              let value = try mappingGraph(draft, listening: positions(draft)).effective.values[OccurrenceControlKey(path: path.map(UseSiteID.init), control: selector)],
              case .scalar(let p) = value else { throw LibraryError.unsupportedEdit }
        return LibrarySelectorPreview(handle: context.handle, generation: generation, path: path, source: source, selector: selector.rawValue,
            option: choice.option(at: p).rawValue, fingerprint: try selectorFingerprint(draft))
    }
    func selectorFingerprint(_ draft: LibraryWorkingDraft) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try draft.payload.canonicalData
        data.append(try encoder.encode(positions(draft).saved)); return libraryDigest(data)
    }
    func libraryMappingEdit(_ handle: LibraryEditHandle, generation: UInt64, path: [UUID], command: LibraryMappingCommand) throws -> LibraryEditSnapshot {
        var (context, before) = try editContext(handle, generation: generation)
        if case .sameForAll(let preview) = command {
            guard preview.handle == context.handle, preview.generation == generation else { throw LibraryError.staleEdit }
        }
        before.positions = positions(before)
        var draft = try next(before)
        let compileContext = try owner().effectiveMetadata.context(profiles: owner().profiles, limits: owner().limits)
        if case .makeLocal(let childPath) = command {
            guard path.isEmpty else { throw LibraryError.unsupportedEdit }
            draft.payload = try draft.payload.localizing(childPath, context: compileContext)
        } else if case .makeLocalAndForward(let source, let target, let axis) = command {
            guard path.isEmpty, !target.path.isEmpty else { throw LibraryError.unsupportedEdit }
            draft.payload = try draft.payload.localizing(target.path, context: compileContext)
            var sourceID = source
            for depth in 0..<target.path.count {
                let parentPath = Array(target.path.prefix(depth)), site = target.path[depth]
                let childPath = Array(target.path.prefix(depth + 1))
                let destination: UUID
                if depth + 1 == target.path.count { destination = target.control }
                else {
                    destination = UUID()
                    draft.payload = try draft.payload.replacingLocal(at: childPath) { payload in
                        try self.mappingTransform(payload, path: childPath, command: .create(.slider(id: destination, title: "Forward", initial: 0.5, waypoints: [0, 0.5, 1])), draft: &draft)
                    }
                }
                let bindingID = UUID()
                let connect = LibraryMappingCommand.connect(id: bindingID, source: sourceID, target: .control(site: site, control: destination, axis: depth + 1 == target.path.count ? axis : .value))
                draft.payload = try draft.payload.replacingLocal(at: parentPath) { payload in
                    try self.mappingTransform(payload, path: parentPath, command: connect, draft: &draft)
                }
                let identity = try LibraryMappingLane(points: [LibraryLanePoint(0, 0), LibraryLanePoint(1, 1)], stretches: [.straight])
                draft.payload = try draft.payload.replacingLocal(at: parentPath) { payload in
                    try self.mappingTransform(payload, path: parentPath, command: .lane(binding: bindingID, option: nil, lane: identity), draft: &draft)
                }
                sourceID = LibraryMappingSource(destination)
            }
        } else {
            draft.payload = try draft.payload.replacingLocal(at: path) { payload in
                try self.mappingTransform(payload, path: path, command: command, draft: &draft)
            }
        }
        draft.info = LibraryDraftInfo(id: draft.info.id, generation: draft.info.generation, structural: true)
        // Removing the last incoming edge folds once; the remaining memory is still use-local.
        let prior = try mappingGraph(before, listening: before.positions)
        let schemas = try compileDraft(draft, listening: UseListeningState(positions: [:])).controlSchemas
        var values = draft.positions.values, adjustments = draft.positions.adjustments, dormant = draft.positions.dormant
        for key in prior.manual.keys where schemas[key] == nil {
            if let value = values.removeValue(forKey: key) {
                var saved = LibrarySavedPosition(id: key.control, value: value, path: key.path); saved.dormant = true; saved.retiredControl = try compileDraft(before, listening: UseListeningState(positions: [:])).controlSchemas[key]
                saved.adjustments = adjustments.filter { $0.key.controlKey == key }.map { MappingAxisDelta(axis: $0.key.axis, value: $0.value) }
                dormant.removeAll { $0.key == key }; dormant.append(saved)
            }
            adjustments.removeAll { $0.key.controlKey == key }
        }
        draft.positions = UseListeningState(values: values, adjustments: adjustments, dormant: dormant)
        let after = try mappingGraph(draft, listening: draft.positions)
        for key in prior.incoming.subtracting(after.incoming) {
            guard let effective = prior.effective.values[key.controlKey], after.manual[key.controlKey] != nil else { continue }
            values[key.controlKey] = try foldingMappingAxis(key.axis, manual: values[key.controlKey] ?? after.manual[key.controlKey]!, effective: effective)
            adjustments.removeAll { $0.key == key }
        }
        draft.positions = UseListeningState(values: values, adjustments: adjustments, dormant: dormant)
        try validateDraft(draft, admit: context.admit)
        guard let inverse = patch(before, draft) else { return try libraryInspectEdit(handle) }
        if context.gesture != nil { try stage(inverse.positions, from: draft, context: &context) }
        else { context.undo.append(try ordered(inverse)); context.redo.removeAll() }
        try trim(&context); try install(draft); libraryEdits[handle.id] = context
        return try libraryInspectEdit(handle)
    }
    func mappingTransform(_ payload: LibraryPayload, path: [UUID], command: LibraryMappingCommand, draft: inout LibraryWorkingDraft) throws -> LibraryPayload {
        var block = payload.block, presentation = payload.presentation
        func control(_ id: UUID) throws -> SoundControl {
            guard let c = block.controls.first(where: { $0.id.rawValue == id }) else { throw LibraryError.unknownTarget }; return c
        }
        func targetControl(_ target: LibraryMappingTarget) throws -> SoundControl? {
            guard case .control(let site, let id, _) = target else { return nil }
            if let site {
                guard let piece = block.pieces.first(where: {
                    switch $0 { case .block(let c): return c.site.rawValue == site; case .reference(let c): return c.site.rawValue == site; default: return false }
                }) else { throw LibraryError.unknownTarget }
                let child: SoundBlock
                switch piece {
                case .block(let c): child = c.content
                case .reference(let c): guard let p = try owner().metadata.revisions.first(where: { $0.definition.reference == c.definition })?.payload else { throw LibraryError.missingReference }; child = p.block
                default: throw LibraryError.unknownTarget
                }
                guard let c = child.controls.first(where: { $0.id.rawValue == id }) else { throw LibraryError.unknownTarget }; return c
            }
            return try control(id)
        }
        switch command {
        case .connectLegacy(let source, let part, let parameter):
            guard block.bindings == nil, let p = block.pieces.compactMap({ if case .part(let p) = $0, p.id.rawValue == part { return p }; return nil }).first,
                  let setting = p.settings.first(where: { $0.key.rawValue == parameter }) else { throw LibraryError.unsupportedEdit }
            let c = try control(source.control); _ = try c.position(on: source.axis)
            let lane = try MappingCurve(waypoints: [.init(position: .start, value: setting.position), .init(position: .end, value: setting.position)], shapes: [.straight])
            block = SoundBlock(pieces: block.pieces, controls: block.controls, mappings: block.mappings + [ParameterMapping(control: c.id, axis: source.axis, part: p.id, parameter: setting.key, curve: lane)])
        case .connectOptions(let id, let source, let target, let selector):
            let promoted = try payload.replacing(block: try block.promoted())
            let connected = try mappingTransform(promoted, path: path, command: .connect(id: id, source: source, target: target), draft: &draft)
            return try mappingTransform(connected, path: path, command: .differentForOptions(source: source.control, selector: selector), draft: &draft)
        case .create(let creation):
            let c: SoundControl, p: LibraryControl
            switch creation {
            case .slider(let id, let title, let initial, let points):
                try libraryName(title); let position = try Position(initial)
                c = SoundControl(id: ControlID(id), face: .slider, position: .scalar(position), waypoints: .scalar(try points.map(Position.init)))
                p = LibraryControl(id: id, title: title, face: .slider("", ""), placement: .primary, readout: nil)
            case .xy(let id, let title, let initialX, let initialY, let xPoints, let yPoints):
                try libraryName(title)
                c = SoundControl(id: ControlID(id), face: .xy,
                    position: .xy(x: try Position(initialX), y: try Position(initialY)),
                    waypoints: .xy(x: try xPoints.map(Position.init), y: try yPoints.map(Position.init)))
                p = LibraryControl(id: id, title: title, face: .xy, placement: .primary, readout: nil)
            case .choice(let id, let title, let options, let initial):
                try libraryName(title); let choice = try Choice(options: options.map { OptionID($0.id) })
                guard options.map(\.position) == choice.positions.map(\.value) else { throw LibraryError.invalidPresentation }
                c = SoundControl(id: ControlID(id), face: .choice(choice), position: .scalar(try choice.position(of: OptionID(initial))), waypoints: .scalar(choice.positions))
                p = LibraryControl(id: id, title: title, face: .choice(options), placement: .primary, readout: nil)
            }
            try c.validate(); guard !block.controls.contains(where: { $0.id == c.id }) else { throw SoundModelError.duplicateIdentity }
            block = block.replacing(controls: block.controls + [c]); presentation.append(p)
        case .settingBase(let id, let parameter, let normalized):
            let position = try Position(normalized)
            var found = false
            let pieces = block.pieces.map { piece -> BlockPiece in
                guard case .part(let part) = piece, part.id.rawValue == id else { return piece }
                let settings = part.settings.map { setting -> ParameterSetting in
                    guard setting.key.rawValue == parameter else { return setting }; found = true
                    return ParameterSetting(key: setting.key, position: position)
                }
                return .part(SoundPart(id: part.id, type: part.type, settings: settings))
            }
            guard found else { throw LibraryError.unknownTarget }
            block = block.replacing(pieces: pieces)
        case .removeControl(let id) where block.bindings == nil:
            _ = try control(id)
            block = SoundBlock(pieces: block.pieces, controls: block.controls.filter { $0.id.rawValue != id },
                mappings: block.mappings.filter { $0.control.rawValue != id })
            presentation.removeAll { $0.id == id }
        case .rename(let id, let title):
            try libraryName(title); _ = try control(id)
            presentation = presentation.map { $0.id == id ? $0.renamed(title) : $0 }
        default:
            if case .connect(_, let source, .setting) = command, block.bindings == nil {
                guard case .choice = try control(source.control).face else { throw LibraryError.unsupportedEdit }
            }
            block = try block.promoted()
            var bindings = block.bindings!
            switch command {
            case .connect(let id, let source, let target):
                guard !bindings.contains(where: { $0.id == id }) else { throw SoundModelError.duplicateIdentity }
                let sourceControl = try control(source.control); _ = try sourceControl.position(on: source.axis)
                let q: Position
                let targetC = try targetControl(target)
                switch target {
                case .setting(let part, let parameter):
                    guard let setting = block.pieces.compactMap({ if case .part(let p) = $0, p.id.rawValue == part { return p.settings.first { $0.key.rawValue == parameter } }; return nil }).first else { throw LibraryError.unknownTarget }
                    q = setting.position
                case .control(_, _, let axis): guard let c = targetC else { throw LibraryError.unknownTarget }; q = try c.position(on: axis)
                }
                let lane = try MappingCurve(waypoints: [.init(position: .start, value: q), .init(position: .end, value: q)], shapes: [.straight])
                let transfer = MappingTransfer.sampling(lane, source: sourceControl)
                var response = MappingResponse.lane(transfer), selectorC: SoundControl?
                let selectors = Set(bindings.filter { $0.source.control == source.control }.compactMap { $0.response.selector })
                guard selectors.count <= 1 else { throw LibraryError.unsupportedEdit }
                if let selector = block.selections.first(where: { $0.source.rawValue == source.control })?.selector ?? selectors.first {
                    let excluded: Bool
                    if case .control(nil, let id, _) = target { excluded = id == selector.rawValue } else { excluded = false }
                    if !excluded {
                        selectorC = try control(selector.rawValue)
                        guard case .choice(let choice) = selectorC!.face else { throw LibraryError.unsupportedEdit }
                        response = .options(selector: selector, cases: choice.options.map { MappingCase(option: $0, lane: transfer) })
                    }
                }
                bindings.append(MappingBinding(id: id, source: source, target: target, reference: q, response: response,
                    status: .active, provenance: MappingProvenance(source: sourceControl, selector: selectorC, target: targetC,
                        setting: block.pieces.compactMap { if case .part(let p) = $0, case .setting(let id, _) = target, p.id.rawValue == id { return p }; return nil }.first)))
            case .differentForOptions(let source, let selector):
                let sourceC = try control(source), selectorC = try control(selector)
                guard case .choice(let choice) = selectorC.face else { throw LibraryError.unsupportedEdit }
                if let existing = block.selections.first(where: { $0.source.rawValue == source }), existing.selector.rawValue != selector { throw LibraryError.unsupportedEdit }
                block = SoundBlock(pieces: block.pieces, controls: block.controls, storage: block.mappingStorage,
                    selections: block.selections.filter { $0.source.rawValue != source } + [MappingSelection(source: ControlID(source), selector: ControlID(selector))], optionControls: block.optionControls)
                for i in bindings.indices where bindings[i].source.control == source {
                    if let prior = bindings[i].response.selector, prior.rawValue != selector { throw LibraryError.unsupportedEdit }
                    if case .control(nil, let id, _) = bindings[i].target, id == selector { continue }
                    if case .lane(let lane) = bindings[i].response {
                        bindings[i].response = .options(selector: ControlID(selector), cases: choice.options.map { MappingCase(option: $0, lane: lane) })
                        bindings[i].provenance = MappingProvenance(source: sourceC, selector: selectorC, target: bindings[i].provenance.target, setting: bindings[i].provenance.setting)
                    }
                }
            case .sameForAll(let preview):
                guard preview.path == path, preview.generation + 1 == draft.info.generation,
                      preview.fingerprint == (try selectorFingerprint(LibraryWorkingDraft(owner: draft.owner, base: draft.base, payload: draft.payload, info: draft.info, positions: draft.positions))) else { throw LibraryError.staleEdit }
                block = SoundBlock(pieces: block.pieces, controls: block.controls, storage: block.mappingStorage,
                    selections: block.selections.filter { $0.source.rawValue != preview.source }, optionControls: block.optionControls)
                for i in bindings.indices where bindings[i].source.control == preview.source {
                    if case .options(let selector, let cases) = bindings[i].response {
                        guard selector.rawValue == preview.selector, let lane = cases.first(where: { $0.option.rawValue == preview.option })?.lane else { throw LibraryError.staleEdit }
                        bindings[i].response = .lane(lane)
                        bindings[i].provenance = MappingProvenance(source: bindings[i].provenance.source, selector: nil, target: bindings[i].provenance.target, setting: bindings[i].provenance.setting)
                    }
                }
            case .sourceValue(let id, let selectorOption, let sourceOption, let value):
                _ = try Position(value)
                try updateTransfer(&bindings, id: id, option: selectorOption) { transfer in
                    guard case .choices(var entries) = transfer, let index = entries.firstIndex(where: { $0.option == sourceOption }) else { throw LibraryError.unsupportedEdit }
                    entries[index] = LibrarySourceOptionValue(option: sourceOption, value: value)
                    return .choices(entries)
                }
            case .lane(let id, let option, let lane): try updateLane(&bindings, id: id, option: option) { _ in lane.curve }
            case .point(let id, let option, let position, let value): try updateLane(&bindings, id: id, option: option) { try $0.settingValue(Position(value), at: Position(position)) }
            case .insertPoint(let id, let option, let position):
                try updateLane(&bindings, id: id, option: option) { try $0.insertingWaypoint(at: Position(position)) }
                guard let binding = bindings.first(where: { $0.id == id }), let index = block.controls.firstIndex(where: { $0.id.rawValue == binding.source.control }) else { throw LibraryError.unknownTarget }
                let c = block.controls[index], p = try Position(position)
                var controls = block.controls
                let points: ControlWaypoints
                switch (c.waypoints, binding.source.axis) {
                case (.scalar(let old), .value): points = .scalar(Array(Set(old + [p])).sorted { $0.value < $1.value })
                case (.xy(let x, let y), .x): points = .xy(x: Array(Set(x + [p])).sorted { $0.value < $1.value }, y: y)
                case (.xy(let x, let y), .y): points = .xy(x: x, y: Array(Set(y + [p])).sorted { $0.value < $1.value })
                default: throw LibraryError.unsupportedEdit
                }
                guard case .choice = c.face else {
                    controls[index] = SoundControl(id: c.id, face: c.face, position: c.position, waypoints: points)
                    block = block.replacing(controls: controls)
                    for i in bindings.indices where bindings[i].source.control == c.id.rawValue {
                        bindings[i].provenance = MappingProvenance(source: controls[index], selector: bindings[i].provenance.selector, target: bindings[i].provenance.target, setting: bindings[i].provenance.setting)
                    }
                    break
                }
                throw LibraryError.unsupportedEdit
            case .stretch(let id, let option, let index, let shape, let jump):
                try updateLane(&bindings, id: id, option: option) { try $0.settingStretch(index: index, shape: StretchShape(rawValue: shape.rawValue)!, jump: Position(jump)) }
            case .removeBinding(let id):
                guard bindings.contains(where: { $0.id == id }) else { throw LibraryError.unknownTarget }; bindings.removeAll { $0.id == id }
            case .removeControl(let id):
                _ = try control(id)
                block = SoundBlock(pieces: block.pieces, controls: block.controls.filter { $0.id.rawValue != id }, storage: block.mappingStorage,
                    selections: block.selections.filter { $0.source.rawValue != id && $0.selector.rawValue != id }, optionControls: block.optionControls); presentation.removeAll { $0.id == id }
                for i in bindings.indices {
                    if bindings[i].source.control == id { bindings[i].status = .broken(.sourceRemoved) }
                    else if bindings[i].response.selector?.rawValue == id { bindings[i].status = .broken(.selectorRemoved) }
                    else if case .control(nil, let target, _) = bindings[i].target, target == id { bindings[i].status = .broken(.targetRemoved) }
                }
            case .repair(let id, let target):
                guard let i = bindings.firstIndex(where: { $0.id == id }) else { throw LibraryError.unknownTarget }
                let old = bindings[i], c = try control(old.source.control), targetC = try targetControl(target)
                let selectorC = try old.response.selector.map { try control($0.rawValue) }
                bindings[i] = MappingBinding(id: old.id, source: old.source, target: target, reference: old.reference,
                    response: old.response, status: .active, provenance: MappingProvenance(source: c, selector: selectorC, target: targetC,
                        setting: block.pieces.compactMap { if case .part(let p) = $0, case .setting(let id, _) = target, p.id.rawValue == id { return p }; return nil }.first))
            case .choiceOptions(let id, let options, let tables):
                let old = try control(id), choice = try Choice(options: options.map { OptionID($0.id) })
                guard case .choice(let oldChoice) = old.face, Set(oldChoice.options) == Set(choice.options), options.map(\.position) == choice.positions.map(\.value) else { throw LibraryError.unsupportedEdit }
                let manualKey = OccurrenceControlKey(path: path.map(UseSiteID.init), control: old.id)
                let manual = draft.positions.values[manualKey] ?? old.position
                guard case .scalar(let p) = manual else { throw LibraryError.unsupportedEdit }
                let selected = oldChoice.option(at: p)
                draft.positions = draft.positions.setting(manualKey, to: .scalar(try choice.position(of: selected)))
                let new = SoundControl(id: old.id, face: .choice(choice), position: .scalar(try choice.position(of: oldChoice.option(at: try old.position(on: .value)))), waypoints: .scalar(choice.positions))
                block = block.replacing(controls: block.controls.map { $0.id == old.id ? new : $0 })
                presentation = presentation.map { $0.id == id ? LibraryControl(id: id, title: $0.title, face: .choice(options), placement: $0.placement, readout: $0.readout) : $0 }
                for i in bindings.indices {
                    let b = bindings[i]
                    var response = b.response
                    if b.response.selector?.rawValue == id {
                        if let lanes = tables[b.id] {
                            guard Set(lanes.keys) == Set(options.map(\.id)) else { throw LibraryError.unsupportedEdit }
                            response = .options(selector: old.id, cases: options.map { MappingCase(option: OptionID($0.id), lane: .continuous(lanes[$0.id]!.curve)) })
                        }
                    }
                    bindings[i].response = response
                    bindings[i].provenance = MappingProvenance(source: b.source.control == id ? new : b.provenance.source,
                        selector: b.response.selector?.rawValue == id ? new : b.provenance.selector,
                        target: b.provenance.target?.id == old.id ? new : b.provenance.target, setting: b.provenance.setting)
                }
            default: throw LibraryError.unsupportedEdit
            }
            block = block.replacing(bindings: bindings)
        }
        try block.validateBetaSelectors()
        return try payload.replacing(block: block, presentation: presentation)
    }
    func updateTransfer(_ bindings: inout [MappingBinding], id: UUID, option: UUID?, transform: (MappingTransfer) throws -> MappingTransfer) throws {
        guard let i = bindings.firstIndex(where: { $0.id == id }) else { throw LibraryError.unknownTarget }
        switch (bindings[i].response, option) {
        case (.lane(let transfer), nil): bindings[i].response = .lane(try transform(transfer))
        case (.options(let selector, var cases), .some(let option)):
            guard let j = cases.firstIndex(where: { $0.option.rawValue == option }) else { throw LibraryError.unknownTarget }
            cases[j] = MappingCase(option: cases[j].option, lane: try transform(cases[j].lane))
            bindings[i].response = .options(selector: selector, cases: cases)
        default: throw LibraryError.unsupportedEdit
        }
    }
    func updateLane(_ bindings: inout [MappingBinding], id: UUID, option: UUID?, transform: (MappingCurve) throws -> MappingCurve) throws {
        try updateTransfer(&bindings, id: id, option: option) { transfer in
            guard case .continuous(let curve) = transfer else { throw LibraryError.unsupportedEdit }
            return .continuous(try transform(curve))
        }
    }

}

extension SoundLibrarySession {
    public func mappings(_ handle: LibraryEditHandle) async throws -> LibraryMappingSnapshot { try await document.libraryMappings(handle) }
    public func previewSameForAll(_ handle: LibraryEditHandle, expectedGeneration: UInt64, path: [UUID] = [], source: UUID) async throws -> LibrarySelectorPreview {
        try await document.librarySelectorPreview(handle, generation: expectedGeneration, path: path, source: source)
    }
}
extension SoundDocument {
    func mappingMove(_ draft: LibraryWorkingDraft, key: OccurrenceControlKey, value: ControlValue) throws -> UseListeningState {
        let current = positions(draft), graph = try mappingGraph(draft, listening: current)
        let sound = try compileDraft(draft, listening: current)
        guard let schema = sound.controlSchemas[key] else { throw LibraryError.unknownTarget }
        return try movedMappingValue(value, key: key, current: current, graph: graph, schema: schema)
    }
}

func movedMappingValue(_ value: ControlValue, key: OccurrenceControlKey, current: UseListeningState,
                       graph: MappingEvaluation, schema: SoundControl) throws -> UseListeningState {
    guard let manual = graph.manual[key] else { throw LibraryError.unknownTarget }
    let requested = try libraryValue(value, control: schema)
    var memory = current.setting(key, to: manual), adjustments = current.adjustments
    let axes: [ControlAxis] = schema.face == .xy ? [.x, .y] : [.value]
    for axis in axes {
        let address = MappingAxisKey(path: key.path, control: key.control, axis: axis)
        let requestedControl = SoundControl(id: schema.id, face: schema.face, position: requested, waypoints: schema.waypoints)
        if graph.incoming.contains(address) {
            let delta: Double
            let isChoice: Bool
            if case .choice = schema.face {
                guard let raw = graph.rawSums[address] else { throw LibraryError.invalidCanonical }
                delta = try requestedControl.position(on: axis).value - raw
                isChoice = true
            } else {
                let prior = adjustments.first { $0.key == address }?.value ?? 0
                delta = try requestedControl.position(on: axis).value - schema.position(on: axis).value + prior
                isChoice = false
            }
            adjustments.removeAll { $0.key == address }
            if delta != 0 || isChoice {
                adjustments.append(MappingAdjustment(key: address, value: delta))
            }
        } else { memory = memory.setting(key, to: requested) }
    }
    return UseListeningState(values: memory.values, adjustments: adjustments, dormant: current.dormant)
}

extension SoundBlock {
    func validateBetaSelectors() throws {
        let records = (bindings ?? []).filter { $0.status == .active }
        for source in Set(records.map { $0.source.control }) {
            let owned = records.filter { $0.source.control == source }
            let selectors = Set(owned.compactMap { $0.response.selector })
            guard selectors.count <= 1 else { throw LibraryError.unsupportedEdit }
            if let selector = selectors.first ?? selections.first(where: { $0.source.rawValue == source })?.selector {
                for binding in owned {
                    let excluded: Bool
                    if case .control(nil, let id, _) = binding.target { excluded = id == selector.rawValue } else { excluded = false }
                    guard excluded ? binding.response.selector == nil : binding.response.selector == selector else { throw LibraryError.unsupportedEdit }
                }
            }
        }
    }
}

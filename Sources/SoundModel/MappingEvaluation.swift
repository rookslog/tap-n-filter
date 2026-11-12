import Foundation

struct MappingAxisKey: Hashable, Sendable, Codable {
    let path: [UseSiteID]
    let control: ControlID
    let axis: ControlAxis
    var controlKey: OccurrenceControlKey { OccurrenceControlKey(path: path, control: control) }
}
struct MappingAdjustment: Equatable, Sendable, Codable {
    let key: MappingAxisKey
    let value: Double
}
struct MappingEvaluation {
    let effective: UseListeningState
    let manual: [OccurrenceControlKey: ControlValue]
    let bindings: [(path: [UseSiteID], binding: MappingBinding)]
    let contributions: [TargetAddress: [(UUID, Double)]]
    let incoming: Set<MappingAxisKey>
    let rawSums: [MappingAxisKey: Double]
    let optionControls: [LibraryOptionControl]
    let resolvedAdjustments: [MappingAdjustment]

    init(payload: LibraryPayload, root: RootUseID, context: LibraryCompileContext, listening: UseListeningState,
         preservingHands: [MappingAxisKey: OptionID] = [:]) throws {
        let rootProfile = payload.profile
        var controls: [OccurrenceControlKey: SoundControl] = [:]
        var defaults: [OccurrenceControlKey: ControlValue] = [:]
        var parts: [TargetAddress: Position] = [:]
        var profiles: [[UseSiteID]: String] = [:]
        var records: [(path: [UseSiteID], binding: MappingBinding)] = []
        var selected: [OccurrenceControlKey: ControlID] = [:]
        var relations: [(path: [UseSiteID], relation: OptionControl)] = []
        var count = 0
        func visit(_ block: SoundBlock, payload: LibraryPayload?, path: [UseSiteID], active: Set<DefinitionReference>) throws {
            try block.validateLocalOptionControls()
            relations += block.optionControls.map { (path, $0) }
            profiles[path] = payload?.profile ?? profiles[Array(path.dropLast())] ?? rootProfile
            count += 1
            guard path.count < (context.limits?.maximumDepth ?? 32), count <= (context.limits?.maximumOccurrences ?? 512) else { throw LibraryError.expansionExceeded }
            if let payload {
                try payload.validateCanonical()
                for item in payload.descendantDefaults {
                    let key = OccurrenceControlKey(path: path + item.path, control: item.id)
                    if defaults[key] == nil { defaults[key] = item.value }
                }
            }
            guard block.controls.count <= 256, (block.bindings?.count ?? 0) <= 2048 else { throw LibraryError.expansionExceeded }
            for control in block.controls {
                try control.validate()
                switch control.waypoints {
                case .scalar(let points): guard points.count <= 256 else { throw LibraryError.expansionExceeded }
                case .xy(let x, let y): guard x.count <= 256, y.count <= 256 else { throw LibraryError.expansionExceeded }
                }
                if case .choice(let choice) = control.face, choice.options.count > 64 { throw LibraryError.expansionExceeded }
                let key = OccurrenceControlKey(path: path, control: control.id)
                guard controls.updateValue(control, forKey: key) == nil else { throw SoundModelError.duplicateIdentity }
            }
            guard Set(block.selections.map(\.source)).count == block.selections.count else { throw LibraryError.invalidCanonical }
            for selection in block.selections {
                guard block.controls.contains(where: { $0.id == selection.source }),
                      let selector = block.controls.first(where: { $0.id == selection.selector }), case .choice = selector.face else { throw LibraryError.invalidCanonical }
                selected[OccurrenceControlKey(path: path, control: selection.source)] = selection.selector
            }
            if let bindings = block.bindings {
                guard Set(bindings.map(\.id)).count == bindings.count else { throw SoundModelError.duplicateIdentity }
                var pairs = Set<String>()
                for binding in bindings {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    let pair = String(decoding: try encoder.encode(binding.source), as: UTF8.self) + String(decoding: try encoder.encode(binding.target), as: UTF8.self)
                    guard pairs.insert(pair).inserted else { throw SoundModelError.duplicateIdentity }
                    records.append((path, binding))
                }
            }
            var sites = Set<UseSiteID>()
            for piece in block.pieces {
                switch piece {
                case .part(let part):
                    for setting in part.settings {
                        let address = TargetAddress(part: PartAddress(occurrence: Occurrence(root: root, path: path), part: part.id), parameter: setting.key)
                        guard parts.updateValue(setting.position, forKey: address) == nil else { throw SoundModelError.duplicateIdentity }
                    }
                case .reference(let child):
                    guard sites.insert(child.site).inserted else { throw SoundModelError.duplicateIdentity }
                    guard context.limits != nil else { throw SoundModelError.unsupportedReference }
                    guard let p = context.revisions[child.definition] else { throw LibraryError.missingReference }
                    guard !active.contains(child.definition) else { throw LibraryError.cyclicReference }
                    try visit(p.block, payload: p, path: path + [child.site], active: active.union([child.definition]))
                case .block(let child):
                    guard sites.insert(child.site).inserted else { throw SoundModelError.duplicateIdentity }
                    if let p = child.payload {
                        guard p.block == child.content, let original = child.original, context.revisions[original]?.profile == p.profile else { throw LibraryError.missingReference }
                    } else if child.original != nil { throw LibraryError.invalidCanonical }
                    try visit(child.content, payload: child.payload, path: path + [child.site], active: active)
                }
            }
        }
        try visit(payload.block, payload: payload, path: [], active: [])
        guard records.count <= 8192, controls.count <= 4096 else { throw LibraryError.expansionExceeded }
        var manual: [OccurrenceControlKey: ControlValue] = [:]
        for (key, control) in controls { manual[key] = try libraryValue(listening.values[key] ?? defaults[key] ?? control.position, control: control) }
        for (key, value) in listening.values { guard let control = controls[key], try libraryValue(value, control: control) == value else { throw LibraryError.invalidCanonical } }
        var adjustments: [MappingAxisKey: Double] = [:]
        for item in listening.adjustments {
            guard item.value.isFinite, adjustments.updateValue(item.value, forKey: item.key) == nil,
                  let c = controls[item.key.controlKey] else { throw LibraryError.invalidCanonical }
            _ = try c.position(on: item.key.axis)
        }
        var edges: [MappingAxisKey: [MappingAxisKey]] = [:]
        var incoming: [MappingAxisKey: [(path: [UseSiteID], binding: MappingBinding)]] = [:]
        func targetKey(_ target: LibraryMappingTarget, _ path: [UseSiteID]) -> MappingAxisKey? {
            if case .control(let site, let control, let axis) = target {
                return MappingAxisKey(path: path + (site.map { [UseSiteID($0)] } ?? []), control: ControlID(control), axis: axis)
            }
            return nil
        }
        for (path, binding) in records {
            let sourceKey = MappingAxisKey(path: path, control: ControlID(binding.source.control), axis: binding.source.axis)
            let active = binding.status == .active
            let source = active ? controls[sourceKey.controlKey] : binding.provenance.source
            guard let source, source.id == ControlID(binding.source.control), source.face == binding.provenance.source.face,
                  source.waypoints == binding.provenance.source.waypoints else { throw LibraryError.invalidCanonical }
            try binding.provenance.source.validate()
            _ = try source.position(on: sourceKey.axis)
            for transfer in binding.response.lanes { try transfer.validate(source: source, axis: sourceKey.axis) }
            var dependencies = [sourceKey]
            if case .options(let selector, let cases) = binding.response {
                let key = MappingAxisKey(path: path, control: selector, axis: .value)
                let control = active ? controls[key.controlKey] : binding.provenance.selector
                guard let control, case .choice(let choice) = control.face, choice.options.count <= 64,
                      binding.provenance.selector?.id == selector,
                      binding.provenance.selector?.face == control.face,
                      cases.count == choice.options.count, Set(cases.map(\.option)) == Set(choice.options) else { throw LibraryError.invalidCanonical }
                try control.validate()
                guard targetKey(binding.target, path)?.controlKey != key.controlKey else { throw LibraryError.mappingCycle }
                dependencies.append(key)
            } else if binding.provenance.selector != nil { throw LibraryError.invalidCanonical }
            switch binding.target {
            case .setting(let part, let parameter):
                _ = try ParameterKey(parameter)
                guard let original = binding.provenance.setting, original.id.rawValue == part,
                      original.settings.contains(where: { $0.key.rawValue == parameter }) else { throw LibraryError.invalidCanonical }
                guard let profile = profiles[path] else { throw LibraryError.invalidCanonical }
                let allowed = try context.profiles.catalog(profile) + context.profiles.authoredCatalog(profile)
                let keys = original.settings.map(\.key)
                guard Set(keys).count == keys.count, allowed.contains(where: { $0.type == original.type && Set($0.parameters) == Set(keys) }) else { throw LibraryError.invalidCanonical }
                let address = TargetAddress(part: PartAddress(occurrence: Occurrence(root: root, path: path), part: PartID(part)), parameter: try ParameterKey(parameter))
                guard !active || parts[address] != nil else { throw LibraryError.invalidCanonical }
            case .control:
                guard let key = targetKey(binding.target, path) else { throw LibraryError.invalidCanonical }
                let target = active ? controls[key.controlKey] : binding.provenance.target
                guard let target, target.id == key.control, target.face == binding.provenance.target?.face else { throw LibraryError.invalidCanonical }
                try target.validate(); _ = try target.position(on: key.axis)
                if active { incoming[key, default: []].append((path, binding)); edges[key, default: []] += dependencies }
            }
        }
        var parents: [OccurrenceControlKey: (key: MappingAxisKey, option: OptionID)] = [:]
        for (path, relation) in relations {
            let child = OccurrenceControlKey(path: path, control: relation.child)
            let parent = MappingAxisKey(path: path, control: relation.parentChoice, axis: .value)
            parents[child] = (parent, relation.option)
            edges[MappingAxisKey(path: path, control: relation.child, axis: .value), default: []].append(parent)
        }
        var visiting = Set<MappingAxisKey>(), evaluated: [MappingAxisKey: Position] = [:]
        var rawSums: [MappingAxisKey: Double] = [:]
        func effective(_ key: MappingAxisKey) throws -> Position {
            if let v = evaluated[key] { return v }
            guard visiting.insert(key).inserted else { throw LibraryError.mappingCycle }
            guard let c = controls[key.controlKey], let value = manual[key.controlKey] else { throw LibraryError.invalidCanonical }
            let manualControl = SoundControl(id: c.id, face: c.face, position: value, waypoints: c.waypoints)
            var sum = try manualControl.position(on: key.axis).value
            for dependency in edges[key] ?? [] { _ = try effective(dependency) }
            for item in (incoming[key] ?? []).sorted(by: { $0.binding.id.uuidString < $1.binding.id.uuidString }) {
                sum += try contribution(item.binding, at: item.path)
            }
            rawSums[key] = sum
            if let desired = preservingHands[key], case .choice(let choice) = c.face {
                adjustments[key] = try choice.position(of: desired).value - sum
            }
            sum += adjustments[key] ?? 0
            var result = try Position.evaluated(sum)
            if case .choice(let choice) = c.face { result = try choice.position(of: choice.option(at: result)) }
            evaluated[key] = result; visiting.remove(key); return result
        }
        func contribution(_ binding: MappingBinding, at path: [UseSiteID]) throws -> Double {
            let sourceKey = MappingAxisKey(path: path, control: ControlID(binding.source.control), axis: binding.source.axis)
            if let parent = parents[sourceKey.controlKey] {
                let selected = try effective(parent.key)
                guard let control = controls[parent.key.controlKey], case .choice(let choice) = control.face else { throw LibraryError.invalidCanonical }
                if choice.option(at: selected) != parent.option { return 0 }
            }
            let source = try effective(sourceKey)
            let lane: MappingTransfer
            switch binding.response {
            case .lane(let value): lane = value
            case .options(let selector, let cases):
                let p = try effective(MappingAxisKey(path: path, control: selector, axis: .value))
                guard let control = controls[OccurrenceControlKey(path: path, control: selector)], case .choice(let choice) = control.face,
                      let selected = cases.first(where: { $0.option == choice.option(at: p) }) else { throw LibraryError.invalidCanonical }
                lane = selected.lane
            }
            switch lane {
            case .continuous(let curve): return curve.value(at: source).value - binding.reference.value
            case .choices(let entries):
                guard let c = controls[OccurrenceControlKey(path: path, control: ControlID(binding.source.control))], case .choice(let choice) = c.face,
                      let value = entries.first(where: { $0.option == choice.option(at: source).rawValue })?.value else { throw LibraryError.invalidCanonical }
                return value - binding.reference.value
            }
        }
        var effectiveValues: [OccurrenceControlKey: ControlValue] = [:]
        for (key, c) in controls {
            switch c.face {
            case .xy: effectiveValues[key] = .xy(x: try effective(MappingAxisKey(path: key.path, control: key.control, axis: .x)), y: try effective(MappingAxisKey(path: key.path, control: key.control, axis: .y)))
            default: effectiveValues[key] = .scalar(try effective(MappingAxisKey(path: key.path, control: key.control, axis: .value)))
            }
        }
        var contributions: [TargetAddress: [(UUID, Double)]] = [:]
        for (path, binding) in records where binding.status == .active {
            if case .setting(let part, let parameter) = binding.target {
                let address = TargetAddress(part: PartAddress(occurrence: Occurrence(root: root, path: path), part: PartID(part)), parameter: try ParameterKey(parameter))
                contributions[address, default: []].append((binding.id, try contribution(binding, at: path)))
            }
        }
        self.optionControls = try relations.map { path, relation in
            let key = OccurrenceControlKey(path: path, control: relation.parentChoice)
            guard let control = controls[key], case .choice(let choice) = control.face, case .scalar(let value) = effectiveValues[key] else { throw LibraryError.invalidCanonical }
            return LibraryOptionControl(parent: LibraryControlAddress(path: path.map(\.rawValue), control: relation.parentChoice.rawValue),
                option: relation.option.rawValue, child: LibraryControlAddress(path: path.map(\.rawValue), control: relation.child.rawValue),
                isActive: choice.option(at: value) == relation.option)
        }
        self.effective = UseListeningState(values: effectiveValues)
        self.manual = manual; self.bindings = records; self.contributions = contributions; self.incoming = Set(incoming.keys)
        self.rawSums = rawSums
        self.resolvedAdjustments = adjustments.map { MappingAdjustment(key: $0.key, value: $0.value) }.sorted {
            let a = $0.key.controlKey.orderBytes + Data($0.key.axis.rawValue.utf8)
            let b = $1.key.controlKey.orderBytes + Data($1.key.axis.rawValue.utf8)
            return a.lexicographicallyPrecedes(b)
        }
    }
}

struct MappingAxisDelta: Equatable, Sendable, Codable {
    let axis: ControlAxis
    let value: Double
}
extension UseListeningState {
    init(saved: [LibrarySavedPosition]) throws {
        guard Set(saved.map(\.key)).count == saved.count else { throw LibraryError.invalidArchive }
        var values: [OccurrenceControlKey: ControlValue] = [:], adjustments: [MappingAdjustment] = [], dormant: [LibrarySavedPosition] = []
        for item in saved {
            guard Set(item.adjustments.map(\.axis)).count == item.adjustments.count,
                  item.adjustments.allSatisfy({ $0.value.isFinite }) else { throw LibraryError.invalidArchive }
            if item.dormant {
                guard let c = item.retiredControl, c.id == item.id, try libraryValue(item.value, control: c) == item.value else { throw LibraryError.invalidCanonical }
                for adjustment in item.adjustments { _ = try c.position(on: adjustment.axis) }
                dormant.append(item)
            } else if item.retiredControl != nil { throw LibraryError.invalidCanonical }
            else {
                values[item.key] = item.value
                adjustments += item.adjustments.map { MappingAdjustment(key: MappingAxisKey(path: item.path, control: item.id, axis: $0.axis), value: $0.value) }
            }
        }
        self.init(values: values, adjustments: adjustments, dormant: dormant)
    }
    var saved: [LibrarySavedPosition] {
        values.sorted { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) }.map { key, value in
            var saved = LibrarySavedPosition(id: key.control, value: value, path: key.path)
            saved.adjustments = adjustments.filter { $0.key.controlKey == key }.sorted { $0.key.axis.rawValue < $1.key.axis.rawValue }.map { MappingAxisDelta(axis: $0.key.axis, value: $0.value) }
            return saved
        } + dormant.sorted { $0.key.orderBytes.lexicographicallyPrecedes($1.key.orderBytes) }
    }
}

extension LibraryCompileContext {
    func needsMappingGraph(_ block: SoundBlock) -> Bool {
        var pending = [block], visited = Set<DefinitionReference>()
        while let current = pending.popLast() {
            if current.bindings != nil { return true }
            for piece in current.pieces {
                switch piece {
                case .part: break
                case .block(let child):
                    if child.payload != nil { return true }
                    pending.append(child.content)
                case .reference(let child):
                    if visited.insert(child.definition).inserted, let payload = revisions[child.definition] { pending.append(payload.block) }
                }
            }
        }
        return false
    }
}

func foldingMappingAxis(_ axis: ControlAxis, manual: ControlValue, effective: ControlValue) throws -> ControlValue {
    switch (axis, manual, effective) {
    case (.value, .scalar, .scalar): return effective
    case (.x, .xy(_, let y), .xy(let x, _)): return .xy(x: x, y: y)
    case (.y, .xy(let x, _), .xy(_, let y)): return .xy(x: x, y: y)
    default: throw SoundModelError.invalidControl
    }
}

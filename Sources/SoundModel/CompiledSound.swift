import Foundation

struct Occurrence: Hashable, Sendable {
    let root: RootUseID
    let path: [UseSiteID]
}

struct PartAddress: Hashable, Sendable {
    let occurrence: Occurrence
    let part: PartID
}

struct TargetAddress: Hashable, Sendable {
    let part: PartAddress
    let parameter: ParameterKey
}

struct PartDescriptor: Sendable {
    let type: String
    let parameters: [ParameterKey]
}

struct CompiledPart: Equatable, Sendable {
    let address: PartAddress
    let type: String
}

// Authoring-side data only. These heap-owning values must not cross the render mailbox.
// Native unit conversion belongs to the subsequent preparation adapter.
struct CompiledSound: Equatable, Sendable {
    let parts: [CompiledPart]
    let targets: [TargetAddress: Position]
    let unadjusted: [TargetAddress: Double]
    let bypassed: Set<PartAddress>
    let authoredParts: Set<PartAddress>
    let profiles: [PartAddress: String]
    let controlSchemas: [OccurrenceControlKey: SoundControl]
    let occurrences: [LibraryOccurrenceSummary]
    let optionControls: [LibraryOptionControl]

    init(block: SoundBlock, root: RootUseID, catalog: [PartDescriptor]) throws {
        try self.init(block: block, root: root, catalog: catalog, context: nil, payload: nil,
                      listening: UseListeningState(positions: [:]), reference: nil)
    }
    init(payload: LibraryPayload, root: RootUseID, reference: DefinitionReference?,
         context: LibraryCompileContext, listening: UseListeningState) throws {
        try self.init(block: payload.block, root: root, catalog: [], context: context, payload: payload,
                      listening: listening, reference: reference)
    }
    private init(block: SoundBlock, root: RootUseID, catalog: [PartDescriptor], context: LibraryCompileContext?,
                 payload: LibraryPayload?, listening: UseListeningState, reference: DefinitionReference?) throws {
        let graph = try payload.flatMap { payload in
            try context.flatMap { context in
                context.needsMappingGraph(payload.block) || !listening.adjustments.isEmpty
                    ? try MappingEvaluation(payload: payload, root: root, context: context, listening: listening) : nil
            }
        }
        let evaluatedListening = graph?.effective ?? listening
        var descriptors: [String: Set<ParameterKey>] = [:]
        for descriptor in catalog {
            guard !descriptor.type.isEmpty, descriptors[descriptor.type] == nil,
                Set(descriptor.parameters).count == descriptor.parameters.count
            else { throw SoundModelError.duplicateIdentity }
            descriptors[descriptor.type] = Set(descriptor.parameters)
        }
        var parts: [CompiledPart] = []
        var targets: [TargetAddress: Position] = [:]
        var raw: [TargetAddress: Double] = [:]
        var bypassed = Set<PartAddress>(), authoredParts = Set<PartAddress>()
        var partProfiles: [PartAddress: String] = [:]
        var schemas: [OccurrenceControlKey: SoundControl] = [:]
        var projections: [LibraryOccurrenceSummary] = []
        var defaultBindings: [(OccurrenceControlKey, ControlValue)] = []
        var visits = 0

        func lower(_ block: SoundBlock, path: [UseSiteID], profile: String?, payload: LibraryPayload?,
                   active: Set<DefinitionReference>, inherited: [OccurrenceControlKey: ControlValue],
                   reference: DefinitionReference?) throws {
            visits += 1
            if let limits = context?.limits {
                guard path.count < limits.maximumDepth, visits <= limits.maximumOccurrences else { throw LibraryError.expansionExceeded }
            }
            var defaults = inherited
            if let payload {
                try payload.validateCanonical()
                try context?.profiles.validatePresentation(payload)
                for item in payload.descendantDefaults {
                    let key = OccurrenceControlKey(path: path + item.path, control: item.id)
                    defaultBindings.append((key, item.value))
                    if defaults[key] == nil { defaults[key] = item.value }
                }
            }
            let localDescriptors: [String: Set<ParameterKey>]
            if let context, let profile {
                localDescriptors = Dictionary(uniqueKeysWithValues: try ((payload?.canonicalVersion ?? 0) >= 3 ? context.profiles.authoredCatalog(profile) : context.profiles.catalog(profile)).map { ($0.type, Set($0.parameters)) })
            } else { localDescriptors = descriptors }
            var controls: [ControlID: SoundControl] = [:]
            for original in block.controls {
                let key = OccurrenceControlKey(path: path, control: original.id)
                let value = try libraryValue(evaluatedListening.values[key] ?? defaults[key] ?? original.position, control: original)
                let control = SoundControl(id: original.id, face: original.face, position: value, waypoints: original.waypoints)
                try control.validate()
                if context != nil { schemas[key] = control }
                guard controls.updateValue(control, forKey: control.id) == nil else {
                    throw SoundModelError.duplicateIdentity
                }
            }
            if context != nil {
                projections.append(LibraryOccurrenceSummary(path: path.map(\.rawValue),
                    reference: reference.map { LibraryReference(definition: $0.id.rawValue, revision: $0.version.rawValue) },
                    controls: payload?.presentation ?? [],
                    positions: Dictionary(uniqueKeysWithValues: controls.values.map { ($0.id.rawValue, LibraryPosition($0.position)) })))
            }
            var localParts: [PartID: SoundPart] = [:]
            var sites = Set<UseSiteID>()
            for piece in block.pieces {
                switch piece {
                case .part(let part):
                    guard localParts.updateValue(part, forKey: part.id) == nil else {
                        throw SoundModelError.duplicateIdentity
                    }
                case .reference(let use):
                    guard sites.insert(use.site).inserted else { throw SoundModelError.duplicateIdentity }
                case .block(let use):
                    guard sites.insert(use.site).inserted else { throw SoundModelError.duplicateIdentity }
                }
            }
            struct MappingKey: Hashable {
                let control: ControlID
                let axis: ControlAxis
                let part: PartID
                let parameter: ParameterKey
            }
            var mappingKeys = Set<MappingKey>()
            for mapping in block.mappings {
                guard let control = controls[mapping.control], let part = localParts[mapping.part],
                    part.settings.contains(where: { $0.key == mapping.parameter })
                else { throw SoundModelError.invalidReference }
                _ = try control.position(on: mapping.axis)
                let waypoints = try control.waypoints.positions(on: mapping.axis)
                guard mapping.curve.waypoints.allSatisfy({ waypoints.contains($0.position) }) else {
                    throw SoundModelError.invalidWaypoints
                }
                let key = MappingKey(
                    control: mapping.control, axis: mapping.axis, part: mapping.part,
                    parameter: mapping.parameter)
                guard mappingKeys.insert(key).inserted else { throw SoundModelError.duplicateIdentity }
            }
            for piece in block.pieces {
                switch piece {
                case .reference(let use):
                    guard let context, context.limits != nil else { throw SoundModelError.unsupportedReference }
                    guard let child = context.revisions[use.definition] else { throw LibraryError.missingReference }
                    guard !active.contains(use.definition) else { throw LibraryError.cyclicReference }
                    try lower(child.block, path: path + [use.site], profile: child.profile, payload: child,
                              active: active.union([use.definition]), inherited: defaults, reference: use.definition)
                case .block(let use):
                    try lower(use.content, path: path + [use.site], profile: use.payload?.profile ?? profile, payload: use.payload,
                              active: active, inherited: defaults, reference: nil)
                case .part(let part):
                    guard let required = localDescriptors[part.type] else {
                        throw SoundModelError.invalidReference
                    }
                    let keys = part.settings.map(\.key)
                    guard Set(keys).count == keys.count else { throw SoundModelError.duplicateIdentity }
                    let retainedLegacyColour: Bool
                    if profile == LibraryProfiles.legacyEveryday, part.type == "deviceColour", let context {
                        retainedLegacyColour = try context.profiles.catalog(LibraryProfiles.legacyEveryday)
                            .contains { $0.type == part.type && Set($0.parameters) == Set(keys) }
                    } else { retainedLegacyColour = false }
                    guard Set(keys) == required || retainedLegacyColour else { throw SoundModelError.incompleteParameters }
                    let address = PartAddress(occurrence: Occurrence(root: root, path: path), part: part.id)
                    if let limits = context?.limits, parts.count >= limits.maximumParts { throw LibraryError.expansionExceeded }
                    parts.append(CompiledPart(address: address, type: part.type))
                    if (payload?.canonicalVersion ?? 0) >= 3 && !retainedLegacyColour { authoredParts.insert(address) }
                    if payload?.authored.bypassed.contains(part.id) == true { bypassed.insert(address) }
                    if let profile { partProfiles[address] = profile }
                    for setting in part.settings {
                        let base = setting.position.value
                        var value = base
                        for mapping in block.mappings
                        where mapping.part == part.id && mapping.parameter == setting.key {
                            guard let control = controls[mapping.control] else {
                                throw SoundModelError.invalidReference
                            }
                            value +=
                                mapping.curve.value(at: try control.position(on: mapping.axis)).value - base
                        }
                        let target = TargetAddress(part: address, parameter: setting.key)
                        for (_, delta) in (graph?.contributions[target] ?? []).sorted(by: { $0.0.uuidString < $1.0.uuidString }) { value += delta }
                        guard value.isFinite else { throw LibraryError.invalidCanonical }
                        raw[target] = value
                        targets[target] = try Position.evaluated(value + (payload?.authored.adjustment(part.id, setting.key) ?? 0))
                    }
                }
            }
        }
        try lower(block, path: [], profile: payload?.profile, payload: payload,
                  active: Set(reference.map { [$0] } ?? []), inherited: [:], reference: reference)
        for (key, value) in Array(listening.values) + defaultBindings {
            guard let control = schemas[key], try libraryValue(value, control: control) == value else { throw SoundModelError.invalidReference }
        }
        self.parts = parts; self.targets = targets
        unadjusted = raw; self.bypassed = bypassed; self.authoredParts = authoredParts
        profiles = partProfiles; controlSchemas = schemas; occurrences = projections
        optionControls = graph?.optionControls ?? []
    }
}

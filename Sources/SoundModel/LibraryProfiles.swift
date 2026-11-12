import Foundation

struct LibraryProfiles: Sendable {
    static let everyday = "tnf.native.everyday.v1"
    static let quickMenu = "tnf.native.quick-menu.v1"
    static let filters = "tnf.native.filters.v1"
    static let legacyEveryday = "tnf.native.everyday-legacy.v1"
    let recipes: BuiltinSounds
    let quickMenuRecipe: QuickMenuEveryday

    init() throws { recipes = try BuiltinSounds(); quickMenuRecipe = try QuickMenuEveryday() }

    func recipe(_ profile: String) throws -> any BuiltinSound {
        switch profile {
        case Self.everyday, Self.legacyEveryday: return recipes.all[0]
        case Self.filters: return recipes.all[1]
        case Self.quickMenu: return quickMenuRecipe
        default: throw LibraryError.unknownProfile(profile)
        }
    }
    func profile(for definition: BlockDefinition) throws -> String {
        let recipe = try recipes.recipe(id: definition.id)
        if definition.id == recipes.all[0].definition.id, definition.version == quickMenuRecipe.definition.version { return Self.quickMenu }
        // Only the explicitly archived shipped revisions are accepted, not a generic custom v1.
        let allowed: Set<UInt8> = recipe.kind == .everyday ? [2, 4, 5, 6] : [4, 5, 6]
        let prefix: UInt8 = recipe.kind == .everyday ? 1 : 2
        let known = allowed.contains { byte in
            definition.version.rawValue == UUID(uuid: (0x54,0x4e,0x46,prefix,0,0,0,0,0,0,0,0,0,0,0,byte))
        }
        guard known else { throw LibraryError.unsupportedLegacy }
        if recipe.kind == .filters { return Self.filters }
        return recipes.validationCatalog(for: definition).first(where: { $0.type == "deviceColour" })?
            .parameters.contains(where: { $0.rawValue == "factoryPreset" }) == false
            ? Self.legacyEveryday : Self.everyday
    }
    func catalog(_ profile: String) throws -> [PartDescriptor] {
        let recipe = try recipe(profile)
        let types = Set(recipe.definition.content.pieces.compactMap { piece -> String? in
            if case .part(let part) = piece { return part.type }; return nil
        })
        let catalog = profile == Self.quickMenu ? recipes.catalog + [PartDescriptor(type: "sizedReverb", parameters: try ["wetPercent", "roomPreset", "roomSize"].map(ParameterKey.init))] : recipes.catalog
        return catalog.filter { types.contains($0.type) }.map { descriptor in
            PartDescriptor(type: descriptor.type, parameters: descriptor.parameters.filter {
                profile != Self.legacyEveryday || descriptor.type != "deviceColour"
                    || $0.rawValue != "factoryPreset"
            })
        }
    }
    func presentation(for definition: BlockDefinition) throws -> [LibraryControl] {
        let source = definition.version == quickMenuRecipe.definition.version
            ? quickMenuRecipe.presentation : try recipes.recipe(id: definition.id).presentation
        return try definition.content.controls.map { control in
            guard let old = source.first(where: { $0.id == control.id.rawValue }) else {
                throw LibraryError.invalidPresentation
            }
            let face: LibraryFace
            switch (control.face, old.face) {
            case (.slider, .slider(let a, let b)): face = .slider(a, b)
            case (.xy, _): face = .xy
            case (.choice(let choice), .choice(let options)):
                face = .choice(try choice.options.map { id in
                    guard let option = options.first(where: { $0.id == id.rawValue }) else {
                        throw LibraryError.invalidPresentation
                    }
                    return LibraryOption(id: option.id, title: option.title,
                                         position: try choice.position(of: id).value)
                })
            default: throw LibraryError.invalidPresentation
            }
            var authoredFace = face
            var readout = old.readout
            if definition.id == recipes.all[1].definition.id,
               definition.version != recipes.all[1].definition.version,
               control.id == ControlID(UUID(uuid: (0x54,0x4e,0x46,2,0,0,0,0,0,0,0,0,0,0,0,17))) {
                _ = try BuiltinSounds.highCutMigration(from: definition, to: recipes.all[1].definition)
                if definition.version == DefinitionVersionID(UUID(uuid: (0x54,0x4e,0x46,2,0,0,0,0,0,0,0,0,0,0,0,4))) {
                    authoredFace = .slider("Off", "1 kHz")
                    readout = .frequency(20_000, 1000)
                }
            }
            return LibraryControl(id: old.id, title: old.title, face: authoredFace,
                                  placement: old.placement, readout: readout)
        }
    }
    func validate(_ payload: LibraryPayload, root: RootUseID) throws {
        try payload.validateCanonical()
        _ = try CompiledSound(block: payload.block, root: root, catalog: catalog(payload.profile))
        try validatePresentation(payload)
    }
    func validatePresentation(_ payload: LibraryPayload) throws {
        _ = try recipe(payload.profile)
        guard payload.presentation.map(\.id) == payload.block.controls.map({ $0.id.rawValue }) else {
            throw LibraryError.invalidPresentation
        }
        for (control, presentation) in zip(payload.block.controls, payload.presentation) {
            try libraryName(presentation.title)
            switch (control.face, presentation.face) {
            case (.slider, .slider), (.xy, .xy): break
            case (.choice(let choice), .choice(let options)):
                guard options.map(\.id) == choice.options.map(\.rawValue),
                    options.map(\.position) == choice.positions.map(\.value),
                    options.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                else { throw LibraryError.invalidPresentation }
            default: throw LibraryError.invalidPresentation
            }
            if let readout = presentation.readout {
                let a = try readout.value(at: 0), b = try readout.value(at: 1)
                guard a.isFinite, b.isFinite else { throw LibraryError.invalidPresentation }
                if case .frequency(let lower, let upper) = readout, lower <= 0 || upper <= 0 {
                    throw LibraryError.invalidPresentation
                }
            }
        }
    }
    func native(_ sound: CompiledSound, includingBypassed: Bool = false) throws -> [ListeningRenderPart] {
        guard sound.profiles.count == sound.parts.count else { throw LibraryError.unknownProfile("missing part provenance") }
        let all = try sound.parts.map { part in
            guard let profile = sound.profiles[part.address] else { throw LibraryError.unknownProfile("missing part provenance") }
            let converter = try recipe(profile)
            let parameters = try sound.targets.filter { $0.key.part == part.address }.map { target, position in
                let value: Double
                if sound.authoredParts.contains(part.address) {
                    guard let parameter = try descriptor(profile, type: part.type).parameters.first(where: { $0.key == target.parameter }) else { throw SoundModelError.invalidReference }
                    value = parameter.domain.value(position)
                } else { value = try converter.nativeValue(type: part.type, parameter: target.parameter, position: position) }
                return ListeningParameter(key: target.parameter.rawValue, value: value)
            }.sorted { $0.key < $1.key }
            return ListeningRenderPart(id: part.address.part.rawValue, path: part.address.occurrence.path.map(\.rawValue), type: part.type, parameters: parameters)
        }
        return zip(sound.parts, all).filter { includingBypassed || !sound.bypassed.contains($0.0.address) }.map(\.1)
    }
    func native(_ sound: CompiledSound, profile: String) throws -> [ListeningRenderPart] {
        let recipe = try recipe(profile)
        return try sound.parts.map { part in
            let parameters = try sound.targets.filter { $0.key.part == part.address }.map { key, value in
                ListeningParameter(key: key.parameter.rawValue,
                                   value: try recipe.nativeValue(type: part.type, parameter: key.parameter,
                                                                 position: value))
            }.sorted { $0.key < $1.key }
            return ListeningRenderPart(id: part.address.part.rawValue,
                path: part.address.occurrence.path.map(\.rawValue), type: part.type, parameters: parameters)
        }
    }
}

func libraryName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DocumentError.invalidName
    }
}

func libraryValue(_ value: ControlValue, control: SoundControl) throws -> ControlValue {
    try SoundControl(id: control.id, face: control.face, position: value,
                     waypoints: control.waypoints).validate()
    if case (.choice(let choice), .scalar(let p)) = (control.face, value) {
        return .scalar(try choice.position(of: choice.option(at: p)))
    }
    return value
}

extension SoundBlock {
    func withPositions(_ positions: [ControlID: ControlValue]) -> SoundBlock {
        replacing(controls: controls.map {
            SoundControl(id: $0.id, face: $0.face, position: positions[$0.id] ?? $0.position,
                         waypoints: $0.waypoints)
        })
    }
}

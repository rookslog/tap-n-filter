import Foundation

extension LibraryArchive {
    private enum CodingKeys: String, CodingKey {
        case format, schema, commit, provenance, revisions, heads, definitions, uses, assignments, enabled, workspaces
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sourceSchema = try c.decode(Int.self, forKey: .schema)
        if sourceSchema == 2 && decoder.userInfo[.libraryLegacy] as? Bool != true { throw LibraryError.migrationRequired }
        if sourceSchema == 3 && decoder.userInfo[.librarySchema3] as? Bool != true { throw LibraryError.migrationRequired }
        if sourceSchema == 4 && decoder.userInfo[.librarySchema4] as? Bool != true { throw LibraryError.migrationRequired }
        guard sourceSchema == 8 || sourceSchema == 7 || sourceSchema == 6 || sourceSchema == 5 || (sourceSchema == 4 && decoder.userInfo[.librarySchema4] as? Bool == true) || (sourceSchema == 3 && decoder.userInfo[.librarySchema3] as? Bool == true)
            || (sourceSchema == 2 && decoder.userInfo[.libraryLegacy] as? Bool == true) else { throw LibraryError.unsupportedFormat }
        try LibraryWireAdmission.check(decoder, legacy: sourceSchema == 2, metadata: sourceSchema >= 4, authoring: sourceSchema >= 5)
        format = try c.decode(String.self, forKey: .format)
        schema = try c.decode(Int.self, forKey: .schema)
        commit = try c.decode(UUID.self, forKey: .commit)
        provenance = try c.decode(String.self, forKey: .provenance)
        let decodedRevisions = try c.decode([LibraryRevision].self, forKey: .revisions)
        revisions = decodedRevisions
        if sourceSchema >= 4 { heads = try c.decode([LibraryDefinitionRecord].self, forKey: .definitions) }
        else {
            let old = try c.decode([LibraryPriorHead].self, forKey: .heads)
            heads = try old.map { head in
                guard let record = decodedRevisions.first(where: { $0.definition.id == head.definition && $0.definition.version == head.revision }) else { throw LibraryError.invalidArchive }
                return LibraryDefinitionRecord(record)
            }
        }
        uses = try c.decode([LibraryOwnedUse].self, forKey: .uses)
        assignments = try c.decode([PlaybackAssignment].self, forKey: .assignments)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        workspaces = sourceSchema >= 5 ? try c.decode([LibraryWorkspace].self, forKey: .workspaces) : []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format); try c.encode(schema, forKey: .schema)
        try c.encode(commit, forKey: .commit); try c.encode(provenance, forKey: .provenance)
        try c.encode(revisions, forKey: .revisions); try c.encode(heads, forKey: .definitions)
        try c.encode(uses, forKey: .uses); try c.encode(assignments, forKey: .assignments)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(workspaces, forKey: .workspaces)
    }
    static func initial(profiles: LibraryProfiles, builtins: LibraryBuiltinSet = .standard) throws -> Self {
        let recipes: [any BuiltinSound] = builtins == .quickMenu ? [profiles.quickMenuRecipe, profiles.recipes.all[1]] : profiles.recipes.all
        let revisions = try recipes.map { recipe in
            let payload = LibraryPayload(profile: try profiles.profile(for: recipe.definition),
                block: recipe.definition.content, presentation: try profiles.presentation(for: recipe.definition),
                canonicalVersion: recipe.definition.content.needsVersion5 ? 5 : 1)
            return try LibraryRevision(definition: recipe.definition, origin: "builtin",
                                   payload: payload, contentHash: payload.contentHash)
        }
        return Self(format: "tnf.library", schema: revisions.contains { $0.payload.requiresSchema8 } ? 8 : 5, commit: UUID(), provenance: "fresh",
            revisions: revisions,
            heads: revisions.map { LibraryDefinitionRecord($0) },
            uses: [], assignments: [], enabled: false)
    }

    static func migrating(_ data: Data, profiles: LibraryProfiles) throws -> Self {
        try LibraryWireAdmission.uniqueKeys(data)
        let old = try JSONDecoder().decode(LibraryV1Source.self, from: data).archive
        guard old.version == 1 else { throw LibraryError.unsupportedLegacy }
        guard Set(old.definitions.map(\.id)).count == old.definitions.count,
            Set(old.definitions.map(\.version)).count == old.definitions.count,
            Set(old.uses.map(\.id)).count == old.uses.count,
            Set(old.listening.map(\.root)).count == old.listening.count,
            Set(old.listening.map(\.root)) == Set(old.uses.map(\.id)),
            Set(old.assignments.map { $0.assignment.id }).count == old.assignments.count,
            Set(old.assignments.map { $0.assignment.app }).count == old.assignments.count
        else { throw LibraryError.invalidArchive }
        let revisions = try old.definitions.map { definition in
            let payload = LibraryPayload(profile: try profiles.profile(for: definition), block: definition.content,
                                         presentation: try profiles.presentation(for: definition))
            return try LibraryRevision(definition: definition, origin: "builtin", payload: payload,
                                   contentHash: payload.contentHash)
        }
        // v1 has shared recipe roots and per-assignment positions. Only active targets have known memory.
        var owned: [LibraryOwnedUse] = []
        var assignments: [PlaybackAssignment] = []
        for saved in old.assignments {
            guard let use = old.uses.first(where: { $0.id == saved.assignment.root }),
                revisions.contains(where: { $0.definition.reference == use.definition })
            else { throw LibraryError.invalidArchive }
            let root = RootUseID()
            owned.append(LibraryOwnedUse(target: saved.assignment.app,
                use: RootSoundUse(id: root, definition: use.definition, name: use.name), draft: nil,
                positions: saved.positions.map { LibrarySavedPosition(id: $0.control, value: $0.value) }))
            assignments.append(PlaybackAssignment(id: saved.assignment.id, root: root,
                app: saved.assignment.app, isEnabled: saved.assignment.isEnabled))
        }
        // Refuse unknown/dangling old state, even if it would not be copied into target memory.
        for use in old.uses {
            guard let revision = revisions.first(where: { $0.definition.reference == use.definition }),
                let memory = old.listening.first(where: { $0.root == use.id })
            else { throw LibraryError.invalidArchive }
            if case .own(let name) = use.name { try libraryName(name) }
            try validatePositions(memory.positions.map { LibrarySavedPosition(id: $0.control, value: $0.value) },
                                  in: revision.payload.block)
        }
        return Self(format: "tnf.library", schema: 5, commit: UUID(),
            provenance: "v1: retained exact archived revisions/native profiles; active memory only; no retune",
            revisions: revisions,
            heads: revisions.map { LibraryDefinitionRecord($0) },
            uses: owned, assignments: assignments, enabled: old.isEnabled ?? false)
    }

    static func migratingV2(_ data: Data, profiles: LibraryProfiles, limits: LibraryLimits) throws -> Self {
        guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
        try LibraryWireAdmission.uniqueKeys(data)
        let decoder = JSONDecoder(); decoder.userInfo[.libraryLegacy] = true
        decoder.userInfo[.libraryExpansion] = limits.expansion
        let old = try decoder.decode(Self.self, from: data)
        guard old.schema == 2 else { throw LibraryError.unsupportedFormat }
        guard old.heads.count == old.revisions.count,
              Set(old.revisions.map { $0.definition.id }).count == old.revisions.count else { throw LibraryError.unsupportedHistory }
        for revision in old.revisions { try profiles.validate(revision.payload, root: RootUseID()) }
        for use in old.uses { if let draft = use.draft { try profiles.validate(draft, root: use.use.id) } }
        // Preserve payload IDs/hashes, display spelling, memory and commit token. Only envelope/wire fields lift.
        let upgraded = Self(format: old.format, schema: 5, commit: old.commit, provenance: old.provenance,
            revisions: old.revisions, heads: old.heads, uses: old.uses, assignments: old.assignments, enabled: old.enabled)
        _ = try upgraded.validated(profiles: profiles, limits: limits)
        return upgraded
    }

    static func migratingV3(_ data: Data, profiles: LibraryProfiles, limits: LibraryLimits) throws -> Self {
        guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
        try LibraryWireAdmission.uniqueKeys(data)
        let decoder = JSONDecoder(); decoder.userInfo[.librarySchema3] = true
        decoder.userInfo[.libraryExpansion] = limits.expansion
        let old = try decoder.decode(Self.self, from: data)
        guard old.schema == 3 else { throw LibraryError.unsupportedFormat }
        let upgraded = Self(format: old.format, schema: 5, commit: old.commit, provenance: old.provenance,
            revisions: old.revisions, heads: old.heads, uses: old.uses, assignments: old.assignments, enabled: old.enabled)
        _ = try upgraded.validated(profiles: profiles, limits: limits)
        _ = try upgraded.encoded(limits: limits)
        return upgraded
    }

    static func migratingV4(_ data: Data, profiles: LibraryProfiles, limits: LibraryLimits) throws -> Self {
        guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
        try LibraryWireAdmission.uniqueKeys(data)
        let decoder = JSONDecoder(); decoder.userInfo[.librarySchema4] = true
        decoder.userInfo[.libraryExpansion] = limits.expansion
        let old = try decoder.decode(Self.self, from: data)
        guard old.schema == 4 else { throw LibraryError.unsupportedFormat }
        let upgraded = Self(format: old.format, schema: 5, commit: old.commit, provenance: old.provenance,
            revisions: old.revisions, heads: old.heads, uses: old.uses, assignments: old.assignments, enabled: old.enabled)
        _ = try upgraded.validated(profiles: profiles, limits: limits)
        _ = try upgraded.encoded(limits: limits)
        return upgraded
    }

    func validated(profiles: LibraryProfiles, limits: LibraryLimits) throws -> (DocumentContent, LibraryMetadata) {
        guard format == "tnf.library", (schema == 5 || schema == 6 || schema == 7 || schema == 8) else { throw LibraryError.unsupportedFormat }
        let v5 = revisions.contains { $0.payload.requiresSchema8 } || uses.contains { $0.draft?.requiresSchema8 == true } || workspaces.contains { $0.payload.requiresSchema8 }
        guard schema == 8 || !v5 else { throw LibraryError.unsupportedFormat }
        if schema == 5 {
            guard !revisions.contains(where: { $0.canonicalVersion == 4 }),
                  !uses.contains(where: { ($0.draft?.canonicalVersion ?? 0) == 4 || $0.positions.contains { $0.dormant || !$0.adjustments.isEmpty } }),
                  !workspaces.contains(where: { $0.payload.canonicalVersion == 4 || $0.positions.contains { $0.dormant || !$0.adjustments.isEmpty } }) else { throw LibraryError.unsupportedFormat }
        }
        let hasIntent = uses.contains { !($0.optionRemovals ?? []).isEmpty } || workspaces.contains { !($0.optionRemovals ?? []).isEmpty }
        guard schema == 8 || (schema == 7) == hasIntent else { throw LibraryError.unsupportedFormat }
        guard revisions.count <= limits.maximumRevisions else { throw LibraryError.limitExceeded }
        guard Set(revisions.map { $0.definition.version }).count == revisions.count,
              Set(heads.map(\.definition)).count == heads.count,
              Set(heads.map(\.definition)) == Set(revisions.map { $0.definition.id }) else { throw LibraryError.invalidArchive }
        let metadata = LibraryMetadata(revisions: revisions, heads: heads, owned: uses, provenance: provenance, workspaces: workspaces)
        let context = try metadata.context(profiles: profiles, limits: limits)
        for head in heads {
            _ = try metadata.head(head.definition); try libraryName(head.name)
            let records = revisions.filter { $0.definition.id == head.definition }
            let builtin = profiles.recipes.all.contains { $0.definition.id == head.definition }
            guard head.origin == (builtin ? "builtin" : "custom"), records.allSatisfy({ $0.origin == head.origin }) else { throw LibraryError.invalidArchive }
        }
        var content = DocumentContent()
        for record in revisions {
            try libraryName(record.definition.name)
            guard record.origin == "builtin" || record.origin == "custom" else { throw LibraryError.invalidArchive }
            _ = try CompiledSound(payload: record.payload, root: RootUseID(), reference: record.definition.reference,
                                  context: context, listening: UseListeningState(positions: [:]))
            guard record.contentHash == (try record.payload.contentHash) else { throw LibraryError.invalidArchive }
            content.definitions.append(record.definition)
        }
        guard Set(workspaces.map(\.definition)).count == workspaces.count else { throw LibraryError.invalidArchive }
        for workspace in workspaces {
            let head = try metadata.definition(workspace.definition)
            guard head.origin == "custom", workspace.base.id == workspace.definition,
                  let base = revisions.first(where: { $0.definition.reference == workspace.base }),
                  workspace.payload.profile == base.profile else { throw LibraryError.invalidArchive }
            try workspace.info.validate()
            try validateOptionRemovals(workspace.optionRemovals, base: workspace.base, payload: workspace.payload, context: context)
            guard workspace.info.structural || !workspace.payload.structurallyDiffers(from: base.payload) else { throw LibraryError.invalidArchive }
            let listening = try workspace.listening()
            _ = try CompiledSound(payload: workspace.payload, root: RootUseID(), reference: workspace.base,
                context: context, listening: listening)
        }
        var targets = Set<String>()
        for owned in uses {
            guard !content.uses.contains(where: { $0.id == owned.use.id }),
                  targets.insert(owned.target.bundleIdentifier + ":" + owned.use.definition.id.rawValue.uuidString).inserted,
                  let record = revisions.first(where: { $0.definition.reference == owned.use.definition }) else { throw LibraryError.invalidArchive }
            if case .own(let name) = owned.use.name { try libraryName(name) }
            if let info = owned.authoring {
                try info.validate()
                guard let draft = owned.draft, info.structural || !draft.structurallyDiffers(from: record.payload) else { throw LibraryError.invalidArchive }
            }
            if (owned.draft?.canonicalVersion ?? 0) >= 3 && owned.authoring == nil { throw LibraryError.invalidArchive }
            let payload = owned.draft ?? record.payload
            if owned.optionRemovals != nil && owned.authoring == nil { throw LibraryError.invalidArchive }
            try validateOptionRemovals(owned.optionRemovals, base: owned.use.definition, payload: payload, context: context)
            guard payload.profile == record.payload.profile,
                  Set(owned.positions.map(\.key)).count == owned.positions.count else { throw LibraryError.invalidArchive }
            let listening = try UseListeningState(saved: owned.positions)
            _ = try CompiledSound(payload: payload, root: owned.use.id, reference: owned.use.definition, context: context, listening: listening)
            content.uses.append(owned.use); content.listening[owned.use.id] = listening
        }
        for binding in assignments {
            guard !content.assignments.contains(where: { $0.id == binding.id || $0.app == binding.app }),
                  uses.contains(where: { $0.use.id == binding.root && $0.target == binding.app }) else { throw LibraryError.invalidArchive }
            content.assignments.append(binding)
        }
        return (content, metadata)
    }

    static func validatePositions(_ positions: [LibrarySavedPosition], in block: SoundBlock) throws {
        guard positions.allSatisfy({ $0.path.isEmpty }), Set(positions.map(\.key)).count == positions.count else { throw LibraryError.invalidArchive }
        for position in positions {
            guard let control = block.controls.first(where: { $0.id == position.id }),
                  try libraryValue(position.value, control: control) == position.value else { throw LibraryError.invalidArchive }
        }
    }

    func encoded(limits: LibraryLimits) throws -> Data {
        guard revisions.count <= limits.maximumRevisions else { throw LibraryError.limitExceeded }
        let data = try encoded()
        guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
        return data
    }

    // Live status must remain observable even when its next checkpoint cannot fit.
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

extension LibraryMetadata {
    func payload(root: RootUseID) throws -> LibraryPayload {
        guard let owned = owned.first(where: { $0.use.id == root }),
              let record = revisions.first(where: { $0.definition.reference == owned.use.definition })
        else { throw LibraryError.invalidArchive }
        return owned.draft ?? record.payload
    }
    func archive(content: DocumentContent, enabled: Bool, token: UUID) -> LibraryArchive {
        var records = owned
        for index in records.indices {
            records[index].use = content.uses.first(where: { $0.id == records[index].use.id }) ?? records[index].use
            records[index].positions = content.listening[records[index].use.id]?.saved ?? []
        }
        let v5 = revisions.contains { $0.payload.requiresSchema8 } || records.contains { $0.draft?.requiresSchema8 == true } || workspaces.contains { $0.payload.requiresSchema8 }
        let v4 = revisions.contains { $0.payload.canonicalVersion == 4 } || records.contains {
            ($0.draft?.canonicalVersion ?? 0) == 4 || $0.positions.contains { $0.dormant || !$0.adjustments.isEmpty }
        } || workspaces.contains { $0.payload.canonicalVersion == 4 || $0.positions.contains { $0.dormant || !$0.adjustments.isEmpty } }
        let hasIntent = records.contains { !($0.optionRemovals ?? []).isEmpty } || workspaces.contains { !($0.optionRemovals ?? []).isEmpty }
        return LibraryArchive(format: "tnf.library", schema: v5 ? 8 : (hasIntent ? 7 : (v4 ? 6 : 5)), commit: token, provenance: provenance,
            revisions: revisions, heads: heads, uses: records, assignments: content.assignments, enabled: enabled, workspaces: workspaces)
    }
}

private struct LibraryPriorHead: Decodable {
    let definition: DefinitionID
    let revision: DefinitionVersionID
}
extension CodingUserInfoKey {
    static let librarySchema4 = CodingUserInfoKey(rawValue: "tnf.library.schema4-migration")!
    static let librarySchema3 = CodingUserInfoKey(rawValue: "tnf.library.schema3-migration")!
}

private struct LibraryV1Source: Decodable {
    let archive: SoundSessionArchive
    init(from decoder: Decoder) throws {
        try LibraryWireAdmission.checkV1(decoder)
        archive = try SoundSessionArchive(from: decoder)
    }
}

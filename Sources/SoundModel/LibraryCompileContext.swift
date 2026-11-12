import Foundation

struct LibraryCompileContext: Sendable {
    let profiles: LibraryProfiles
    let revisions: [DefinitionReference: LibraryPayload]
    let limits: LibraryExpansionLimits?
}

extension LibraryMetadata {
    func context(profiles: LibraryProfiles, limits: LibraryLimits) throws -> LibraryCompileContext {
        var bank: [DefinitionReference: LibraryPayload] = [:]
        for revision in revisions {
            guard bank.updateValue(revision.payload, forKey: revision.definition.reference) == nil else { throw LibraryError.invalidArchive }
        }
        return LibraryCompileContext(profiles: profiles, revisions: bank, limits: limits.expansion)
    }
    func head(_ id: DefinitionID) throws -> LibraryRevision {
        guard let head = heads.first(where: { $0.definition == id }),
              let record = revisions.first(where: { $0.definition.id == id && $0.definition.version == head.revision }) else { throw LibraryError.unknownDefinition }
        return record
    }
    func definition(_ id: DefinitionID) throws -> LibraryDefinitionRecord {
        guard let record = heads.first(where: { $0.definition == id }) else { throw LibraryError.unknownDefinition }
        return record
    }
    func presentationDefinitions(_ frozen: [BlockDefinition]) -> [BlockDefinition] {
        frozen.map { old in
            guard let current = heads.first(where: { $0.definition == old.id }) else { return old }
            return BlockDefinition(id: old.id, version: old.version, name: current.name,
                content: old.content, inTheMenu: current.inTheMenu)
        }
    }
    func compile(root: RootUseID, listening: UseListeningState, profiles: LibraryProfiles, limits: LibraryLimits) throws -> CompiledSound {
        guard let use = owned.first(where: { $0.use.id == root }) else { throw LibraryError.unknownTarget }
        return try CompiledSound(payload: payload(root: root), root: root, reference: use.use.definition,
            context: context(profiles: profiles, limits: limits), listening: listening)
    }
}

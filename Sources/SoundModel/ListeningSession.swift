import Foundation

public struct ListeningOption: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let position: Double
}

public enum ListeningControlFace: Equatable, Sendable {
    case choice([ListeningOption])
    case slider(String, String)
}

public struct ListeningControl: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let face: ListeningControlFace
    public var placement: ListeningControlPlacement = .primary
    public var readout: ListeningReadout? = nil
}

public struct ListeningControlState: Equatable, Sendable {
    public let id: UUID
    public let position: Double
}

public struct ListeningParameter: Equatable, Sendable {
    public let key: String
    public let value: Double
}

// Control-rate, native-domain values. Never capture these heap-owning values in an audio callback.
public struct ListeningRenderPart: Equatable, Sendable {
    public let id: UUID
    public let path: [UUID]
    public let type: String
    public let parameters: [ListeningParameter]
}

public struct ListeningAssignment: Equatable, Sendable {
    public var block: BuiltinBlock = .everyday
    public var definitionID: UUID? = nil
    public let id: UUID
    public let bundleIdentifier: String
    public let isEnabled: Bool
    public let controls: [ListeningControlState]
    public let parts: [ListeningRenderPart]
}

public struct ListeningSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let isEnabled: Bool
    public let assignments: [ListeningAssignment]
    public var builtins: [ListeningBuiltin] = []
}

public struct ListeningCheckpoint: Sendable {
    public let snapshot: ListeningSnapshot
    public let data: Data
}

public enum ListeningSessionError: Error {
    case incompatibleBuiltin
    case noMenuBuiltin
}

/// A listening-only interface to the actual command owner. No method opens audio or writes files.
public struct ListeningSession: Sendable {
    public let controls: [ListeningControl]
    public let builtins: [ListeningBuiltin]
    private let recipes: BuiltinSounds
    private let document: SoundDocument

    public init(savedData: Data? = nil) async throws {
        let recipes = try BuiltinSounds()
        let document = try SoundDocument(
            catalog: recipes.catalog, historyLimit: UndoHistoryLimit(groups: 64))
        if let savedData {
            let saved = try JSONDecoder().decode(SoundSessionArchive.self, from: savedData)
            let current = try SoundSessionArchive(adopting: recipes, from: saved)
            _ = try await document.restoreSession(JSONEncoder().encode(current))
        } else {
            for recipe in recipes.all {
                _ = try await document.perform(.addDefinition(recipe.definition))
                _ = try await document.perform(
                    .instantiate(definition: recipe.definition.id, root: recipe.root))
            }
        }
        self.recipes = recipes
        self.document = document
        controls = recipes.all[0].presentation
        let state = await document.snapshot()
        builtins = try recipes.all.map { recipe in
            guard let definition = state.definitions.first(where: { $0.id == recipe.definition.id })
            else {
                throw ListeningSessionError.incompatibleBuiltin
            }
            return try recipes.summary(definition)
        }
    }

    public func snapshot() async throws -> ListeningSnapshot {
        try await document.listeningSnapshot(recipes: recipes)
    }
    public func savedData() async throws -> Data { try await document.sessionData() }
    public func checkpoint() async throws -> ListeningCheckpoint {
        try await document.listeningCheckpoint(recipes: recipes)
    }
    public func putEveryday(on bundleIdentifier: String) async throws {
        guard let everyday = builtins.first(where: { $0.kind == .everyday }) else {
            throw ListeningSessionError.incompatibleBuiltin
        }
        try await select(everyday.id, on: bundleIdentifier)
    }
    public func putDefault(on bundleIdentifier: String) async throws {
        guard let first = builtins.first(where: \.inTheMenu) else {
            throw ListeningSessionError.noMenuBuiltin
        }
        try await select(first.id, on: bundleIdentifier)
    }
    public func select(_ definition: UUID?, on bundleIdentifier: String) async throws {
        let root = try definition.map { try recipes.recipe(id: DefinitionID($0)).root }
        _ = try await document.selectBuiltin(on: ApplicationKey(bundleIdentifier), root: root)
    }
    public func takeOff(_ assignment: UUID) async throws {
        _ = try await document.perform(.unassign(AssignmentID(assignment)))
    }
    public func setEnabled(_ enabled: Bool) async throws {
        _ = try await document.perform(.setEnabled(enabled))
    }
    public func setEnabled(_ enabled: Bool, for assignment: UUID) async throws {
        _ = try await document.perform(.setAssignmentEnabled(AssignmentID(assignment), enabled))
    }
    public func move(_ control: UUID, on assignment: UUID, to position: Double) async throws {
        _ = try await document.perform(
            .moveAssignmentControl(
                assignment: AssignmentID(assignment), control: ControlID(control),
                value: .scalar(Position(position))))
    }
}

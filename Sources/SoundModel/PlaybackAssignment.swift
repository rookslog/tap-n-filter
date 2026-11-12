import Foundation

enum AssignmentKind {}
typealias AssignmentID = EntityID<AssignmentKind>

struct ApplicationKey: Hashable, Sendable, Codable {
    let bundleIdentifier: String

    init(_ bundleIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty,
            !bundleIdentifier.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else { throw DocumentError.invalidApplicationKey }
        self.bundleIdentifier = bundleIdentifier
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bundleIdentifier)
    }
}

struct PlaybackAssignment: Equatable, Sendable, Codable {
    let id: AssignmentID
    let root: RootUseID
    let app: ApplicationKey
    var isEnabled: Bool
}

struct SavedControlPosition: Codable {
    let control: ControlID
    let value: ControlValue
}

struct SavedRootListening: Codable {
    let root: RootUseID
    let positions: [SavedControlPosition]
}

struct SavedAssignment: Codable {
    let assignment: PlaybackAssignment
    let positions: [SavedControlPosition]
}

// Internal restart envelope, not a released block-exchange or library schema.
struct SoundSessionArchive: Codable {
    let version: Int
    let isEnabled: Bool?
    let definitions: [BlockDefinition]
    let uses: [RootSoundUse]
    let listening: [SavedRootListening]
    let assignments: [SavedAssignment]

    // Menu-only built-ins have no user-authored edits. Future library updates
    // must use the confirmation/version contract once the editor exists.
    init(adopting builtin: BlockDefinition, root: RootUseID, from saved: Self) throws {
        guard saved.version == 1 else { throw DocumentError.unsupportedSessionVersion(saved.version) }
        guard saved.definitions.count == 1, saved.definitions[0].id == builtin.id,
            saved.uses.count == 1, saved.uses[0].id == root,
            saved.uses[0].definition == saved.definitions[0].reference
        else {
            throw ListeningSessionError.incompatibleBuiltin
        }
        let oldControls = saved.definitions[0].content.controls
        guard Set(oldControls.map(\.id)).count == oldControls.count else {
            throw DocumentError.invalidSession
        }
        let controls = builtin.content.controls
        let highCut = try BuiltinSounds.highCutMigration(from: saved.definitions[0], to: builtin)
        for old in oldControls {
            guard let current = controls.first(where: { $0.id == old.id }) else { continue }
            switch (old.face, current.face) {
            case (.slider, .slider), (.xy, .xy), (.choice, .choice): break
            default: throw ListeningSessionError.incompatibleBuiltin
            }
        }
        func positions(_ values: [SavedControlPosition]) throws -> [SavedControlPosition] {
            var seen = Set<ControlID>()
            var result: [SavedControlPosition] = []
            for value in values {
                guard seen.insert(value.control).inserted,
                    let old = oldControls.first(where: { $0.id == value.control })
                else {
                    throw DocumentError.invalidSession
                }
                // Validate before dropping removed controls, so migration cannot hide corrupt state.
                let probe = SoundControl(
                    id: old.id, face: old.face, position: value.value, waypoints: old.waypoints)
                try probe.validate()
                if case (.choice(let choice), .scalar(let position)) = (old.face, value.value) {
                    guard try choice.position(of: choice.option(at: position)) == position else {
                        throw DocumentError.invalidSession
                    }
                }
                guard let current = controls.first(where: { $0.id == old.id }) else { continue }
                if case (.choice(let prior), .choice(let next), .scalar(let position)) =
                    (old.face, current.face, value.value)
                {
                    let option = prior.option(at: position)
                    guard next.options.contains(option) else { continue }
                    result.append(
                        SavedControlPosition(
                            control: old.id, value: .scalar(try next.position(of: option))))
                } else if let highCut, old.id == highCut.control, case .scalar(let position) = value.value {
                    result.append(SavedControlPosition(
                        control: old.id, value: .scalar(try Position(position.value * highCut.factor))))
                } else {
                    result.append(value)
                }
            }
            return result
        }
        version = saved.version
        isEnabled = saved.isEnabled
        definitions = [
            BlockDefinition(
                id: builtin.id, version: builtin.version, name: builtin.name,
                content: builtin.content, inTheMenu: saved.definitions[0].inTheMenu)
        ]
        uses = [RootSoundUse(id: root, definition: builtin.reference, name: saved.uses[0].name)]
        listening = try saved.listening.map {
            SavedRootListening(root: $0.root, positions: try positions($0.positions))
        }
        assignments = try saved.assignments.map {
            SavedAssignment(assignment: $0.assignment, positions: try positions($0.positions))
        }
    }

    init(snapshot: DocumentSnapshot) throws {
        guard snapshot.listening.values.allSatisfy({ $0.values.keys.allSatisfy { $0.path.isEmpty } }),
              snapshot.assignmentListening.values.allSatisfy({ $0.values.keys.allSatisfy { $0.path.isEmpty } }) else { throw DocumentError.legacyDescendantState }
        guard Set(snapshot.definitions.map(\.id)).count == snapshot.definitions.count else { throw DocumentError.legacyRevisionBank }
        func hasReference(_ block: SoundBlock) -> Bool {
            block.pieces.contains {
                switch $0 {
                case .reference: return true
                case .block(let child): return hasReference(child.content)
                case .part: return false
                }
            }
        }
        guard !snapshot.definitions.contains(where: { hasReference($0.content) }) else { throw DocumentError.legacyDescendantState }
        func positions(_ state: UseListeningState?) -> [SavedControlPosition] {
            (state?.positions ?? [:]).sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
                .map { SavedControlPosition(control: $0.key, value: $0.value) }
        }
        version = 1
        isEnabled = snapshot.isEnabled
        definitions = snapshot.definitions
        uses = snapshot.uses
        listening = uses.map {
            SavedRootListening(root: $0.id, positions: positions(snapshot.listening[$0.id]))
        }
        assignments = snapshot.assignments.map {
            SavedAssignment(assignment: $0, positions: positions(snapshot.assignmentListening[$0.id]))
        }
    }
}


extension SoundSessionArchive {
    private init(
        version: Int, isEnabled: Bool?, definitions: [BlockDefinition], uses: [RootSoundUse],
        listening: [SavedRootListening], assignments: [SavedAssignment]
    ) {
        self.version = version; self.isEnabled = isEnabled; self.definitions = definitions;
        self.uses = uses
        self.listening = listening; self.assignments = assignments
    }

    init(adopting recipes: BuiltinSounds, from saved: Self) throws {
        guard saved.version == 1 else {
            throw DocumentError.unsupportedSessionVersion(saved.version)
        }
        let ids = saved.definitions.map(\.id), versions = saved.definitions.map(\.version)
        guard Set(ids).count == ids.count, Set(versions).count == versions.count,
            ids.contains(recipes.all[0].definition.id), (1...recipes.all.count).contains(ids.count),
            ids.allSatisfy({ id in recipes.all.contains { $0.definition.id == id } }),
            saved.uses.count == ids.count, Set(saved.uses.map(\.id)).count == saved.uses.count,
            Set(saved.listening.map(\.root)) == Set(saved.uses.map(\.id)),
            saved.listening.count == saved.uses.count,
            Set(saved.assignments.map { $0.assignment.id }).count == saved.assignments.count,
            Set(saved.assignments.map { $0.assignment.app }).count == saved.assignments.count,
            saved.assignments.allSatisfy({ a in saved.uses.contains { $0.id == a.assignment.root } }
            )
        else { throw ListeningSessionError.incompatibleBuiltin }
        var definitions: [BlockDefinition] = [], uses: [RootSoundUse] = [],
            listening: [SavedRootListening] = []
        var assignments: [SavedAssignment] = []
        for recipe in recipes.all {
            if let old = saved.definitions.first(where: { $0.id == recipe.definition.id }) {
                guard !old.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let use = saved.uses.first(where: { $0.id == recipe.root }),
                    use.definition == old.reference
                else {
                    throw ListeningSessionError.incompatibleBuiltin
                }
                // Retuning cannot launder an invalid old graph into a valid shipped definition.
                _ = try CompiledSound(
                    block: old.content, root: recipe.root,
                    catalog: recipes.validationCatalog(for: old))
                let sub = Self(
                    version: saved.version, isEnabled: saved.isEnabled, definitions: [old],
                    uses: [use],
                    listening: saved.listening.filter { $0.root == recipe.root },
                    assignments: saved.assignments.filter { $0.assignment.root == recipe.root })
                let migrated = try Self(adopting: recipe.definition, root: recipe.root, from: sub)
                definitions += migrated.definitions; uses += migrated.uses;
                listening += migrated.listening
                assignments += migrated.assignments
            } else {
                guard !saved.uses.contains(where: { $0.id == recipe.root }) else {
                    throw DocumentError.invalidSession
                }
                definitions.append(recipe.definition)
                uses.append(
                    RootSoundUse(
                        id: recipe.root, definition: recipe.definition.reference, name: .library))
                listening.append(SavedRootListening(root: recipe.root, positions: []))
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.assignment.id, $0) })
        self.init(
            version: 1, isEnabled: saved.isEnabled, definitions: definitions, uses: uses,
            listening: listening,
            assignments: try saved.assignments.map {
                guard let a = byID[$0.assignment.id] else { throw DocumentError.invalidSession };
                return a
            })
    }
}

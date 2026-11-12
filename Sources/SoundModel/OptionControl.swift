import Foundation

enum OptionControl: Equatable, Sendable, Codable {
    case choiceOption(parentChoice: ControlID, option: OptionID, child: ControlID)

    var parentChoice: ControlID { switch self { case .choiceOption(let id, _, _): return id } }
    var option: OptionID { switch self { case .choiceOption(_, let id, _): return id } }
    var child: ControlID { switch self { case .choiceOption(_, _, let id): return id } }
    var order: String { parentChoice.rawValue.uuidString + option.rawValue.uuidString + child.rawValue.uuidString }
}

public struct LibraryOptionControl: Equatable, Sendable {
    public let parent: LibraryControlAddress
    public let option: UUID
    public let child: LibraryControlAddress
    public let isActive: Bool
}

public struct LibraryOptionGesture: Equatable, Sendable {
    public let parent: LibraryControlAddress
    public let option: UUID
    public init(parent: LibraryControlAddress, option: UUID) { self.parent = parent; self.option = option }
}

extension SoundBlock {
    var needsVersion5: Bool {
        !optionControls.isEmpty || pieces.contains {
            if case .block(let use) = $0 { return use.payload?.requiresSchema8 == true || use.content.needsVersion5 }
            return false
        }
    }
    func validateOptionControls() throws {
        try validateLocalOptionControls()
        for piece in pieces {
            if case .block(let use) = piece {
                if let payload = use.payload { try payload.validateCanonical() }
                else { try use.content.validateOptionControls() }
            }
        }
    }
    func validateLocalOptionControls() throws {
        guard optionControls.count <= 256 else { throw LibraryError.expansionExceeded }
        guard optionControls.isEmpty || bindings != nil,
              Set(optionControls.map(\.child)).count == optionControls.count else { throw LibraryError.invalidCanonical }
        for relation in optionControls {
            guard relation.parentChoice != relation.child,
                  let parent = controls.first(where: { $0.id == relation.parentChoice }), case .choice(let choice) = parent.face,
                  choice.options.contains(relation.option),
                  let child = controls.first(where: { $0.id == relation.child }), case .slider = child.face,
                  !optionControls.contains(where: { $0.child == relation.parentChoice }) else { throw LibraryError.invalidCanonical }
            let position = try child.position(on: .value)
            for binding in bindings ?? [] where binding.source.control == child.id.rawValue {
                for lane in binding.response.lanes {
                    guard case .continuous(let curve) = lane,
                          curve.value(at: position) == binding.reference else { throw LibraryError.invalidCanonical }
                }
            }
        }
    }
}

extension LibraryPayload {
    var requiresSchema8: Bool { canonicalVersion == 5 || block.needsVersion5 }
}

extension LibraryCompileContext {
    func containsOptionControls(_ block: SoundBlock) -> Bool {
        var pending = [block], visited = Set<DefinitionReference>()
        while let block = pending.popLast() {
            if !block.optionControls.isEmpty { return true }
            for piece in block.pieces {
                switch piece {
                case .part: break
                case .block(let use): pending.append(use.content)
                case .reference(let use):
                    if visited.insert(use.definition).inserted, let payload = revisions[use.definition] { pending.append(payload.block) }
                }
            }
        }
        return false
    }
}

extension SoundDocument {
    func libraryOptionControls(expected: LibraryBinding) throws -> [LibraryOptionControl] {
        guard matches(expected) else { throw LibraryError.staleBinding }
        let state = try owner(), root = RootUseID(expected.use)
        return try MappingEvaluation(payload: state.effectiveMetadata.payload(root: root), root: root,
            context: state.effectiveMetadata.context(profiles: state.profiles, limits: state.limits),
            listening: content.listening[root] ?? UseListeningState(positions: [:])).optionControls
    }
    func libraryMoveOptionChild(expected: LibraryBinding, key: OccurrenceControlKey,
                                gesture: LibraryOptionGesture, value: LibraryPosition) throws -> LibraryLiveMutation {
        guard matches(expected) else { return .superseded }
        let relations = try libraryOptionControls(expected: expected)
        guard relations.contains(where: { $0.child.key == key && $0.parent == gesture.parent && $0.option == gesture.option && $0.isActive }) else {
            return .superseded
        }
        return try libraryMove(expected: expected, key: key, value: value)
    }
}

extension SoundLibrarySession {
    public func optionControls(expected: LibraryBinding) async throws -> [LibraryOptionControl] {
        try await document.libraryOptionControls(expected: expected)
    }
    public func move(_ address: LibraryControlAddress, expected: LibraryBinding,
                     optionGesture: LibraryOptionGesture, to value: LibraryPosition) async throws -> LibraryLiveMutation {
        try await document.libraryMoveOptionChild(expected: expected, key: address.key, gesture: optionGesture, value: value)
    }
}

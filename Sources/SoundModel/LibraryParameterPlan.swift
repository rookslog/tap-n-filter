import Foundation

/// Invalidated by every semantic owner replacement, including changes outside the menu coordinator.
public final class LibraryParameterLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    public func ifValid<Result>(_ body: () throws -> Result) rethrows -> Result? {
        lock.lock(); defer { lock.unlock() }; guard valid else { return nil }; return try body()
    }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
}

final class WeakLibraryParameterLease {
    weak var lease: LibraryParameterLease?
    init(_ lease: LibraryParameterLease) { self.lease = lease }
}

public struct LibraryParameterPlan: Sendable, Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.address == rhs.address && lhs.option == rhs.option && lhs.template == rhs.template
    }

    public let identity: LibraryMenuIdentity
    public let address: LibraryControlAddress
    public let option: LibraryOptionGesture?
    public let lease: LibraryParameterLease
    private let template: LibraryMenuDelta
    private let adjustment: Double
    private let parts: [Part]
    private struct Term: Sendable {
        let curve: MappingCurve?
        let constant: Double
        func value(_ position: Position) -> Double { curve.map { $0.value(at: position).value - constant } ?? constant }
    }
    private struct Parameter: Sendable {
        let key: ParameterKey
        let base: Double
        let terms: [Term]
        let adjustment: Double
        let native: @Sendable (Position) throws -> Double
    }
    private struct Part: Sendable {
        let id: UUID
        let type: String
        let parameters: [Parameter]
    }

    public func evaluate(_ value: LibraryPosition) throws -> LibraryMenuDelta? {
        guard lease.isValid else { return nil }
        guard case .scalar(let input) = value else { throw LibraryError.unsupportedEdit }
        let requested = try Position(input)
        let effective = try Position.evaluated(requested.value + adjustment)
        let native = try parts.map { part in
            ListeningRenderPart(id: part.id, path: [], type: part.type, parameters: try part.parameters.map { parameter in
                var sum = parameter.base
                for term in parameter.terms { sum += term.value(effective) }
                let position = try Position.evaluated(sum + parameter.adjustment)
                return ListeningParameter(key: parameter.key.rawValue, value: try parameter.native(position))
            })
        }
        var result = template
        result.transientPosition = address
        result = result.replacingParameterPosition(address, with: .scalar(effective.value), parts: native)
        return lease.isValid ? result : nil
    }

    init(identity: LibraryMenuIdentity, address: LibraryControlAddress, option: LibraryOptionGesture?,
         lease: LibraryParameterLease, template: LibraryMenuDelta, payload: LibraryPayload,
         sound: CompiledSound, graph: MappingEvaluation, profiles: LibraryProfiles) throws {
        guard address.path.isEmpty, sound.parts.allSatisfy({ $0.address.occurrence.path.isEmpty }),
              graph.incoming.isEmpty, sound.directSliderControls?.contains(address) == true else { throw LibraryError.unsupportedEdit }
        self.identity = identity; self.address = address; self.option = option; self.lease = lease; self.template = template
        let key = address.key
        adjustment = graph.resolvedAdjustments.first { $0.key.controlKey == key }?.value ?? 0
        let allParts = payload.block.pieces.compactMap { piece -> SoundPart? in if case .part(let p) = piece { return p }; return nil }
        let records = graph.bindings.filter { $0.binding.status == .active }.sorted { $0.binding.id.uuidString < $1.binding.id.uuidString }
        parts = try sound.parts.filter { !sound.bypassed.contains($0.address) }.map { compiled in
            guard let authored = allParts.first(where: { $0.id == compiled.address.part }),
                  let profile = sound.profiles[compiled.address] else { throw LibraryError.invalidCanonical }
            let converter = try profiles.recipe(profile)
            let domains = try profiles.descriptor(profile, type: compiled.type).parameters
            let parameters = try authored.settings.sorted { $0.key.rawValue < $1.key.rawValue }.map { setting -> Parameter in
                let target = TargetAddress(part: compiled.address, parameter: setting.key)
                var terms: [Term] = []
                for mapping in payload.block.mappings where mapping.part == authored.id && mapping.parameter == setting.key {
                    if mapping.control.rawValue == address.control {
                        terms.append(Term(curve: mapping.curve, constant: setting.position.value))
                    } else {
                        guard let control = sound.controlSchemas[OccurrenceControlKey(path: [], control: mapping.control)] else { throw LibraryError.invalidCanonical }
                        terms.append(Term(curve: nil, constant: mapping.curve.value(at: try control.position(on: mapping.axis)).value - setting.position.value))
                    }
                }
                for record in records {
                    let binding = record.binding
                    guard case .setting(let part, let parameter) = binding.target,
                          part == authored.id.rawValue, parameter == setting.key.rawValue else { continue }
                    if binding.source.control == address.control {
                        let active = !sound.optionControls.contains { $0.child == address && !$0.isActive }
                        guard active else { terms.append(Term(curve: nil, constant: 0)); continue }
                        let lane: MappingTransfer
                        switch binding.response {
                        case .lane(let value): lane = value
                        case .options(let selector, let options):
                            guard let control = sound.controlSchemas[OccurrenceControlKey(path: [], control: selector)],
                                  case .choice(let choice) = control.face else { throw LibraryError.invalidCanonical }
                            let selectedOption = choice.option(at: try control.position(on: .value))
                            guard let selected = options.first(where: { $0.option == selectedOption }) else { throw LibraryError.invalidCanonical }
                            lane = selected.lane
                        }
                        guard case .continuous(let curve) = lane else { throw LibraryError.unsupportedEdit }
                        terms.append(Term(curve: curve, constant: binding.reference.value))
                    } else {
                        guard let value = graph.contributions[target]?.first(where: { $0.0 == binding.id })?.1 else { throw LibraryError.invalidCanonical }
                        terms.append(Term(curve: nil, constant: value))
                    }
                }
                let convert: @Sendable (Position) throws -> Double
                if sound.authoredParts.contains(compiled.address) {
                    guard let domain = domains.first(where: { $0.key == setting.key })?.domain else { throw LibraryError.invalidCanonical }
                    convert = { domain.value($0) }
                } else { convert = { try converter.nativeValue(type: compiled.type, parameter: setting.key, position: $0) } }
                return Parameter(key: setting.key, base: setting.position.value, terms: terms,
                    adjustment: payload.authored.adjustment(authored.id, setting.key), native: convert)
            }
            return Part(id: authored.id.rawValue, type: authored.type, parameters: parameters)
        }
    }
}

extension LibraryMenuDelta {
    fileprivate func replacingParameterPosition(_ address: LibraryControlAddress, with value: LibraryPosition,
                                                parts: [ListeningRenderPart]) -> Self {
        var occurrences = occurrences
        for index in occurrences.indices where occurrences[index].path == address.path {
            let old = occurrences[index]; var positions = old.positions; positions[address.control] = value
            occurrences[index] = LibraryOccurrenceSummary(path: old.path, reference: old.reference, controls: old.controls, positions: positions)
        }
        var result = Self(identity: identity, liveGeneration: liveGeneration, baseGeneration: baseGeneration,
            stateRevision: stateRevision, baseStateRevision: baseStateRevision, live: live, outcome: .noChange,
            occurrences: occurrences, optionControls: optionControls, directSliderControls: directSliderControls,
            assignment: ListeningRenderAssignment(id: assignment.id, bundleIdentifier: assignment.bundleIdentifier,
                isEnabled: assignment.isEnabled, parts: parts))
        result.transientPosition = address
        return result
    }
}

extension SoundDocument {
    func libraryParameterPlans(for snapshot: LibraryMenuState) throws -> [LibraryParameterPlan] {
        guard !snapshot.writing, !snapshot.unresolved else { return [] }
        let state = try owner(), metadata = state.effectiveMetadata
        var plans: [LibraryParameterPlan] = []
        for assignment in snapshot.assignments {
            let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
            guard let identity = snapshot.identity(for: binding),
                  let owned = metadata.owned.first(where: { $0.use.id.rawValue == assignment.use }),
                  owned.draft == nil, state.drafts[.use(owned.use.id)] == nil,
                  let record = metadata.revisions.first(where: { $0.definition.reference == owned.use.definition }), record.origin == "builtin",
                  record.definition.reference == state.profiles.quickMenuRecipe.definition.reference || record.definition.reference == state.profiles.recipes.filters.definition.reference else { continue }
            let listening = content.listening[owned.use.id] ?? UseListeningState(positions: [:])
            let sound = try metadata.compile(root: owned.use.id, listening: listening, profiles: state.profiles, limits: state.limits)
            let graph = try MappingEvaluation(payload: record.payload, root: owned.use.id,
                context: metadata.context(profiles: state.profiles, limits: state.limits), listening: listening)
            guard graph.incoming.isEmpty else { continue }
            let template = LibraryMenuDelta(identity: identity, liveGeneration: snapshot.liveGeneration, baseGeneration: snapshot.liveGeneration,
                stateRevision: snapshot.stateRevision, baseStateRevision: snapshot.stateRevision, live: snapshot.live, outcome: .noChange,
                occurrences: sound.occurrences, optionControls: sound.optionControls, directSliderControls: sound.directSliderControls,
                assignment: ListeningRenderAssignment(id: assignment.id, bundleIdentifier: assignment.target,
                    isEnabled: assignment.isEnabled, parts: assignment.parts))
            let lease = LibraryParameterLease(); parameterLeases.removeAll { $0.lease == nil }; parameterLeases.append(WeakLibraryParameterLease(lease))
            for address in sound.directSliderControls ?? [] {
                let relations = sound.optionControls.filter { $0.child == address }
                guard relations.isEmpty || relations.contains(where: \.isActive) else { continue }
                let option = relations.first(where: \.isActive).map { LibraryOptionGesture(parent: $0.parent, option: $0.option) }
                plans.append(try LibraryParameterPlan(identity: identity, address: address, option: option,
                    lease: lease, template: template, payload: record.payload, sound: sound, graph: graph, profiles: state.profiles))
            }
        }
        return plans
    }
}

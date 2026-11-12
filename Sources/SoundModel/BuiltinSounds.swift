import Foundation

public enum BuiltinBlock: String, CaseIterable, Sendable {
    case everyday, filters
}

public enum ListeningControlPlacement: Equatable, Sendable, Codable { case primary, more }

public enum ListeningReadout: Equatable, Sendable, Codable {
    case frequency(Double, Double)
    case wetPercent(Double)
    case decibels(Double, Double)
    case positionPercent

    public func value(at position: Double) throws -> Double {
        let p = try Position(position).value
        switch self {
        case .frequency(let a, let b): return a * pow(b / a, p)
        case .wetPercent(let maximum): return maximum * p
        case .decibels(let a, let b): return a + (b - a) * p
        case .positionPercent: return 100 * p
        }
    }

    public func text(at position: Double) throws -> String {
        let value = try value(at: position)
        switch self {
        case .frequency:
            if position == 0 { return "Off" }
            return value >= 1000
                ? String(format: "%.1f kHz", value / 1000) : "\(Int(value.rounded())) Hz"
        case .wetPercent:
            return position == 0 ? "Off" : "\(Int(value.rounded()))%"
        case .positionPercent: return "\(Int(value.rounded()))%"
        case .decibels:
            let rounded = Int(value.rounded())
            return rounded == 0 ? "0 dB" : rounded > 0 ? "+\(rounded) dB" : "−\(-rounded) dB"
        }
    }
}

public struct ListeningBuiltin: Equatable, Sendable {
    public let kind: BuiltinBlock
    public let id: UUID
    public let title: String
    public let inTheMenu: Bool
    public let controls: [ListeningControl]
}

protocol BuiltinSound: Sendable {
    var kind: BuiltinBlock { get }
    var root: RootUseID { get }
    var definition: BlockDefinition { get }
    var presentation: [ListeningControl] { get }
    func nativeValue(type: String, parameter: ParameterKey, position: Position) throws -> Double
}

enum BuiltinMigrationError: Error {
    case unsupportedHighCutRange
}

// Fixed shipped set, not an extension/plugin registry.
struct BuiltinSounds: Sendable {
    let everyday: Everyday
    let filters: Filters
    let all: [any BuiltinSound]
    let catalog: [PartDescriptor]
    init() throws {
        everyday = try Everyday()
        filters = try Filters()
        all = [everyday, filters]
        catalog = everyday.catalog
    }

    static func highCutMigration(from old: BlockDefinition, to current: BlockDefinition) throws
        -> (control: ControlID, factor: Double)?
    {
        func id<Kind>(_ byte: UInt8) -> EntityID<Kind> {
            EntityID(UUID(uuid: (0x54, 0x4E, 0x46, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
        }
        guard current.id == id(1) else { return nil }
        let controlID: ControlID = id(17)
        let partID: PartID = id(32)
        let cutoff = try ParameterKey("lowPassHz")
        let endpoint: Double
        switch old.version {
        case id(4): endpoint = 1000
        case id(5), id(6): endpoint = 100
        default: throw BuiltinMigrationError.unsupportedHighCutRange
        }
        let frequency = ParameterDomain.logarithmic(20, 20_000)
        let expected = try MappingCurve(waypoints: [
            Waypoint(position: .start, value: frequency.position(20_000)),
            Waypoint(position: .end, value: frequency.position(endpoint)),
        ], shapes: [.straight])
        let mappings = old.content.mappings.filter { $0.part == partID && $0.parameter == cutoff }
        let parts = old.content.pieces.compactMap { piece -> SoundPart? in
            if case .part(let part) = piece, part.id == partID { return part }
            return nil
        }
        guard current.version == id(6), let control = old.content.controls.first(where: { $0.id == controlID }),
            case .slider = control.face, control.position == .scalar(.start),
            control.waypoints == .scalar([.start, .end]),
            parts.count == 1, parts[0].type == "deviceEQ",
            parts[0].settings.first(where: { $0.key == cutoff })?.position == .end,
            mappings.count == 1, mappings[0].control == controlID, mappings[0].axis == .value,
            mappings[0].curve == expected
        else { throw BuiltinMigrationError.unsupportedHighCutRange }
        return (controlID, log(endpoint / 20_000) / log(100.0 / 20_000))
    }
    func recipe(id: DefinitionID) throws -> any BuiltinSound {
        guard let value = all.first(where: { $0.definition.id == id }) else {
            throw DocumentError.unknownDefinition(id)
        }
        return value
    }
    // The retained v1 Everyday fixture predates its explicit distortion preset setting.
    // Validate that version against its own known parameter schema, not today's schema.
    func validationCatalog(for definition: BlockDefinition) -> [PartDescriptor] {
        let legacy = DefinitionVersionID(
            UUID(uuid: (0x54, 0x4E, 0x46, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)))
        guard definition.id == all[0].definition.id, definition.version == legacy else {
            return catalog
        }
        return catalog.map { descriptor in
            PartDescriptor(
                type: descriptor.type,
                parameters: descriptor.parameters.filter {
                    descriptor.type != "deviceColour" || $0.rawValue != "factoryPreset"
                })
        }
    }
    func summary(_ definition: BlockDefinition) throws -> ListeningBuiltin {
        let recipe = try recipe(id: definition.id)
        return ListeningBuiltin(
            kind: recipe.kind, id: definition.id.rawValue,
            title: definition.name, inTheMenu: definition.inTheMenu, controls: recipe.presentation)
    }
}

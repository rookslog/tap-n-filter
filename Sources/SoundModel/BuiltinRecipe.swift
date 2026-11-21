import Foundation
import EffectCatalog

struct BuiltinRecipe {
    let namespace: UInt8
    var controls: [SoundControl] = []
    var presentation: [ListeningControl] = []
    var parts: [SoundPart] = []
    var bindings: [MappingBinding] = []
    var relations: [OptionControl] = []

    func id<Kind>(_ byte: UInt8) -> EntityID<Kind> {
        EntityID(UUID(uuid: (0x54, 0x4E, 0x46, namespace, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte)))
    }
    static func parameters(_ type: String) throws -> [EffectProfileParameter] {
        guard let parameters = EffectCatalog.effect(type)?.profiles[type == "reverb" ? "unified.v1" : "everyday.v1"] else {
            throw SoundModelError.invalidReference
        }
        return parameters
    }
    static func domain(_ type: String, _ parameter: String) throws -> ParameterDomain {
        guard let parameter = try parameters(type).first(where: { $0.key == parameter }) else {
            throw SoundModelError.invalidReference
        }
        return parameter.domain
    }
    mutating func part(_ byte: UInt8, type: String, values: [String: Double]) throws {
        let parameters = try Self.parameters(type)
        guard Set(values.keys).isSubset(of: Set(parameters.map(\.key))) else { throw SoundModelError.invalidReference }
        parts.append(SoundPart(id: id(byte), type: type, settings: try parameters.map {
            ParameterSetting(key: try ParameterKey($0.key), position: try $0.domain.position(values[$0.key] ?? $0.seed))
        }))
    }
    mutating func slider(_ byte: UInt8, title: String, ends: (String, String), position: Double = 0.5,
                         parent: UInt8? = nil, option: UInt8? = nil) throws {
        let control = SoundControl(id: id(byte), face: .slider, position: .scalar(try Position(position)),
            waypoints: .scalar([.start, try Position(0.5), .end]))
        controls.append(control)
        presentation.append(ListeningControl(id: control.id.rawValue, title: title, face: .slider(ends.0, ends.1),
            readout: parent == nil ? nil : .positionPercent))
        if let parent, let option { relations.append(.choiceOption(parentChoice: id(parent), option: id(option), child: control.id)) }
    }
    mutating func choice(_ byte: UInt8, title: String, options: [(UInt8, String)]) throws {
        let choice = try Choice(options: options.map { id($0.0) })
        let control = SoundControl(id: id(byte), face: .choice(choice), position: .scalar(.start), waypoints: .scalar(choice.positions))
        controls.append(control)
        presentation.append(ListeningControl(id: control.id.rawValue, title: title, face: .choice(options.enumerated().map {
            ListeningOption(id: (id($0.element.0) as OptionID).rawValue, title: $0.element.1, position: choice.positions[$0.offset].value)
        })))
    }
    mutating func map(_ source: UInt8, part byte: UInt8, parameter: String, values: [Double], reference: Double? = nil) throws {
        guard let part = parts.first(where: { $0.id == id(byte) }),
              let control = controls.first(where: { $0.id == id(source) }),
              let base = part.settings.first(where: { $0.key.rawValue == parameter }) else { throw SoundModelError.invalidReference }
        let domain = try Self.domain(part.type, parameter)
        let positions = try control.waypoints.positions(on: .value)
        guard positions.count == values.count else { throw SoundModelError.invalidWaypoints }
        let curve = try MappingCurve(waypoints: zip(positions, values).map {
            Waypoint(position: $0.0, value: try domain.position($0.1))
        }, shapes: Array(repeating: .straight, count: values.count - 1))
        let identity: ControlID = id(UInt8(100 + bindings.count))
        bindings.append(MappingBinding(id: identity.rawValue, source: LibraryMappingSource(control.id.rawValue),
            target: .setting(part: part.id.rawValue, parameter: parameter), reference: try reference.map(domain.position) ?? base.position,
            response: .lane(.sampling(curve, source: control)), status: .active,
            provenance: MappingProvenance(source: control, selector: nil, target: nil, setting: part)))
    }
    mutating func volume(gain: UInt8) throws {
        let control = SoundControl(id: id(19), face: .slider, position: .scalar(try Position(0.8)), waypoints: .scalar([.start, .end]))
        controls.append(control)
        presentation.append(ListeningControl(id: control.id.rawValue, title: "Volume", face: .slider("−24 dB", "+6 dB"), readout: .decibels(-24, 6)))
        try map(19, part: gain, parameter: "gainDb", values: [-24, 6], reference: 0)
    }
    func definition(_ name: String) -> BlockDefinition {
        BlockDefinition(id: id(1), version: id(2), name: name,
            content: SoundBlock(pieces: parts.map(BlockPiece.part), controls: controls, storage: .bindings(bindings), optionControls: relations))
    }
}

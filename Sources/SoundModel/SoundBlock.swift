import Foundation

struct ParameterKey: Hashable, Sendable, Codable {
    let rawValue: String

    init(_ rawValue: String) throws {
        guard !rawValue.isEmpty else { throw SoundModelError.invalidReference }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ControlValue: Equatable, Sendable, Codable {
    case scalar(Position)
    case xy(x: Position, y: Position)
}

public enum ControlAxis: String, Hashable, Sendable, Codable { case value, x, y }

enum ControlFace: Equatable, Sendable, Codable {
    case slider
    case choice(Choice)
    case xy
}

enum ControlWaypoints: Equatable, Sendable, Codable {
    case scalar([Position])
    case xy(x: [Position], y: [Position])

    func positions(on axis: ControlAxis) throws -> [Position] {
        switch (self, axis) {
        case (.scalar(let points), .value): return points
        case (.xy(let points, _), .x), (.xy(_, let points), .y): return points
        default: throw SoundModelError.invalidControl
        }
    }
}

struct SoundControl: Equatable, Sendable, Codable {
    let id: ControlID
    let face: ControlFace
    let position: ControlValue
    let waypoints: ControlWaypoints

    func position(on axis: ControlAxis) throws -> Position {
        switch (position, face, axis) {
        case (.scalar(let position), .slider, .value):
            return position
        case (.scalar(let position), .choice(let choice), .value):
            return try choice.position(of: choice.option(at: position))
        case (.xy(let x, _), .xy, .x): return x
        case (.xy(_, let y), .xy, .y): return y
        default: throw SoundModelError.invalidControl
        }
    }

    func validate() throws {
        func validatePoints(_ points: [Position]) throws {
            guard points.first == .start, points.last == .end,
                zip(points, points.dropFirst()).allSatisfy({ $0.value < $1.value })
            else { throw SoundModelError.invalidWaypoints }
        }
        switch (face, position, waypoints) {
        case (.slider, .scalar, .scalar(let points)):
            try validatePoints(points)
        case (.xy, .xy, .xy(let x, let y)):
            try validatePoints(x)
            try validatePoints(y)
        case (.choice(let choice), .scalar, .scalar(let points)):
            guard points == choice.positions else { throw SoundModelError.invalidWaypoints }
        default: throw SoundModelError.invalidControl
        }
    }
}

struct ParameterSetting: Equatable, Sendable, Codable {
    let key: ParameterKey
    let position: Position
}

struct SoundPart: Equatable, Sendable, Codable {
    let id: PartID
    let type: String
    let settings: [ParameterSetting]
}

struct ParameterMapping: Equatable, Sendable, Codable {
    let control: ControlID
    let axis: ControlAxis
    let part: PartID
    let parameter: ParameterKey
    let curve: MappingCurve
}

struct BlockUse: Equatable, Sendable, Codable {
    let site: UseSiteID
    private let storage: LocalBlockStorage
    var content: SoundBlock {
        switch storage { case .inline(let block): return block; case .owned(let payload, _): return payload.block }
    }
    var payload: LibraryPayload? { if case .owned(let payload, _) = storage { return payload }; return nil }
    var original: DefinitionReference? { if case .owned(_, let reference) = storage { return reference }; return nil }
    init(site: UseSiteID, content: SoundBlock) { self.site = site; storage = .inline(content) }
    init(site: UseSiteID, payload: LibraryPayload, original: DefinitionReference) {
        self.site = site; storage = .owned(payload, original)
    }
    private enum CodingKeys: CodingKey { case site, content, payload, original }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        site = try c.decode(UseSiteID.self, forKey: .site)
        if c.contains(.payload) {
            guard !c.contains(.content) else { throw LibraryError.invalidCanonical }
            storage = .owned(try c.decode(LibraryPayload.self, forKey: .payload), try c.decode(DefinitionReference.self, forKey: .original))
        } else {
            guard !c.contains(.original) else { throw LibraryError.invalidCanonical }
            storage = .inline(try c.decode(SoundBlock.self, forKey: .content))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(site, forKey: .site)
        switch storage {
        case .inline(let block): try c.encode(block, forKey: .content)
        case .owned(let payload, let original): try c.encode(payload, forKey: .payload); try c.encode(original, forKey: .original)
        }
    }
}
private indirect enum LocalBlockStorage: Equatable, Sendable {
    case inline(SoundBlock)
    case owned(LibraryPayload, DefinitionReference)
}

struct ReferencedBlockUse: Equatable, Sendable, Codable {
    let site: UseSiteID
    let definition: DefinitionReference
}

indirect enum BlockPiece: Equatable, Sendable, Codable {
    case part(SoundPart)
    case block(BlockUse)
    case reference(ReferencedBlockUse)
}

// Inline authoring content for the first compiler unit, not the library/file schema.
struct SoundBlock: Equatable, Sendable, Codable {
    let pieces: [BlockPiece]
    let controls: [SoundControl]
    let mappingStorage: MappingStorage
    let selections: [MappingSelection]
    let optionControls: [OptionControl]
    var mappings: [ParameterMapping] { if case .legacy(let value) = mappingStorage { return value }; return [] }
    init(pieces: [BlockPiece], controls: [SoundControl], mappings: [ParameterMapping]) {
        self.pieces = pieces; self.controls = controls; mappingStorage = .legacy(mappings); selections = []; optionControls = []
    }
    init(pieces: [BlockPiece], controls: [SoundControl], storage: MappingStorage, selections: [MappingSelection] = [], optionControls: [OptionControl] = []) {
        self.pieces = pieces; self.controls = controls; mappingStorage = storage; self.selections = selections; self.optionControls = optionControls
    }
    private enum CodingKeys: CodingKey { case pieces, controls, mappings, bindings, selections, optionControls }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pieces = try c.decode([BlockPiece].self, forKey: .pieces); controls = try c.decode([SoundControl].self, forKey: .controls)
        guard c.contains(.bindings) != c.contains(.mappings) else { throw LibraryError.invalidCanonical }
        optionControls = try c.decodeIfPresent([OptionControl].self, forKey: .optionControls) ?? []
        selections = c.contains(.bindings) ? try c.decode([MappingSelection].self, forKey: .selections) : []
        guard c.contains(.bindings) || !c.contains(.selections) else { throw LibraryError.invalidCanonical }
        mappingStorage = c.contains(.bindings) ? .bindings(try c.decode([MappingBinding].self, forKey: .bindings))
            : .legacy(try c.decode([ParameterMapping].self, forKey: .mappings))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pieces, forKey: .pieces); try c.encode(controls, forKey: .controls)
        if !optionControls.isEmpty { try c.encode(optionControls.sorted { $0.order < $1.order }, forKey: .optionControls) }
        switch mappingStorage { case .legacy(let values): try c.encode(values, forKey: .mappings)
        case .bindings(let values):
            try c.encode(values.sorted { $0.id.uuidString < $1.id.uuidString }, forKey: .bindings)
            try c.encode(selections.sorted { $0.source.rawValue.uuidString < $1.source.rawValue.uuidString }, forKey: .selections) }
    }
}

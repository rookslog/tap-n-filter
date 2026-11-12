import Foundation

enum SoundModelError: Error, Equatable {
    case invalidPosition(Double)
    case invalidCurve
    case duplicateWaypoint
    case invalidChoice
    case unknownOption
    case duplicateIdentity
    case invalidReference
    case incompleteParameters
    case invalidControl
    case invalidWaypoints
    case unsupportedReference
}

struct Position: Hashable, Sendable, Codable {
    let value: Double

    init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw SoundModelError.invalidPosition(value)
        }
        self.value = value
    }

    static let start = Position(clamping: 0)
    static let end = Position(clamping: 1)

    // Only evaluation arithmetic may clamp; import and command input must reject.
    fileprivate init(clamping value: Double) {
        self.value = min(1, max(0, value))
    }

    static func evaluated(_ value: Double) throws -> Position {
        guard value.isFinite else { throw SoundModelError.invalidPosition(value) }
        return Position(clamping: value)
    }

    static func interpolated(_ value: Double) -> Position {
        precondition(value.isFinite)
        return Position(clamping: value)
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Double.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct EntityID<Kind>: Hashable, Sendable, Codable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum RootUseKind {}
enum UseSiteKind {}
enum PartKind {}
enum ControlKind {}
enum OptionKind {}
typealias RootUseID = EntityID<RootUseKind>
typealias UseSiteID = EntityID<UseSiteKind>
typealias PartID = EntityID<PartKind>
typealias ControlID = EntityID<ControlKind>
typealias OptionID = EntityID<OptionKind>

struct Choice: Equatable, Sendable, Codable {
    let options: [OptionID]

    init(options: [OptionID]) throws {
        guard options.count >= 2, Set(options).count == options.count else {
            throw SoundModelError.invalidChoice
        }
        self.options = options
    }

    var positions: [Position] {
        options.indices.map { Position(clamping: Double($0) / Double(options.count - 1)) }
    }

    func option(at position: Position) -> OptionID {
        options[Int((position.value * Double(options.count - 1)).rounded())]
    }

    func position(of option: OptionID) throws -> Position {
        guard let index = options.firstIndex(of: option) else { throw SoundModelError.unknownOption }
        return positions[index]
    }

    init(from decoder: Decoder) throws {
        try self.init(options: decoder.singleValueContainer().decode([OptionID].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(options)
    }
}

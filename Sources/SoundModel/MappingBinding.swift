import Foundation

public enum LibraryMappingTarget: Hashable, Sendable, Codable {
    case setting(part: UUID, parameter: String)
    case control(site: UUID?, control: UUID, axis: ControlAxis)
}
public enum LibraryMappingSource: Hashable, Sendable, Codable {
    case control(id: UUID, axis: ControlAxis)
    public init(_ control: UUID, axis: ControlAxis = .value) { self = .control(id: control, axis: axis) }
    public var control: UUID { switch self { case .control(let id, _): return id } }
    public var axis: ControlAxis { switch self { case .control(_, let axis): return axis } }
}
public struct LibraryLanePoint: Equatable, Sendable, Codable {
    public let position: Double
    public let value: Double
    public init(_ position: Double, _ value: Double) { self.position = position; self.value = value }
}
public enum LibraryStretch: String, Sendable, Codable { case curve, straight, ease, step }
public struct LibraryLaneStretch: Equatable, Sendable {
    public let kind: LibraryStretch
    public let first: Double
    public let second: Double
    public let jump: Double
}
public enum LibraryMappingStorageKind: Sendable { case legacy, bindings }
public struct LibraryMappingLane: Equatable, Sendable {
    let curve: MappingCurve
    public init(points: [LibraryLanePoint], stretches: [LibraryStretch]) throws {
        curve = try MappingCurve(waypoints: points.map { try Waypoint(position: Position($0.position), value: Position($0.value)) },
            shapes: stretches.map { StretchShape(rawValue: $0.rawValue)! })
    }
    init(curve: MappingCurve) { self.curve = curve }
    public var points: [LibraryLanePoint] { curve.waypoints.map { LibraryLanePoint($0.position.value, $0.value.value) } }
    public func value(at position: Double) throws -> Double { curve.value(at: try Position(position)).value }
    public func stretches() throws -> [LibraryLaneStretch] {
        struct Segment: Decodable { let shape: LibraryStretch; let first: Double; let second: Double; let jump: Double }
        struct Read: Decodable { let segments: [Segment] }
        return try JSONDecoder().decode(Read.self, from: JSONEncoder().encode(curve)).segments.map {
            LibraryLaneStretch(kind: $0.shape, first: $0.first, second: $0.second, jump: $0.jump)
        }
    }
}
public struct LibrarySourceOptionValue: Equatable, Sendable, Codable {
    public let option: UUID
    public let value: Double
    public init(option: UUID, value: Double) { self.option = option; self.value = value }
}
enum MappingTransfer: Equatable, Sendable, Codable {
    case continuous(MappingCurve)
    case choices([LibrarySourceOptionValue])
    static func sampling(_ lane: MappingCurve, source: SoundControl) -> Self {
        if case .choice(let choice) = source.face {
            return .choices(choice.options.map { LibrarySourceOptionValue(option: $0.rawValue, value: lane.value(at: try! choice.position(of: $0)).value) })
        }
        return .continuous(lane)
    }
    var curve: MappingCurve? { if case .continuous(let c) = self { return c }; return nil }
    var values: [UUID: Double] {
        if case .choices(let entries) = self { return Dictionary(uniqueKeysWithValues: entries.map { ($0.option, $0.value) }) }; return [:]
    }
    func validate(source: SoundControl, axis: ControlAxis) throws {
        switch (source.face, self) {
        case (.choice(let choice), .choices(let entries)):
            guard entries.count <= 64, entries.count == choice.options.count, Set(entries.map(\.option)) == Set(choice.options.map(\.rawValue)),
                  entries.allSatisfy({ $0.value.isFinite && (0...1).contains($0.value) }) else { throw LibraryError.invalidCanonical }
        case (.slider, .continuous(let curve)), (.xy, .continuous(let curve)):
            let points = try source.waypoints.positions(on: axis)
            guard curve.waypoints.count <= 256, curve.waypoints.allSatisfy({ points.contains($0.position) }) else { throw SoundModelError.invalidWaypoints }
        default: throw LibraryError.invalidCanonical
        }
    }
}
struct MappingCase: Equatable, Sendable, Codable {
    let option: OptionID
    let lane: MappingTransfer
}
enum MappingResponse: Equatable, Sendable, Codable {
    case lane(MappingTransfer)
    case options(selector: ControlID, cases: [MappingCase])
    var lanes: [MappingTransfer] {
        switch self { case .lane(let lane): return [lane]; case .options(_, let cases): return cases.map(\.lane) }
    }
    var selector: ControlID? { if case .options(let id, _) = self { return id }; return nil }
}
public enum LibraryMappingBreak: String, Sendable, Codable { case sourceRemoved, targetRemoved, selectorRemoved }
enum MappingStatus: Equatable, Sendable, Codable { case active, broken(LibraryMappingBreak) }
struct MappingProvenance: Equatable, Sendable, Codable {
    let source: SoundControl
    let selector: SoundControl?
    let target: SoundControl?
    var setting: SoundPart? = nil
}
struct MappingBinding: Equatable, Sendable, Codable {
    let id: UUID
    let source: LibraryMappingSource
    let target: LibraryMappingTarget
    let reference: Position
    var response: MappingResponse
    var status: MappingStatus
    var provenance: MappingProvenance
}
struct MappingSelection: Equatable, Sendable, Codable {
    let source: ControlID
    let selector: ControlID
}
enum MappingStorage: Equatable, Sendable {
    case legacy([ParameterMapping])
    case bindings([MappingBinding])
}

extension SoundBlock {
    var bindings: [MappingBinding]? { if case .bindings(let result) = mappingStorage { return result }; return nil }
    func replacing(pieces: [BlockPiece]? = nil, controls: [SoundControl]? = nil) -> Self {
        Self(pieces: pieces ?? self.pieces, controls: controls ?? self.controls, storage: mappingStorage, selections: selections, optionControls: optionControls)
    }
    func replacing(bindings: [MappingBinding]) -> Self { Self(pieces: pieces, controls: controls, storage: .bindings(bindings), selections: selections, optionControls: optionControls) }
    func promoted() throws -> Self {
        if bindings != nil { return self }
        let parts = pieces.compactMap { if case .part(let p) = $0 { return p }; return nil }
        let converted = try mappings.enumerated().map { index, mapping -> MappingBinding in
            guard let control = controls.first(where: { $0.id == mapping.control }),
                  let setting = parts.first(where: { $0.id == mapping.part })?.settings.first(where: { $0.key == mapping.parameter }) else { throw LibraryError.invalidCanonical }
            // Fixed-width ordinal IDs retain the original floating-point accumulation order.
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", UInt64(index)))!
            return MappingBinding(id: id, source: LibraryMappingSource(control.id.rawValue, axis: mapping.axis),
                target: .setting(part: mapping.part.rawValue, parameter: mapping.parameter.rawValue), reference: setting.position,
                response: .lane(.sampling(mapping.curve, source: control)), status: .active, provenance: MappingProvenance(source: control, selector: nil, target: nil, setting: parts.first { $0.id == mapping.part }))
        }
        return replacing(bindings: converted)
    }
    var needsVersion4: Bool {
        bindings != nil || pieces.contains { if case .block(let use) = $0 { return use.payload != nil || use.content.needsVersion4 }; return false }
    }
}

public struct LibraryMappingSummary: Equatable, Sendable {
    public let id: UUID
    public let path: [UUID]
    public let source: LibraryMappingSource
    public let target: LibraryMappingTarget
    public let reference: Double
    public let selector: UUID?
    public let lane: LibraryMappingLane?
    public let cases: [UUID: LibraryMappingLane]
    public let sourceValues: [UUID: Double]
    public let caseSourceValues: [UUID: [UUID: Double]]
    public let broken: LibraryMappingBreak?
    public let storage: LibraryMappingStorageKind
    public let sourceWaypoints: [Double]
}
public struct LibraryMappingControl: Equatable, Sendable {
    public let address: LibraryControlAddress
    public let manual: LibraryPosition
    public let effective: LibraryPosition
    public let adjustments: [ControlAxis: Double]
}
public struct LibraryMappingControlDescriptor: Equatable, Sendable {
    public let address: LibraryControlAddress
    public let waypoints: [ControlAxis: [Double]]
    public let presentation: LibraryControl?
    public let storage: LibraryMappingStorageKind
}
public struct LibraryMappingSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let bindings: [LibraryMappingSummary]
    public let controls: [LibraryMappingControl]
    public let descriptors: [LibraryMappingControlDescriptor]
}

extension MappingTransfer {
    var ordered: Self {
        if case .choices(let entries) = self { return .choices(entries.sorted { $0.option.uuidString < $1.option.uuidString }) }
        return self
    }
}
extension MappingResponse {
    var ordered: Self {
        switch self {
        case .lane(let transfer): return .lane(transfer.ordered)
        case .options(let selector, let cases): return .options(selector: selector,
            cases: cases.sorted { $0.option.rawValue.uuidString < $1.option.rawValue.uuidString }.map { MappingCase(option: $0.option, lane: $0.lane.ordered) })
        }
    }
}
extension MappingBinding {
    private enum CodingKeys: CodingKey { case id, source, target, reference, response, status, provenance }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(source, forKey: .source); try c.encode(target, forKey: .target)
        try c.encode(reference, forKey: .reference); try c.encode(response.ordered, forKey: .response)
        try c.encode(status, forKey: .status); try c.encode(provenance, forKey: .provenance)
    }
}

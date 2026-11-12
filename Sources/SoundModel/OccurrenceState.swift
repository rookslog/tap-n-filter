import Foundation

struct OccurrenceControlKey: Hashable, Sendable {
    let path: [UseSiteID]
    let control: ControlID
    var orderBytes: Data {
        var stream = AuthoredStream(); stream.count(path.count)
        for site in path { stream.id(site.rawValue) }; stream.id(control.rawValue)
        return stream.data
    }
}

public struct LibraryReference: Equatable, Sendable {
    public let definition: UUID
    public let revision: UUID
    public init(definition: UUID, revision: UUID) { self.definition = definition; self.revision = revision }
    var reference: DefinitionReference { DefinitionReference(id: DefinitionID(definition), version: DefinitionVersionID(revision)) }
}
public struct LibraryControlAddress: Hashable, Sendable {
    public let path: [UUID]
    public let control: UUID
    public init(path: [UUID], control: UUID) { self.path = path; self.control = control }
    var key: OccurrenceControlKey { OccurrenceControlKey(path: path.map(UseSiteID.init), control: ControlID(control)) }
}
public struct LibraryExpansionLimits: Sendable {
    public let maximumDepth: Int
    public let maximumOccurrences: Int
    public let maximumParts: Int
    public init(maximumDepth: Int, maximumOccurrences: Int, maximumParts: Int) throws {
        guard maximumDepth > 0, maximumOccurrences > 0, maximumParts > 0 else { throw LibraryError.invalidLimits }
        self.maximumDepth = maximumDepth; self.maximumOccurrences = maximumOccurrences; self.maximumParts = maximumParts
    }
}
public struct LibraryOccurrenceSummary: Equatable, Sendable {
    public let path: [UUID]
    public let reference: LibraryReference?
    public let controls: [LibraryControl]
    public let positions: [UUID: LibraryPosition]
}

extension CodingUserInfoKey {
    static let libraryLegacy = CodingUserInfoKey(rawValue: "tnf.library.schema2-migration")!
    static let libraryExpansion = CodingUserInfoKey(rawValue: "tnf.library.expansion")!
}

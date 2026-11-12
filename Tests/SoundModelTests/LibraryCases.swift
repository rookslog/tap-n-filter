import Foundation
@testable import SoundModel

actor LibraryMemoryPort: LibraryPersistence {
    var data: Data?
    var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func commit(_ value: Data) -> LibraryWriteOutcome { data = value; writes += 1; return .committed }
}

struct LibraryCases {
    let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)

    func test_canonical_stream() throws {
        let profiles = try LibraryProfiles()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/filters-v5-library.json")
        let archive = try LibraryArchive.migratingV2(Data(contentsOf: fixture), profiles: profiles,
            limits: LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128))
        let definition = try requireValue(archive.revisions.first { $0.definition.name == "Filters" }).definition
        let presentation = try profiles.presentation(for: definition)
        func payload(_ block: SoundBlock, _ label: String) -> LibraryPayload {
            LibraryPayload(profile: LibraryProfiles.filters, block: block,
                presentation: presentation.enumerated().map { $0.offset == 0 ? $0.element.renamed(label) : $0.element })
        }
        let a = payload(definition.content, "Café")
        let b = payload(definition.content, "Cafe\u{301}")
        try requireEqual(a.canonicalData, b.canonicalData, "NFC equality")
        try requireEqual(a.contentHash, b.contentHash)
        let zero = definition.content.withPositions([definition.content.controls[0].id: .scalar(try Position(-0.0))])
        try requireEqual(payload(zero, "Café").contentHash, a.contentHash, "signed zero")
        let reordered = SoundBlock(pieces: definition.content.pieces.reversed(), controls: definition.content.controls,
                                   mappings: definition.content.mappings)
        try requireDifferent(payload(reordered, "Café").contentHash, a.contentHash)
        let domainChanged = LibraryPayload(profile: LibraryProfiles.everyday, block: a.block, presentation: a.presentation)
        try requireDifferent(domainChanged.contentHash, a.contentHash)
        let reorderedMappings = SoundBlock(pieces: a.block.pieces, controls: a.block.controls, mappings: a.block.mappings.reversed())
        try requireDifferent(payload(reorderedMappings, "Café").contentHash, a.contentHash)
        let curve = a.block.mappings[0].curve
        let inserted = try curve.insertingWaypoint(at: Position(0.37))
        let data = try JSONEncoder().encode(inserted)
        let decoded = try JSONDecoder().decode(MappingCurve.self, from: data)
        var left = AuthoredStream(), right = AuthoredStream()
        inserted.appendCanonical(to: &left); decoded.appendCanonical(to: &right)
        try requireEqual(left.data, right.data, "exact stored Bezier subdivision")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var segments = object["segments"] as! [[String: Any]]
        segments[0]["jump"] = 0.13; object["segments"] = segments
        let altered = try JSONDecoder().decode(MappingCurve.self, from: JSONSerialization.data(withJSONObject: object))
        var changed = AuthoredStream(); altered.appendCanonical(to: &changed)
        try requireDifferent(left.data, changed.data)
        print("GOLDEN filters-nfc-v1 \(try a.contentHash) bytes=\(try a.canonicalData.count)")
        try requireEqual(a.contentHash, "3366a8f086ab6ca53da5d30a12e69125bdded5febd226f3b3e2f58f5c6a2616c", "canonical-v1 golden")
    }

    func test_scopes_and_refusals() async throws {
        let profiles = try LibraryProfiles(), recipe = try Filters()
        let child = recipe.definition.content
        let nested = SoundBlock(pieces: [.block(BlockUse(site: UseSiteID(), content: child)),
                                         .block(BlockUse(site: UseSiteID(), content: child))], controls: [], mappings: [])
        let sound = try CompiledSound(block: nested, root: RootUseID(), catalog: profiles.catalog(LibraryProfiles.filters))
        try requireEqual(sound.parts.count, child.pieces.count * 2, "same local IDs in distinct occurrence scopes")
        let duplicate = SoundBlock(pieces: child.pieces + [child.pieces[0]], controls: child.controls, mappings: child.mappings)
        try requireThrows(CompiledSound(block: duplicate, root: RootUseID(), catalog: profiles.catalog(LibraryProfiles.filters)))
        let reference = SoundBlock(pieces: [.reference(ReferencedBlockUse(site: UseSiteID(), definition: recipe.definition.reference))],
                                   controls: [], mappings: [])
        let encoded = try JSONEncoder().encode(reference)
        try requireEqual(try JSONDecoder().decode(SoundBlock.self, from: encoded), reference)
        try requireThrows(CompiledSound(block: reference, root: RootUseID(), catalog: profiles.catalog(LibraryProfiles.filters))) {
            try requireEqual($0 as? SoundModelError, .unsupportedReference)
        }
        let archive = try LibraryArchive.initial(profiles: profiles)
        let unknownPayload = LibraryPayload(profile: "unknown.v99", block: child,
                                            presentation: try profiles.presentation(for: recipe.definition))
        try requireThrows(profiles.validate(unknownPayload, root: RootUseID()))
        var unknown = archive
        unknown = LibraryArchive(format: unknown.format, schema: 99, commit: unknown.commit, provenance: unknown.provenance,
            revisions: unknown.revisions, heads: unknown.heads, uses: [], assignments: [], enabled: false)
        let port = LibraryMemoryPort(try unknown.encoded(limits: limits))
        do {
            _ = try await SoundLibrarySession(persistence: port, limits: limits)
            throw ContractFailure(description: "future archive must refuse")
        } catch LibraryError.unsupportedFormat { }
        try requireEqual(await port.writes, 0)
        var malformed = try JSONSerialization.jsonObject(with: archive.encoded(limits: limits)) as! [String: Any]
        var records = malformed["revisions"] as! [[String: Any]]
        records[0]["contentHash"] = String(repeating: "0", count: 64); malformed["revisions"] = records
        let invalid = LibraryMemoryPort(try JSONSerialization.data(withJSONObject: malformed))
        do {
            _ = try await SoundLibrarySession(persistence: invalid, limits: limits)
            throw ContractFailure(description: "wrong hash must refuse")
        } catch LibraryError.invalidArchive { }
        try requireEqual(await invalid.writes, 0)
        malformed = try JSONSerialization.jsonObject(with: archive.encoded(limits: limits)) as! [String: Any]
        malformed["marks"] = [["revision": archive.revisions[0].definition.version.rawValue.uuidString]]
        let protected = LibraryMemoryPort(try JSONSerialization.data(withJSONObject: malformed))
        do {
            _ = try await SoundLibrarySession(persistence: protected, limits: limits)
            throw ContractFailure(description: "unsupported protected state must refuse, not truncate")
        } catch LibraryError.unsupportedFormat { }
        try requireEqual(await protected.writes, 0)
        let tiny = try LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 2)
        let bounded = LibraryMemoryPort()
        let session = try await SoundLibrarySession(persistence: bounded, limits: tiny)
        let id = try await session.snapshot().definitions[0].id
        _ = try await session.select(id, on: "test.limits")
        let before = await bounded.data
        do {
            _ = try await session.createFromUse(on: "test.limits", name: "over cap")
            throw ContractFailure(description: "history cap must refuse")
        } catch LibraryError.limitExceeded { }
        try requireEqual(await bounded.data, before)
        try requireEqual(try await session.snapshot().definitions.count, 2)
    }

    func test_archived_v1_migration() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for file in ["everyday-01.session.json", "controls-v4.session.json"] {
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent(file))
            let old = try JSONDecoder().decode(SoundSessionArchive.self, from: bytes)
            let port = LibraryMemoryPort()
            let session = try await SoundLibrarySession(persistence: port, limits: limits, migratingV1: bytes)
            _ = try await session.checkpoint()
            let saved = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
            try requireEqual(saved.revisions.map(\.definition), old.definitions, "exact archived builtin revisions, not current recipes")
            if file == "controls-v4.session.json" {
                let filters = saved.revisions.first { $0.definition.name == "Filters" }!
                try requireEqual(filters.payload.presentation[1].face, .slider("Off", "1 kHz"))
                try requireEqual(try filters.payload.presentation[1].readout!.value(at: 1), 1000, accuracy: 1e-9)
            }
            for binding in old.assignments {
                let oldUse = old.uses.first { $0.id == binding.assignment.root }!
                let oldDefinition = old.definitions.first { $0.reference == oldUse.definition }!
                let profiles = try LibraryProfiles(), profile = try profiles.profile(for: oldDefinition)
                let positions = Dictionary(uniqueKeysWithValues: binding.positions.map { ($0.control, $0.value) })
                let compiled = try CompiledSound(block: oldDefinition.content.withPositions(positions), root: RootUseID(), catalog: profiles.catalog(profile))
                let expected = try profiles.native(compiled, profile: profile)
                let state = try await session.snapshot()
                let assignment = state.assignments.first { $0.target == binding.assignment.app.bundleIdentifier }!
                try requireEqual(assignment.parts, expected)
                try requireEqual(assignment.id, binding.assignment.id.rawValue)
                try requireEqual(assignment.isEnabled, binding.assignment.isEnabled)
            }
            let fresh = try await SoundLibrarySession(persistence: port, limits: limits)
            try requireEqual(try await fresh.snapshot(), try await session.snapshot())
            try requireEqual(try Data(contentsOf: fixtures.appendingPathComponent(file)), bytes)
        }
        let current = try await ListeningSession()
        let bytes = try await current.savedData()
        var foreign = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var defs = foreign["definitions"] as! [[String: Any]]
        defs[0]["id"] = ["rawValue": UUID().uuidString]; foreign["definitions"] = defs
        let port = LibraryMemoryPort()
        var refused = false
        do {
            _ = try await SoundLibrarySession(persistence: port, limits: limits,
                    migratingV1: JSONSerialization.data(withJSONObject: foreign))
        } catch { refused = true }
        try requireTrue(refused, "generic custom v1 cannot claim builtin profile")
        try requireEqual(await port.writes, 0)
    }
}

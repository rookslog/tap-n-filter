import Foundation
@testable import SoundModel

struct RangeCompatibilityCases {
    let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)

    func test_v5_library_reopens_without_retune() async throws {
        let profiles = try LibraryProfiles()
        let current = try LibraryArchive.initial(profiles: profiles)
        for kind in ["everyday", "filters"] {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(kind)-v5-library.json")
            let bytes = try Data(contentsOf: fixture)
            let old = try LibraryArchive.migratingV2(bytes, profiles: profiles, limits: limits)
            let port = LibraryMemoryPort(nil)
            let session = try await SoundLibrarySession(persistence: port, limits: limits, migratingSchema2: bytes)
            try requireEqual(await port.writes, 0)
            let state = try await session.snapshot()
            let app = try requireValue(state.assignments.first)
            let owned = try requireValue(old.uses.first)
            let record = try requireValue(old.revisions.first { $0.definition.id == owned.use.definition.id })
            let positions = Dictionary(uniqueKeysWithValues: owned.positions.map { ($0.id, $0.value) })
            let compiled = try CompiledSound(block: record.definition.content.withPositions(positions), root: owned.use.id,
                                            catalog: profiles.catalog(record.profile))
            try requireEqual(app.parts, try profiles.native(compiled, profile: record.profile))
            try requireEqual(app.parts.first { $0.type == "dynamics" }?.parameters.first { $0.key == "thresholdDb" }?.value, -17)
            _ = try await session.checkpoint()
            let saved = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
            try requireEqual(saved.revisions, old.revisions)
            try requireEqual(saved.heads, old.heads)
            try requireEqual(saved.uses, old.uses)
            try requireEqual(saved.assignments, old.assignments)
            for revision in old.revisions {
                let new = try requireValue(current.revisions.first { $0.definition.id == revision.definition.id })
                try requireDifferent(new.definition.version, revision.definition.version)
                try requireDifferent(new.contentHash, revision.contentHash)
                try requireEqual(new.profile, revision.profile)
            }
            let reopened = try await SoundLibrarySession(persistence: port, limits: limits)
            try requireEqual(try await reopened.snapshot(), try await session.snapshot())
            _ = try await session.createFromUse(on: "synthetic.unit22", name: "Archived custom")
            let authored = try await session.snapshot()
            let custom = try requireValue(authored.definitions.first { $0.origin == "custom" })
            try requireEqual(custom.profile, record.profile)
            let authoredArchive = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
            let authoredReopened = try await SoundLibrarySession(persistence: port, limits: limits)
            try requireEqual(try await authoredReopened.snapshot(), authored)
            _ = try await authoredReopened.checkpoint()
            let reopenedArchive = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
            try requireEqual(reopenedArchive.revisions, authoredArchive.revisions)
            try requireEqual(try await authoredReopened.snapshot().assignments[0].parts, app.parts)
            try requireEqual(try Data(contentsOf: fixture), bytes)
        }
    }

    func test_v5_high_cut_recognition_preserves_100hz_readout() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/filters-v5-library.json")
        let profiles = try LibraryProfiles()
        let old = try LibraryArchive.migratingV2(Data(contentsOf: fixture), profiles: profiles, limits: limits)
        let filters = try requireValue(old.revisions.first { $0.definition.name == "Filters" })
        let presentation = try profiles.presentation(for: filters.definition)
        try requireEqual(presentation[1].face, .slider("Off", "100 Hz"))
        try requireEqual(try presentation[1].readout!.value(at: 1), 100, accuracy: 1e-9)
        let current = try Filters().definition
        let migration = try requireValue(BuiltinSounds.highCutMigration(from: filters.definition, to: current))
        try requireEqual(migration.factor, 1, accuracy: 1e-12)
        try requireEqual(try profiles.profile(for: current), LibraryProfiles.filters)
    }
}

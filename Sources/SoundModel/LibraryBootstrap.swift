import Foundation

public enum LibraryMigrationSource: Sendable {
    case v1(Data)
    case schema2(Data)
    case schema3(Data)
    case schema4(Data)
}
public enum LibraryMigrationFormat: Equatable, Sendable { case v1, schema2, schema3, schema4 }
public struct LibraryMigrationReceipt: Equatable, Sendable {
    public let sourceFormat: LibraryMigrationFormat
    public let sourceDigest: String
    public let migrationVersion: Int
}
public enum LibraryOpenFailure: Equatable, Sendable {
    case load(String)
    case destination(String)
    case source(String)
    case initialization(String)
    case write(LibraryWriteRefusal)
}
public enum LibraryOpenResult: Sendable {
    case existing(SoundLibrarySession)
    case fresh(SoundLibrarySession)
    case migrated(SoundLibrarySession, LibraryMigrationReceipt)
    case refused(LibraryOpenFailure)
    case unresolved(LibraryMigrationReceipt, String)
}

extension SoundLibrarySession {
    /// One loaded destination and writer. Paths, normal-App seeding and instance locks belong to the caller.
    public static func open(persistence: any LibraryPersistence, limits: LibraryLimits,
                            migrationSource: LibraryMigrationSource? = nil,
                            builtins: LibraryBuiltinSet = .standard) async -> LibraryOpenResult {
        let saved: Data?
        do { saved = try await persistence.load() }
        catch { return .refused(.load(String(describing: error))) }
        if let saved {
            do {
                let archive = try storedArchive(saved, limits: limits)
                let session = try await Self(archive: archive, profiles: LibraryProfiles(),
                    persistence: persistence, limits: limits, committed: saved)
                return .existing(session)
            } catch { return .refused(.destination(String(describing: error))) }
        }
        guard let migrationSource else {
            do {
                let profiles = try LibraryProfiles()
                let session = try await Self(archive: LibraryArchive.initial(profiles: profiles, builtins: builtins), profiles: profiles,
                    persistence: persistence, limits: limits, committed: nil)
                return .fresh(session)
            } catch { return .refused(.initialization(String(describing: error))) }
        }
        let session: Self, receipt: LibraryMigrationReceipt
        do {
            let profiles = try LibraryProfiles()
            let imported: LibraryArchive, bytes: Data, format: LibraryMigrationFormat, spelling: String
            switch migrationSource {
            case .v1(let data):
                bytes = data; format = .v1; spelling = "v1"
                guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
                imported = try LibraryArchive.migrating(data, profiles: profiles)
            case .schema2(let data):
                bytes = data; format = .schema2; spelling = "schema2"
                guard data.count <= limits.maximumBytes else { throw LibraryError.limitExceeded }
                imported = try LibraryArchive.migratingV2(data, profiles: profiles, limits: limits)
            case .schema3(let data):
                bytes = data; format = .schema3; spelling = "schema3"
                imported = try LibraryArchive.migratingV3(data, profiles: profiles, limits: limits)
            case .schema4(let data):
                bytes = data; format = .schema4; spelling = "schema4"
                imported = try LibraryArchive.migratingV4(data, profiles: profiles, limits: limits)
            }
            receipt = LibraryMigrationReceipt(sourceFormat: format, sourceDigest: libraryDigest(bytes), migrationVersion: 3)
            let archive = LibraryArchive(format: imported.format, schema: imported.schema, commit: imported.commit,
                provenance: "tnf.bootstrap/3;source=\(spelling);sha256=\(receipt.sourceDigest);prior=\(imported.provenance)",
                revisions: imported.revisions, heads: imported.heads, uses: imported.uses,
                assignments: imported.assignments, enabled: imported.enabled)
            session = try await Self(archive: archive, profiles: profiles, persistence: persistence,
                                     limits: limits, committed: nil)
        } catch { return .refused(.source(String(describing: error))) }
        do {
            let commit = try await session.checkpoint()
            switch commit.outcome {
            case .committed, .identical: return .migrated(session, receipt)
            case .refused(let reason): return .refused(.write(reason))
            case .unresolved(let detail): return .unresolved(receipt, detail)
            }
        } catch { return .refused(.initialization(String(describing: error))) }
    }
}

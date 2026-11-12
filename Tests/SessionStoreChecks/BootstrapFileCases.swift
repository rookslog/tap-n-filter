import Foundation
import CryptoKit
import SoundModel
import SessionStore

private enum BootstrapFileFailure: Error { case failed(String) }
private func bootstrapExpect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BootstrapFileFailure.failed(message) }
    print("PASS bootstrap-file \(message)")
}
private struct BootstrapOraclePort: LibraryPersistence {
    func load() async throws -> Data? { nil }
    func commit(_ data: Data) async -> LibraryWriteOutcome { .refused(.io("read-only oracle")) }
}
private actor BootstrapFilePort: LibraryPersistence {
    enum Mode { case normal, before, after, unknownBefore, changed }
    let file: LibrarySessionFile
    let url: URL
    let mode: Mode
    var loads = 0
    var writes = 0
    init(_ url: URL, mode: Mode, limit: Int) {
        self.url = url; self.mode = mode; file = LibrarySessionFile(url: url, maximumBytes: limit)
    }
    func load() async throws -> Data? {
        loads += 1
        let bytes = try await file.load()
        if mode == .changed { try Data("competing destination".utf8).write(to: url) }
        return bytes
    }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        writes += 1
        if mode == .before { return .refused(.io("before replacement")) }
        if mode == .unknownBefore { return .unresolved("before replacement uncertainty") }
        let result = await file.commit(data)
        if mode == .after { return .unresolved("replacement before acknowledgement") }
        return result
    }
}

enum BootstrapFileCases {
    static let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
    static func run(_ directory: URL, fixtureDirectory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["controls-v4.session.json", "filters-v5-library.json", "everyday-v5-library.json"] {
            let originalURL = fixtureDirectory.appendingPathComponent(name)
            let source = try Data(contentsOf: originalURL)
            let sourceKind = name.hasSuffix("session.json") ? LibraryMigrationSource.v1(source) : .schema2(source)
            let url = directory.appendingPathComponent(name + "-target.json")
            let port = BootstrapFilePort(url, mode: .normal, limit: limits.maximumBytes)
            guard case .migrated(let first, let receipt) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: sourceKind) else {
                throw BootstrapFileFailure.failed("initial durable import")
            }
            let bytes = try Data(contentsOf: url), state = try await first.snapshot()
            let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
            try bootstrapExpect(receipt.sourceDigest == digest && receipt.migrationVersion == 3 && !state.unsaved,
                                "\(name) committed import and source digest before return")
            let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            try bootstrapExpect((json["provenance"] as! String).contains(digest) && (json["schema"] as! Int) == 5,
                                "\(name) existing provenance binds digest without schema change")
            let fresh = LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes)
            guard case .existing(let reopened) = await SoundLibrarySession.open(persistence: fresh, limits: limits,
                    migrationSource: .v1(Data("changed malformed source".utf8))) else {
                throw BootstrapFileFailure.failed("existing must ignore changed source")
            }
            try bootstrapExpect(try await reopened.snapshot() == state && Data(contentsOf: url) == bytes,
                                "\(name) new file owner reopens exact identities/values without reimport")
            let loadCount = await port.loads, writeCount = await port.writes
            try bootstrapExpect(loadCount == 1 && writeCount == 1,
                                "\(name) one bootstrap load and commit")
            try bootstrapExpect(try Data(contentsOf: originalURL) == source, "\(name) source bytes unchanged")
            if name.hasSuffix("session.json") {
                let original = try await SoundLibrarySession(persistence: BootstrapOraclePort(), limits: limits,
                                                            migratingV1: source).snapshot()
                try bootstrapExpect(state.definitions == original.definitions && state.assignments.map(\.parts) == original.assignments.map(\.parts),
                                    "v1 exact archived definition IDs/hashes/profiles/native values, no current retune")
                let inPlace = directory.appendingPathComponent("owned-in-place-legacy.json")
                try source.write(to: inPlace)
                guard case .refused = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: inPlace, maximumBytes: limits.maximumBytes), limits: limits, migrationSource: .v1(source)) else {
                    throw BootstrapFileFailure.failed("in-place legacy destination cannot be imported over itself")
                }
                try bootstrapExpect(try Data(contentsOf: inPlace) == source, "owned legacy input cannot be migrated in place")
            }
        }
        let source = try Data(contentsOf: fixtureDirectory.appendingPathComponent("controls-v4.session.json"))
        for mode in [BootstrapFilePort.Mode.before, .after, .unknownBefore, .changed] {
            let url = directory.appendingPathComponent("interruption-\(mode).json")
            let port = BootstrapFilePort(url, mode: mode, limit: limits.maximumBytes)
            let result = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: .v1(source))
            switch mode {
            case .before:
                guard case .refused(.write(.io(_))) = result else { throw BootstrapFileFailure.failed("before-replace refusal") }
                try bootstrapExpect(!FileManager.default.fileExists(atPath: url.path), "before replacement refusal creates no accepted file/session")
            case .unknownBefore:
                guard case .unresolved = result else { throw BootstrapFileFailure.failed("uncertain before replacement") }
                try bootstrapExpect(!FileManager.default.fileExists(atPath: url.path), "uncertain before replacement returns no accepted startup")
            case .after:
                guard case .unresolved = result else { throw BootstrapFileFailure.failed("lost acknowledgement") }
                let bytes = try Data(contentsOf: url)
                guard case .existing(let reopened) = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits, migrationSource: .schema2(Data())) else {
                    throw BootstrapFileFailure.failed("restart after actual replacement")
                }
                let raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let assignments = raw["assignments"] as! [[String: Any]]
                let expected = assignments.map { ($0["id"] as! [String: String])["rawValue"]! }
                try bootstrapExpect(try await reopened.snapshot().assignments.map { $0.id.uuidString } == expected && Data(contentsOf: url) == bytes,
                                    "replacement-before-ack restart preserves first imported IDs/file")
            case .changed:
                guard case .refused(.write(.destinationChanged)) = result else { throw BootstrapFileFailure.failed("changed destination must refuse") }
                try bootstrapExpect(try Data(contentsOf: url) == Data("competing destination".utf8), "changed target after load never overwritten")
            case .normal: throw BootstrapFileFailure.failed("unexpected fixture mode")
            }
            let loadCount = await port.loads, writeCount = await port.writes
            try bootstrapExpect(loadCount == 1 && writeCount == 1, "\(mode) no automatic bootstrap retry or second load")
        }
        let freshURL = directory.appendingPathComponent("fresh.json")
        guard case .fresh(let session) = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: freshURL, maximumBytes: limits.maximumBytes), limits: limits) else {
            throw BootstrapFileFailure.failed("genuinely fresh file")
        }
        let freshState = try await session.snapshot()
        try bootstrapExpect(!FileManager.default.fileExists(atPath: freshURL.path) && freshState.assignments.isEmpty && !freshState.isEnabled,
                            "fresh no-source is unsaved empty/OFF, no source seed")
        _ = try await session.checkpoint()
        guard case .existing(let empty) = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: freshURL, maximumBytes: limits.maximumBytes), limits: limits, migrationSource: .v1(source)) else {
            throw BootstrapFileFailure.failed("existing empty never import/seed")
        }
        try bootstrapExpect(try await empty.snapshot().assignments.isEmpty, "saved empty destination remains empty")
        let emptyBytes = try Data(contentsOf: freshURL)
        var unknown = try JSONSerialization.jsonObject(with: emptyBytes) as! [String: Any]; unknown["schema"] = 99
        for (label, bytes) in [("zero", Data()), ("corrupt", Data("bad".utf8)), ("unsupported", try JSONSerialization.data(withJSONObject: unknown)), ("oversize", Data(repeating: 0, count: limits.maximumBytes + 1))] {
            let url = directory.appendingPathComponent(label + ".json"); try bytes.write(to: url)
            guard case .refused = await SoundLibrarySession.open(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits, migrationSource: .v1(source)) else {
                throw BootstrapFileFailure.failed("\(label) destination fallback")
            }
            try bootstrapExpect(try Data(contentsOf: url) == bytes, "\(label) destination refusal retains bytes, no source fallback")
        }
        let unready = LibrarySessionFile(url: directory.appendingPathComponent("unloaded.json"), maximumBytes: 2)
        try bootstrapExpect(await unready.commit(Data()) == .refused(.notLoaded), "notLoaded is a typed refusal, not no-op")
        _ = try await unready.load()
        try bootstrapExpect(await unready.commit(Data(repeating: 0, count: 3)) == .refused(.byteLimit), "byteLimit is a typed refusal")
    }
}

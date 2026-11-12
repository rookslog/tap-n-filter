import Foundation
import CryptoKit
@testable import SoundModel

actor BootstrapPort: LibraryPersistence {
    enum Mode { case committed, identical, refused(LibraryWriteRefusal), unknownBefore, unknownAfter }
    var data: Data?
    var mode = Mode.committed
    var loads = 0
    var writes = 0
    var submitted: Data?
    var failLoad = false
    init(_ data: Data? = nil) { self.data = data }
    func configure(_ mode: Mode) { self.mode = mode }
    func setLoadFailure(_ failed: Bool = true) { failLoad = failed }
    func load() throws -> Data? {
        loads += 1
        if failLoad { throw LibraryError.invalidArchive }
        return data
    }
    func commit(_ bytes: Data) -> LibraryWriteOutcome {
        writes += 1; submitted = bytes
        switch mode {
        case .committed: data = bytes; return .committed
        case .identical: data = bytes; return .identical
        case .refused(let reason): return .refused(reason)
        case .unknownBefore: return .unresolved("injected before replacement")
        case .unknownAfter: data = bytes; return .unresolved("injected lost acknowledgement")
        }
    }
}
private actor BootstrapCompletion {
    var returned = false
    func finish() { returned = true }
}
private struct IdenticalGatePort: LibraryPersistence {
    let base: PowerGatePort
    func load() async throws -> Data? { await base.load() }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        let result = await base.commit(data)
        return result == .committed ? .identical : result
    }
}
struct LibraryBootstrapCases {
    let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }
    private func savedEmpty() async throws -> Data {
        let port = BootstrapPort()
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        _ = try await session.checkpoint()
        return try requireValue(await port.data)
    }
    func test_existing_fresh_and_refusal() async throws {
        let empty = try await savedEmpty()
        for ignored in [LibraryMigrationSource.v1(Data()), .v1(Data("changed".utf8)), .schema2(Data(repeating: 0, count: limits.maximumBytes + 1))] {
            let port = BootstrapPort(empty)
            guard case .existing(let session) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: ignored) else {
                throw ContractFailure(description: "valid existing destination must win over ignored source")
            }
            let snapshot = try await session.snapshot()
            try requireTrue(snapshot.assignments.isEmpty && !snapshot.isEnabled && !snapshot.unsaved)
            try requireEqual(await port.loads, 1, "canonical existing open loads exactly once")
            try requireEqual(await port.writes, 0)
            try requireEqual(await port.data, empty)
        }
        let port = BootstrapPort()
        guard case .fresh(let fresh) = await SoundLibrarySession.open(persistence: port, limits: limits) else {
            throw ContractFailure(description: "nil/no-source must be fresh")
        }
        let state = try await fresh.snapshot()
        try requireTrue(state.assignments.isEmpty && state.uses.isEmpty && !state.isEnabled && state.unsaved)
        try requireEqual(await port.loads, 1)
        try requireEqual(await port.writes, 0)
        try requireEqual(await port.data, nil)
        var unsupported = try JSONSerialization.jsonObject(with: empty) as! [String: Any]
        unsupported["schema"] = 99
        for bad in [Data(), Data("corrupt".utf8), try JSONSerialization.data(withJSONObject: unsupported), Data(repeating: 0, count: limits.maximumBytes + 1)] {
            let port = BootstrapPort(bad)
            guard case .refused(.destination(_)) = await SoundLibrarySession.open(persistence: port, limits: limits,
                    migrationSource: .v1(try Data(contentsOf: fixtures.appendingPathComponent("controls-v4.session.json")))) else {
                throw ContractFailure(description: "bad destination cannot fall back to import/fresh")
            }
            try requireEqual(await port.data, bad)
            try requireEqual(await port.loads, 1)
            try requireEqual(await port.writes, 0)
        }
        let unavailable = BootstrapPort(); await unavailable.setLoadFailure()
        guard case .refused(.load(_)) = await SoundLibrarySession.open(persistence: unavailable, limits: limits) else {
            throw ContractFailure(description: "load error cannot become missing destination")
        }
        for source in [LibraryMigrationSource.v1(Data()), .schema2(Data("bad".utf8))] {
            let port = BootstrapPort()
            guard case .refused(.source(_)) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: source) else {
                throw ContractFailure(description: "used malformed source must refuse")
            }
            try requireEqual(await port.writes, 0)
        }
    }
    func test_import_commit_and_interruption() async throws {
        let source = try Data(contentsOf: fixtures.appendingPathComponent("controls-v4.session.json"))
        let gate = PowerGatePort(), completion = BootstrapCompletion()
        await gate.arm(.before)
        let opening = Task {
            let result = await SoundLibrarySession.open(persistence: gate, limits: limits, migrationSource: .v1(source))
            await completion.finish()
            return result
        }
        await gate.entered()
        try requireTrue(await !completion.returned, "import cannot publish accepted startup before storage finishes")
        try requireEqual(await gate.data, nil)
        await gate.release()
        guard case .migrated(let committed, _) = await opening.value else { throw ContractFailure(description: "gate release must yield accepted import") }
        try requireTrue(try await !committed.snapshot().unsaved)
        print("PASS bootstrap durable gate forbids startup success before replacement")
        for file in ["controls-v4.session.json", "filters-v5-library.json", "everyday-v5-library.json"] {
            let source = try Data(contentsOf: fixtures.appendingPathComponent(file))
            let v1 = file.hasSuffix("session.json")
            let migration = v1 ? LibraryMigrationSource.v1(source) : .schema2(source)
            let expectedPort = BootstrapPort()
            let expected = try await SoundLibrarySession(persistence: expectedPort, limits: limits,
                migratingV1: v1 ? source : nil, migratingSchema2: v1 ? nil : source).snapshot()
            for mode in [BootstrapPort.Mode.committed, .identical] {
                let port = BootstrapPort(); await port.configure(mode)
                guard case .migrated(let session, let receipt) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: migration) else {
                    throw ContractFailure(description: "committed import must return migrated")
                }
                let state = try await session.snapshot()
                try requireEqual(state.definitions, expected.definitions)
                try requireEqual(state.assignments.map(\.parts), expected.assignments.map(\.parts))
                try requireEqual(state.assignments.map(\.id), expected.assignments.map(\.id))
                try requireEqual(state.assignments.map(\.isEnabled), expected.assignments.map(\.isEnabled))
                if !v1 { try requireEqual(state.uses, expected.uses) }
                try requireEqual(state.isEnabled, expected.isEnabled)
                try requireTrue(!state.unsaved)
                let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
                try requireEqual(receipt.sourceDigest, digest)
                try requireEqual(receipt.sourceFormat, v1 ? .v1 : .schema2)
                try requireEqual(receipt.migrationVersion, 3)
                let bytes = try requireValue(await port.data)
                let archive = try JSONDecoder().decode(LibraryArchive.self, from: bytes)
                try requireTrue(archive.provenance.contains("tnf.bootstrap/3;source=" + (v1 ? "v1" : "schema2") + ";sha256=" + digest))
                try requireEqual(archive.schema, 5)
                if v1 {
                    let original = try JSONDecoder().decode(SoundSessionArchive.self, from: source)
                    try requireEqual(archive.revisions.map(\.definition), original.definitions,
                                     "canonical committed archive retains exact typed definitions")
                }
                try requireEqual(await port.loads, 1)
                try requireEqual(await port.writes, 1)
                guard case .existing(let reopened) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: migration) else {
                    throw ContractFailure(description: "repeated import request must reopen target")
                }
                try requireEqual(try await reopened.snapshot(), state)
                try requireEqual(await port.writes, 1)
                try requireEqual(await port.data, bytes)
                try requireEqual(try Data(contentsOf: fixtures.appendingPathComponent(file)), source)
            }
            for mode in [BootstrapPort.Mode.refused(.destinationChanged), .unknownBefore, .unknownAfter] {
                let port = BootstrapPort(); await port.configure(mode)
                let result = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: migration)
                switch mode {
                case .refused:
                    guard case .refused(.write(.destinationChanged)) = result else { throw ContractFailure(description: "bootstrap refusal needs typed non-success") }
                    try requireEqual(await port.data, nil)
                case .unknownBefore:
                    guard case .unresolved = result else { throw ContractFailure(description: "unknown before replacement must not expose accepted startup") }
                    try requireEqual(await port.data, nil)
                case .unknownAfter:
                    guard case .unresolved = result else { throw ContractFailure(description: "lost acknowledgement must stay uncertain") }
                    let submitted = try requireValue(await port.submitted)
                    let archive = try JSONDecoder().decode(LibraryArchive.self, from: submitted)
                    guard case .existing(let reopened) = await SoundLibrarySession.open(persistence: port, limits: limits, migrationSource: .v1(Data())) else {
                        throw ContractFailure(description: "replacement-before-ack restart opens existing, not reimport")
                    }
                    let restored = try await reopened.snapshot()
                    try requireEqual(restored.assignments.map(\.id), archive.assignments.map { $0.id.rawValue })
                    try requireEqual(restored.assignments.map(\.use), archive.assignments.map { $0.root.rawValue })
                    try requireEqual(await port.data, submitted)
                default: throw ContractFailure(description: "unreachable fixture mode")
                }
                try requireEqual(await port.writes, 1, "no bootstrap retry")
            }
        }
    }
    func test_typed_command_outcomes() async throws {
        let port = BootstrapPort()
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        _ = try await session.checkpoint()
        let writes = await port.writes
        try requireEqual(try await session.checkpoint().outcome, .identical)
        try requireEqual(try await session.select(nil, on: "test.absent").outcome, .identical)
        try requireEqual(try await session.reconcile(), .identical)
        try requireEqual(await port.writes, writes)
        let id = try await session.snapshot().definitions[0].id
        _ = try await session.select(id, on: "test.typed")
        let assignedWrites = await port.writes
        let noChange = try await session.select(id, on: "test.typed")
        try requireEqual(noChange.outcome, .identical)
        try requireTrue(noChange.outcome.isAccepted)
        try requireEqual(await port.writes, assignedWrites)
        let baseline = try await session.snapshot(), bytes = await port.data
        // Diagnostic text deliberately resembles a successful old no-op reason.
        await port.configure(.refused(.io("identical")))
        for operation in ["add", "remove", "name"] {
            let receipt: LibraryCommit
            switch operation {
            case "add": receipt = try await session.select(id, on: "test.new")
            case "remove": receipt = try await session.select(nil, on: "test.typed")
            default: receipt = try await session.nameUse(on: "test.typed", name: "Refused")
            }
            try requireEqual(receipt.outcome, .refused(.io("identical")))
            try requireTrue(!receipt.outcome.isAccepted)
            try requireEqual(try await session.snapshot(), baseline)
            try requireEqual(await port.data, bytes)
        }
        do {
            _ = try await session.createFromUse(on: "test.typed", name: "Refused clone")
            throw ContractFailure(description: "refused clone cannot return accepted ID")
        } catch LibraryError.persistenceRefused(.io("identical")) { }
        try requireEqual(try await session.snapshot(), baseline)
        let control = baseline.uses.first { $0.id == baseline.assignments[0].use }!.controls.last!.id
        try await session.move(control, on: "test.typed", to: .scalar(0.37))
        let refused = try await session.checkpoint()
        let dirty = try await session.snapshot()
        try requireTrue(!refused.outcome.isAccepted && dirty.unsaved)
        try requireEqual(await port.data, bytes)
        await port.configure(.identical)
        let clone = try await session.createFromUse(on: "test.typed", name: "Confirmed identical bytes")
        try requireTrue(try await session.snapshot().definitions.contains { $0.id == clone })
        try requireTrue(LibraryWriteOutcome.identical.isAccepted && LibraryWriteOutcome.committed.isAccepted)
        try requireTrue(!LibraryWriteOutcome.unresolved("identical").isAccepted)
        let gate = PowerGatePort()
        let late = try await SoundLibrarySession(persistence: IdenticalGatePort(base: gate), limits: limits)
        let definition = try await late.snapshot().definitions[0]
        _ = try await late.select(definition.id, on: "test.identical")
        await gate.arm(.before)
        let pending = Task { try await late.nameUse(on: "test.identical", name: "Accepted no-op") }
        await gate.entered()
        try await late.setEnabled(false, on: "test.identical")
        await gate.release()
        try requireEqual(try await pending.value.outcome, .identical)
        let state = try await late.snapshot()
        try requireTrue(!state.assignments[0].isEnabled && state.unsaved)
        try requireEqual(state.uses.first { $0.id == state.assignments[0].use }!.name, "Accepted no-op")
        print("PASS bootstrap late identical acceptance retains app-OFF alone and truthful dirty state")
        await port.configure(.unknownAfter)
        _ = try await session.nameUse(on: "test.typed", name: "Unconfirmed")
        try await session.setEnabled(false, on: "test.typed")
        let stored = await port.data
        await port.setLoadFailure()
        guard case .unresolved = try await session.reconcile() else {
            throw ContractFailure(description: "unavailable readback must stay typed uncertain, not refused/accepted")
        }
        try requireTrue(try await session.snapshot().unresolved)
        try requireEqual(await port.data, stored)
        await port.setLoadFailure(false)
        try requireEqual(try await session.reconcile(), .committed)
        try requireTrue(try await !session.snapshot().assignments[0].isEnabled)
        print("PASS bootstrap unreadable readback retains typed uncertainty and newer app OFF through later acceptance")
    }
}

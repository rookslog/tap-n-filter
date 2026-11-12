import Foundation
import SoundModel
import SessionStore

private enum LibraryCheckFailure: Error { case failed(String) }
private func expect(_ value: Bool, _ message: String) throws {
    guard value else { throw LibraryCheckFailure.failed(message) }
    print("PASS \(message)")
}

actor GatedLibraryPort: LibraryPersistence {
    enum Mode { case pass, before, after, failed, uncertainWrite, uncertainNoWrite }
    let file: LibrarySessionFile
    var mode = Mode.pass
    var entered = false
    var enterWaiters: [CheckedContinuation<Void, Never>] = []
    var releaseWaiter: CheckedContinuation<Void, Never>?
    var writes = 0
    init(file: LibrarySessionFile) { self.file = file }
    func load() async throws -> Data? { try await file.load() }
    func set(_ value: Mode) { mode = value; entered = false }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enterWaiters.append($0) }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
    func pause() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation; entered = true
            for waiter in enterWaiters { waiter.resume() }; enterWaiters.removeAll()
        }
    }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        writes += 1
        let selected = mode
        if selected == .before { await pause() }
        if selected == .failed { await pause(); return .refused(.io("injected before replacement")) }
        if selected == .uncertainNoWrite { await pause(); return .unresolved("injected uncertain unchanged") }
        let result = await file.commit(data)
        if selected == .after || selected == .uncertainWrite { await pause() }
        if selected == .uncertainWrite { return .unresolved("injected acknowledgement loss after replacement") }
        return result
    }
}

enum LibraryFileCases {
    static let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)

    static func run(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await roundtrip(directory)
        try await retention(directory)
        try await scheduling(directory)
        try await fileBoundaries(directory)
        try await criticalBoundaries(directory)
        try await LinkedFileCases.run(in: directory)
    }
    static func roundtrip(_ directory: URL) async throws {
        for builtin in ["Everyday", "Filters"] {
            let url = directory.appendingPathComponent("\(builtin).json")
            let session = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            let initial = try await session.snapshot()
            let definition = initial.definitions.first { $0.name == builtin }!
            _ = try await session.select(definition.id, on: "test.player")
            for (index, control) in definition.controls.enumerated() {
                try await session.move(control.id, on: "test.player", to: .scalar(0.23 + Double(index) * 0.09))
            }
            let before = try await session.snapshot()
            let original = try Data(contentsOf: url)
            let customID = try await session.createFromUse(on: "test.player", name: "My \(builtin)")
            let created = try await session.snapshot()
            let custom = created.definitions.first { $0.id == customID }!
            try expect(custom.origin == "custom" && custom.profile == definition.profile && custom.id != definition.id,
                       "\(builtin) public clone has honest identity and explicit native profile")
            let beforeUse = before.uses.first { $0.id == before.assignments[0].use }!
            let createdUse = created.uses.first { $0.id == created.assignments[0].use }!
            try expect(createdUse.positions == beforeUse.positions,
                       "\(builtin) clone stores the exact starting control positions, not just equivalent output")
            try expect(created.assignments[0].parts == before.assignments[0].parts,
                       "\(builtin) clone preserves exact non-neutral native output")
            try expect(custom.controls == definition.controls && custom.contentHash.count == 64,
                       "\(builtin) authored faces, OptionIDs and first SHA256 revision preserved")
            _ = try await session.checkpoint()
            let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            let restored = try await reopened.snapshot()
            try expect(restored == (try await session.snapshot()), "\(builtin) real isolated file reopens through fresh public owner")
            try expect(try Data(contentsOf: url) != original, "\(builtin) clone actually changed stored file bytes")
            let customUse = restored.uses.first { $0.id == restored.assignments[0].use }!
            _ = try await reopened.select(nil, on: "test.player")
            _ = try await reopened.select(customID, on: "test.player")
            let again = try await reopened.snapshot()
            try expect(again.assignments[0].use == customUse.id && again.assignments[0].parts == restored.assignments[0].parts,
                       "\(builtin) None detaches without deleting owned custom use or memory")
            print("INFO \(builtin) archive \((try Data(contentsOf: url)).count) bytes; not a capacity or latency claim")
        }
    }
    static func retention(_ directory: URL) async throws {
        let url = directory.appendingPathComponent("retention.json")
        let session = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let definitions = try await session.snapshot().definitions
        for (t, target) in ["test.one", "test.two"].enumerated() {
            for (d, definition) in definitions.enumerated() {
                _ = try await session.select(definition.id, on: target)
                let control = definition.controls.last!
                try await session.move(control.id, on: target, to: .scalar(0.11 + Double(t) * 0.5 + Double(d) * 0.1))
                _ = try await session.nameUse(on: target, name: "\(target)-\(definition.name)")
                _ = try await session.renameControl(on: target, control: control.id, title: "Local \(target)")
            }
        }
        let before = try await session.snapshot()
        let savedOrder = before.assignments.map(\.id)
        _ = try await session.select(definitions[1].id, on: "test.one")
        try expect(try await session.snapshot().assignments.map(\.id) == savedOrder,
                   "same block selection preserves original added order and binding IDs")
        _ = try await session.select(nil, on: "test.one")
        _ = try await session.select(nil, on: "test.two")
        let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let inactive = try await fresh.snapshot()
        try expect(inactive.uses == before.uses && inactive.assignments.isEmpty,
                   "two targets x two blocks retain inactive owned identity, local draft, base, name and memory on disk")
        for target in ["test.one", "test.two"] {
            for definition in definitions {
                _ = try await fresh.select(definition.id, on: target)
                let state = try await fresh.snapshot()
                let binding = state.assignments.first { $0.target == target }!
                let use = state.uses.first { $0.id == binding.use }!
                let old = before.uses.first { $0.target == target && $0.definition == definition.id }!
                try expect(use == old, "\(target)/\(definition.name) restores its own local state without cross-target leakage")
            }
        }
        let tight = try LibraryLimits(maximumBytes: 32, maximumRevisions: 128)
        let saved = try Data(contentsOf: url)
        do {
            _ = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: tight)
            throw LibraryCheckFailure.failed("tight archive bytes should refuse")
        } catch LibraryError.limitExceeded { }
        try expect(try Data(contentsOf: url) == saved, "tight reload limit refuses without pruning protected state")
        let bounded = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes),
            limits: LibraryLimits(maximumBytes: saved.count + 16, maximumRevisions: 128))
        do {
            _ = try await bounded.nameUse(on: "test.two", name: String(repeating: "large", count: 1000))
            throw LibraryCheckFailure.failed("oversize durable candidate should refuse")
        } catch LibraryError.limitExceeded { }
        try expect(try Data(contentsOf: url) == saved, "oversize authored candidate refuses before replacing existing archive")
    }
    static func scheduling(_ directory: URL) async throws {
        for mode in [GatedLibraryPort.Mode.before, .failed, .uncertainWrite, .uncertainNoWrite, .after] {
            let url = directory.appendingPathComponent("schedule-\(String(describing: mode)).json")
            let port = GatedLibraryPort(file: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
            let session = try await SoundLibrarySession(persistence: port, limits: limits)
            let definition = try await session.snapshot().definitions[0]
            _ = try await session.select(definition.id, on: "test.player")
            let control = definition.controls.last!.id
            await session.setEnabled(true)
            try await session.move(control, on: "test.player", to: .scalar(0.3))
            _ = try await session.checkpoint()
            let committedBefore = try Data(contentsOf: url)
            await port.set(mode)
            let operation = Task { try await session.createFromUse(on: "test.player", name: "While writing") }
            await port.waitUntilEntered()
            try await session.move(control, on: "test.player", to: .scalar(0.71))
            await session.setEnabled(false)
            await session.compareOriginal(true)
            let live = try await session.snapshot()
            try expect(!live.isEnabled && live.compareOriginal && live.writing,
                       "\(mode) actual owner handles move/compare/OFF while real store response suspended")
            if mode == .after { operation.cancel() }
            await port.release()
            do { _ = try await operation.value }
            catch LibraryError.persistenceRefused { }
            catch LibraryError.durableStateUnresolved { }
            let result = try await session.snapshot()
            try expect(result.definitions.count == ((mode == .before || mode == .after) ? 3 : 2),
                       "\(mode) authored acceptance follows confirmed durability only")
            let use = result.uses.first { $0.id == result.assignments[0].use }!
            try expect(!result.isEnabled && use.positions[control] == .scalar(0.71) && result.unsaved,
                       "\(mode) late result cannot undo newer position/OFF; unsaved live state explicit")
            if mode == .uncertainWrite || mode == .uncertainNoWrite {
                do {
                    _ = try await session.nameUse(on: "test.player", name: "blocked")
                    throw LibraryCheckFailure.failed("unresolved durable command must refuse")
                } catch LibraryError.durableStateUnresolved { }
                try await session.move(control, on: "test.player", to: .scalar(0.72))
                await session.setEnabled(false)
                if mode == .uncertainNoWrite {
                    let foreign = Data("unknown replacement".utf8)
                    try foreign.write(to: url)
                    let unresolved = try await session.reconcile()
                    try expect(unresolved == .unresolved("readback matches neither candidate nor previous committed bytes"),
                               "unknown actual readback stays unresolved instead of accepting/truncating")
                    try expect(try Data(contentsOf: url) == foreign, "unresolved reconciliation does not rewrite differing bytes")
                    try committedBefore.write(to: url)
                }
                let resolution = try await session.reconcile()
                try expect(resolution == (mode == .uncertainWrite ? .committed : .refused(.previousRetained)),
                           "\(mode) actual file readback reconciles committed versus unchanged")
                let reconciled = try await session.snapshot()
                try expect(!reconciled.unresolved && !reconciled.isEnabled,
                           "\(mode) reconciliation preserves live OFF")
            }
            await port.set(.pass)
            _ = try await session.checkpoint()
            let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            let disk = try await reopened.snapshot()
            let now = try await session.snapshot()
            try expect(disk.assignments == now.assignments && disk.uses == now.uses && !disk.isEnabled,
                       "\(mode) explicit checkpoint durably flushes latest retained memory")
        }
        let url = directory.appendingPathComponent("coalesce.json")
        let port = GatedLibraryPort(file: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        _ = try await session.select((try await session.snapshot()).definitions[0].id, on: "test.player")
        let control = try await session.snapshot().definitions[0].controls.last!.id
        await port.set(.before)
        try await session.move(control, on: "test.player", to: .scalar(0.4))
        let first = Task { try await session.checkpoint() }
        await port.waitUntilEntered()
        let writes = await port.writes
        let second = Task { try await session.checkpoint() }
        await port.release()
        _ = try await first.value; _ = try await second.value
        try expect(await port.writes == writes, "concurrent identical memory checkpoints coalesce to one replacement")
        await port.set(.before)
        try await session.move(control, on: "test.player", to: .scalar(0.51))
        let older = Task { try await session.checkpoint() }
        await port.waitUntilEntered()
        try await session.move(control, on: "test.player", to: .scalar(0.81))
        let newer = Task { try await session.checkpoint() }
        await port.set(.pass); await port.release()
        _ = try await older.value; _ = try await newer.value
        let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let restored = try await fresh.snapshot()
        try expect(restored.uses[0].positions[control] == .scalar(0.81) && !restored.unsaved,
                   "checkpoint waiting behind an older write flushes the newer live memory")
    }
    static func fileBoundaries(_ directory: URL) async throws {
        let url = directory.appendingPathComponent("changed-destination.json")
        let port = LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes)
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        let foreign = Data("do not overwrite".utf8)
        try foreign.write(to: url)
        let receipt = try await session.checkpoint()
        try expect(receipt.outcome == .refused(.destinationChanged) && (try Data(contentsOf: url)) == foreign,
                   "different destination after known absence is never overwritten")
        do {
            _ = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            throw LibraryCheckFailure.failed("corrupt file should refuse")
        } catch is DecodingError { }
        try expect(try Data(contentsOf: url) == foreign, "corrupt existing destination refuses without reset")
        let valid = directory.appendingPathComponent("Everyday.json")
        let data = try Data(contentsOf: valid)
        let same = LibrarySessionFile(url: valid, maximumBytes: limits.maximumBytes)
        _ = try await same.load()
        try expect(await same.commit(data) == .identical, "identical existing destination is an accepted no-op")
    }
    static func criticalBoundaries(_ directory: URL) async throws {
        let url = directory.appendingPathComponent("exact-cap.json")
        let first = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let definition = try await first.snapshot().definitions[0]
        _ = try await first.select(definition.id, on: "test.exact-cap")
        let control = definition.controls.last!.id
        try await first.move(control, on: "test.exact-cap", to: .scalar(0.3))
        await first.setEnabled(true)
        _ = try await first.checkpoint()
        let baseline = try Data(contentsOf: url)
        let cap = try LibraryLimits(maximumBytes: baseline.count, maximumRevisions: limits.maximumRevisions)
        let session = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: cap)
        try expect(!(try await session.snapshot()).unsaved, "exact-cap unchanged snapshot remains saved")
        try expect(try await session.checkpoint().outcome == .identical, "exact-cap identical checkpoint remains a no-op")
        await session.setEnabled(false)
        let off = try await session.snapshot()
        try expect(!off.isEnabled && off.unsaved, "exact-cap OFF snapshot is observable and honestly unsaved")
        do {
            _ = try await session.checkpoint()
            throw LibraryCheckFailure.failed("over-cap OFF checkpoint must refuse")
        } catch LibraryError.limitExceeded { }
        try expect(try Data(contentsOf: url) == baseline, "over-cap OFF checkpoint preserves committed bytes")
        await session.setEnabled(true)
        try await session.move(control, on: "test.exact-cap", to: .scalar(0.711))
        let moved = try await session.snapshot()
        let use = moved.uses.first { $0.id == moved.assignments[0].use }!
        try expect(use.positions[control] == .scalar(0.711) && moved.unsaved,
                   "over-budget movement remains observable without clamping")
        do {
            _ = try await session.checkpoint()
            throw LibraryCheckFailure.failed("over-cap move checkpoint must refuse")
        } catch LibraryError.limitExceeded { }
        try expect(try Data(contentsOf: url) == baseline, "over-cap move checkpoint preserves committed bytes")

        let valid = try Data(contentsOf: directory.appendingPathComponent("retention.json"))
        enum Step { case key(String), index(Int) }
        func adding(_ value: Any, path: ArraySlice<Step>, field: String) -> Any {
            guard let step = path.first else {
                var record = value as! [String: Any]; record[field] = ["required": true]; return record
            }
            switch step {
            case .key(let name):
                var record = value as! [String: Any]
                record[name] = adding(record[name]!, path: path.dropFirst(), field: field); return record
            case .index(let index):
                var array = value as! [Any]
                array[index] = adding(array[index], path: path.dropFirst(), field: field); return array
            }
        }
        let revision: [Step] = [.key("revisions"), .index(0)]
        let owned: [Step] = [.key("uses"), .index(0)]
        let draft = owned + [.key("draft")]
        let presentation = draft + [.key("presentation"), .index(0)]
        let block = draft + [.key("block")]
        let cases: [(String, [Step], String)] = [
            ("revision-mark", revision, "mark"),
            ("revision-future", revision, "futureSemantic"),
            ("definition", revision + [.key("definition")], "futureSemantic"),
            ("head", [.key("definitions"), .index(0)], "futureSemantic"),
            ("owned", owned, "futureSemantic"),
            ("use", owned + [.key("use")], "futureSemantic"),
            ("base", owned + [.key("use"), .key("definition")], "futureSemantic"),
            ("use-name", owned + [.key("use"), .key("name"), .key("own")], "futureSemantic"),
            ("draft", draft, "futureSemantic"),
            ("draft-block", block, "futureSemantic"),
            ("presentation", presentation, "futureSemantic"),
            ("option", presentation + [.key("face"), .key("choice"), .key("_0"), .index(0)], "futureSemantic"),
            ("position", owned + [.key("positions"), .index(0)], "futureSemantic"),
            ("assignment", [.key("assignments"), .index(0)], "futureSemantic"),
            ("curve-segment", block + [.key("mappings"), .index(0), .key("curve"), .key("segments"), .index(0)], "futureSemantic"),
        ]
        for (name, path, field) in cases {
            let changed = adding(try JSONSerialization.jsonObject(with: valid), path: path[...], field: field)
            let bytes = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys])
            let destination = directory.appendingPathComponent("unsupported-\(name).json")
            try bytes.write(to: destination)
            var refused = false
            do {
                let admitted = try await SoundLibrarySession(persistence: LibrarySessionFile(url: destination, maximumBytes: limits.maximumBytes), limits: limits)
                _ = try await admitted.checkpoint()
            } catch LibraryError.unsupportedFormat { refused = true }
            try expect(refused && (try Data(contentsOf: destination)) == bytes,
                       "unsupported \(name) refuses through public facade/store without replacing bytes")
        }
    }

}

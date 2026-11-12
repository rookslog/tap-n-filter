import Foundation
import SoundModel
import SessionStore

private enum LinkedFailure: Error { case failed(String) }
private func linkedCheck(_ value: Bool, _ message: String) throws {
    guard value else { throw LinkedFailure.failed(message) }; print("PASS \(message)")
}

private actor LinkedGate: LibraryPersistence {
    let file: LibrarySessionFile
    var hold = false
    var waiter: CheckedContinuation<Void, Never>?
    var entered: CheckedContinuation<Void, Never>?
    var isEntered = false
    init(_ file: LibrarySessionFile) { self.file = file }
    func load() async throws -> Data? { try await file.load() }
    func arm() { hold = true; isEntered = false }
    func wait() async { if !isEntered { await withCheckedContinuation { entered = $0 } } }
    func release() { hold = false; waiter?.resume(); waiter = nil }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        if hold {
            await withCheckedContinuation { waiter = $0; isEntered = true; entered?.resume(); entered = nil }
        }
        return await file.commit(data)
    }
}

enum LinkedFileCases {
    static let expansion = try! LibraryExpansionLimits(maximumDepth: 16, maximumOccurrences: 128, maximumParts: 128)
    static let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128, expansion: expansion)
    static func run(in directory: URL) async throws {
        let url = directory.appendingPathComponent("linked.json")
        let gate = LinkedGate(LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
        let session = try await SoundLibrarySession(persistence: gate, limits: limits)
        let builtins = try await session.snapshot().definitions
        let everyday = builtins.first { $0.name == "Everyday" }!, filters = builtins.first { $0.name == "Filters" }!
        _ = try await session.select(filters.id, on: "test.source")
        let volume = filters.controls.first { $0.title == "Volume" }!.id
        try await session.move(volume, on: "test.source", to: .scalar(0.5))
        let captured = try await session.createFromUse(on: "test.source", name: "Captured Filters")
        let snapshot = try await session.snapshot()
        let capturedDef = snapshot.definitions.first { $0.id == captured }!
        let children = [LibraryReference(definition: everyday.id, revision: everyday.revision),
                        LibraryReference(definition: capturedDef.id, revision: capturedDef.revision),
                        LibraryReference(definition: capturedDef.id, revision: capturedDef.revision)]
        let parent = try await session.createLinkedBlock(name: "Layered", children: children, on: "test.one")
        _ = try await session.select(parent, on: "test.two")
        var state = try await session.snapshot()
        let first = state.uses.first { $0.target == "test.one" && $0.definition == parent }!
        let childOccurrences = first.occurrences.filter { !$0.path.isEmpty }
        try linkedCheck(childOccurrences.count == 3 && Set(childOccurrences.map(\.path)).count == 3,
                        "public linked parent exposes three distinct exact child occurrences")
        let filterA = childOccurrences[1], filterB = childOccurrences[2]
        let address = LibraryControlAddress(path: filterA.path, control: volume)
        func gain(_ state: LibrarySnapshot, _ target: String, _ path: [UUID]) -> Double {
            state.assignments.first { $0.target == target }!.parts.first { $0.path == path && $0.type == "gain" }!.parameters.first { $0.key == "gainDb" }!.value
        }
        try linkedCheck(abs(gain(state, "test.one", filterA.path) + 9) < 1e-10,
                        "linked mixed-profile Filters remains -9 dB, not old parent-only -45 dB")
        let attack = state.assignments.first { $0.target == "test.one" }!.parts.first { $0.path == filterA.path && $0.type == "dynamics" }!.parameters.first { $0.key == "attackSeconds" }!.value
        try linkedCheck(abs(attack - 0.080) < 1e-12, "fresh revision6 linked Filters retains its 80ms attack")
        try await session.move(address, on: "test.one", to: .scalar(0.3))
        state = try await session.snapshot()
        try linkedCheck(abs(gain(state, "test.one", filterA.path) + 15) < 1e-10 && abs(gain(state, "test.one", filterB.path) + 9) < 1e-10 && abs(gain(state, "test.two", filterA.path) + 9) < 1e-10,
                        "one child move leaves repeated sibling and second target independent")
        _ = try await session.nameUse(on: "test.one", name: "Local Layer")
        _ = try await session.checkpoint()
        let originalBytes = try Data(contentsOf: url)
        await gate.arm()
        let cloning = Task { try await session.createFromUse(on: "test.one", name: "Layer capture") }
        await gate.wait()
        try await session.move(address, on: "test.one", to: .scalar(0.7))
        await session.setEnabled(false); await session.compareOriginal(true)
        try linkedCheck(!(try await session.snapshot()).isEnabled, "child move/OFF stay responsive during linked clone persistence")
        await gate.release()
        let clone = try await cloning.value
        let current = try await session.snapshot()
        try linkedCheck(current.unsaved && abs(gain(current, "test.one", filterA.path) + 3) < 1e-10,
                        "late linked clone receipt retains newer child listening value as unsaved")
        let disk = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let saved = try await disk.snapshot()
        try linkedCheck(abs(gain(saved, "test.one", filterA.path) + 15) < 1e-10,
                        "linked clone authored start captures invocation value, not later move")
        let cloneUse = saved.uses.first { $0.definition == clone }!
        try linkedCheck(cloneUse.occurrences[3].positions[volume] == .scalar(0.5), "untouched repeated child retains its own starting value")
        _ = try await session.checkpoint()
        _ = try await session.select(nil, on: "test.one")
        _ = try await session.select(clone, on: "test.one")
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let restored = try await reopened.snapshot()
        try linkedCheck(restored.assignments == (try await session.snapshot()).assignments,
                        "qualified memory and exact native ordering survive None/switch/real reopen")
        let beforeUnknown = try Data(contentsOf: url)
        do {
            _ = try await session.createLinkedBlock(name: "missing", children: [LibraryReference(definition: UUID(), revision: UUID())], on: "test.one")
            throw LinkedFailure.failed("missing reference should refuse")
        } catch LibraryError.missingReference { }
        try linkedCheck(try Data(contentsOf: url) == beforeUnknown, "missing exact child refuses atomically with unchanged file")
        try linkedCheck(try Data(contentsOf: url) != originalBytes, "linked actual file path persisted state, not a decoder-only roundtrip")
        try await archivedV5(in: directory)
        try await faults(in: directory)
        try await exactCap(in: directory)
    }
    static func archivedV5(in directory: URL) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SoundModelTests/Fixtures/filters-v5-library.json")
        let bytes = try Data(contentsOf: fixture)
        let file = LibrarySessionFile(url: directory.appendingPathComponent("mixed-archived-v5.json"), maximumBytes: limits.maximumBytes)
        let model = try await SoundLibrarySession(persistence: file, limits: limits, migratingSchema2: bytes)
        let definitions = try await model.snapshot().definitions
        let filters = definitions.first { $0.name == "Filters" }!, everyday = definitions.first { $0.name == "Everyday" }!
        let volume = filters.controls.first { $0.title == "Volume" }!.id
        try await model.move(volume, on: "synthetic.unit22", to: .scalar(0.5))
        let captured = try await model.createFromUse(on: "synthetic.unit22", name: "Archived Filters")
        let definition = try await model.snapshot().definitions.first { $0.id == captured }!
        _ = try await model.createLinkedBlock(name: "Mixed archived", children: [
            LibraryReference(definition: everyday.id, revision: everyday.revision),
            LibraryReference(definition: captured, revision: definition.revision),
            LibraryReference(definition: captured, revision: definition.revision)], on: "test.archived")
        let snapshot = try await model.snapshot(), parts = snapshot.assignments.first { $0.target == "test.archived" }!.parts
        let use = snapshot.uses.first { $0.target == "test.archived" }!, paths = Array(use.occurrences.dropFirst()).dropFirst().map(\.path)
        for path in paths {
            let dynamics = parts.first { $0.path == path && $0.type == "dynamics" }!
            let values = Dictionary(uniqueKeysWithValues: dynamics.parameters.map { ($0.key, $0.value) })
            try linkedCheck(abs(values["attackSeconds"]! - 0.012) < 1e-12 && abs(values["releaseSeconds"]! - 0.320) < 1e-12 && abs(values["thresholdDb"]! + 17) < 1e-10,
                            "archived v5 repeated mixed-profile child keeps 12/320ms and -17dB")
            let gain = parts.first { $0.path == path && $0.type == "gain" }!.parameters.first { $0.key == "gainDb" }!.value
            try linkedCheck(abs(gain + 9) < 1e-10, "archived v5 mixed-profile gain remains -9, not -45dB")
        }
        _ = try await model.checkpoint()
        let reopened = try await SoundLibrarySession(persistence: file, limits: limits)
        try linkedCheck(try await reopened.snapshot().assignments == snapshot.assignments, "archived v5 mixed-profile actual file reopens unchanged")
        try linkedCheck(try Data(contentsOf: fixture) == bytes, "consumed archived v5 fixture unchanged")
    }
    static func faults(in directory: URL) async throws {
        for mode in [GatedLibraryPort.Mode.before, .failed, .uncertainWrite, .uncertainNoWrite, .after] {
            let url = directory.appendingPathComponent("linked-fault-\(mode).json")
            let port = GatedLibraryPort(file: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
            let model = try await SoundLibrarySession(persistence: port, limits: limits)
            let builtins = try await model.snapshot().definitions
            let filter = builtins.first { $0.name == "Filters" }!, everyday = builtins.first { $0.name == "Everyday" }!
            let volume = filter.controls.first { $0.title == "Volume" }!.id
            let rootVolume = everyday.controls.last!.id
            _ = try await model.createLinkedBlock(name: "Linked", children: [LibraryReference(definition: filter.id, revision: filter.revision)], on: "test.child")
            _ = try await model.select(everyday.id, on: "test.root")
            let use = try await model.snapshot().uses.first { $0.target == "test.child" }!
            let path = use.occurrences[1].path
            let address = LibraryControlAddress(path: path, control: volume)
            try await model.move(address, on: "test.child", to: .scalar(0.3)); await model.setEnabled(true)
            _ = try await model.checkpoint(); let baseline = try Data(contentsOf: url)
            await port.set(mode)
            let operation = Task { try await model.createFromUse(on: "test.child", name: "Captured child") }
            await port.waitUntilEntered()
            try await model.move(address, on: "test.child", to: .scalar(0.7))
            try await model.move(rootVolume, on: "test.root", to: .scalar(0.25))
            await model.setEnabled(false); await model.compareOriginal(true)
            let suspended = try await model.snapshot()
            try linkedCheck(suspended.writing && !suspended.isEnabled && suspended.compareOriginal,
                            "linked \(mode) root/child/OFF/compare available during suspended store")
            if mode == .after { operation.cancel() }
            await port.release()
            do { _ = try await operation.value } catch LibraryError.persistenceRefused { } catch LibraryError.durableStateUnresolved { }
            if mode == .failed { try linkedCheck(try Data(contentsOf: url) == baseline, "failed child clone preserves exact committed bytes") }
            if mode == .uncertainWrite || mode == .uncertainNoWrite {
                do { _ = try await model.nameUse(on: "test.child", name: "blocked"); throw LinkedFailure.failed("uncertain durable mutation accepted") }
                catch LibraryError.durableStateUnresolved { }
                try await model.move(address, on: "test.child", to: .scalar(0.7)); await model.setEnabled(false)
                _ = try await model.reconcile()
            }
            let state = try await model.snapshot()
            let childBinding = state.assignments.first { $0.target == "test.child" }!
            let childUse = state.uses.first { $0.id == childBinding.use }!
            let rootUse = state.uses.first { $0.target == "test.root" }!
            try linkedCheck(!state.isEnabled && state.unsaved && childUse.occurrences[1].positions[volume] == .scalar(0.7) && rootUse.positions[rootVolume] == .scalar(0.25),
                            "linked \(mode) late/cancel/reconciled result preserves full newer qualified state")
            await port.set(.pass); _ = try await model.checkpoint()
            let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
            try linkedCheck(try await reopened.snapshot().uses == model.snapshot().uses,
                            "linked \(mode) latest child/root memory durably reopens")
        }
        let url = directory.appendingPathComponent("linked-coalesce.json")
        let port = GatedLibraryPort(file: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes))
        let model = try await SoundLibrarySession(persistence: port, limits: limits)
        let filter = try await model.snapshot().definitions.first { $0.name == "Filters" }!
        let volume = filter.controls.first { $0.title == "Volume" }!.id
        _ = try await model.createLinkedBlock(name: "Linked", children: [LibraryReference(definition: filter.id, revision: filter.revision)], on: "test.child")
        let path = try await model.snapshot().uses[0].occurrences[1].path
        let address = LibraryControlAddress(path: path, control: volume)
        try await model.move(address, on: "test.child", to: .scalar(0.4)); await port.set(.before)
        let old = Task { try await model.checkpoint() }; await port.waitUntilEntered()
        try await model.move(address, on: "test.child", to: .scalar(0.8))
        let next = Task { try await model.checkpoint() }
        await port.set(.pass); await port.release(); _ = try await old.value; _ = try await next.value
        let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        try linkedCheck(try await fresh.snapshot().uses[0].occurrences[1].positions[volume] == .scalar(0.8),
                        "child checkpoint waiting behind older save flushes newest memory")
    }
    static func exactCap(in directory: URL) async throws {
        let url = directory.appendingPathComponent("linked-cap.json")
        let first = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: limits)
        let filter = try await first.snapshot().definitions.first { $0.name == "Filters" }!
        let volume = filter.controls.first { $0.title == "Volume" }!.id
        _ = try await first.createLinkedBlock(name: "Cap", children: [LibraryReference(definition: filter.id, revision: filter.revision)], on: "test.cap")
        let path = try await first.snapshot().uses[0].occurrences[1].path
        let address = LibraryControlAddress(path: path, control: volume)
        try await first.move(address, on: "test.cap", to: .scalar(0.3)); await first.setEnabled(true)
        _ = try await first.checkpoint(); let before = try Data(contentsOf: url)
        let cap = try LibraryLimits(maximumBytes: before.count, maximumRevisions: 128, expansion: expansion)
        let model = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: limits.maximumBytes), limits: cap)
        await model.setEnabled(false); try await model.move(address, on: "test.cap", to: .scalar(0.711))
        let state = try await model.snapshot()
        try linkedCheck(!state.isEnabled && state.unsaved && state.uses[0].occurrences[1].positions[volume] == .scalar(0.711),
                        "exact-cap child movement and OFF remain observable")
        do { _ = try await model.checkpoint(); throw LinkedFailure.failed("over-cap child checkpoint accepted") }
        catch LibraryError.limitExceeded { }
        try linkedCheck(try Data(contentsOf: url) == before, "over-cap child memory checkpoint leaves committed bytes unchanged")
    }
}

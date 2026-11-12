import Foundation
@testable import SoundModel

actor PowerGatePort: LibraryPersistence {
    enum Mode: CaseIterable { case pass, before, after, unchanged, candidate, old, neither }
    var data: Data?
    var writes = 0
    var mode = Mode.pass
    var pendingData: Data?
    var releaseWaiter: CheckedContinuation<Void, Never>?
    var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func load() -> Data? { data }
    func replaceReadback(_ data: Data?) { self.data = data }
    func arm(_ mode: Mode) { self.mode = mode }
    func entered() async {
        if releaseWaiter != nil { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        mode = .pass
        releaseWaiter?.resume(); releaseWaiter = nil
    }
    private func pause() async {
        await withCheckedContinuation { c in
            releaseWaiter = c
            for w in entryWaiters { w.resume() }; entryWaiters.removeAll()
        }
    }
    func commit(_ bytes: Data) async -> LibraryWriteOutcome {
        writes += 1; pendingData = bytes
        let selected = mode
        if selected == .pass { data = bytes; return .committed }
        if selected == .after || selected == .candidate { data = bytes }
        if selected == .neither { data = Data("foreign unconfirmed bytes".utf8) }
        await pause()
        switch selected {
        case .pass, .after: return .committed
        case .before: data = bytes; return .committed
        case .unchanged: return .refused(.io("injected unchanged"))
        case .candidate, .old, .neither: return .unresolved("injected uncertain replacement")
        }
    }
}

struct LibraryPowerCases {
    let limits = try! LibraryLimits(maximumBytes: 4_000_000, maximumRevisions: 128)
    let a = "test.power.a", b = "test.power.b"

    private func assignment(_ snapshot: LibrarySnapshot, _ target: String) throws -> LibraryAssignmentSummary {
        try requireValue(snapshot.assignments.first { $0.target == target })
    }
    private func setup() async throws -> (SoundLibrarySession, PowerGatePort, LibrarySnapshot) {
        let port = PowerGatePort()
        let session = try await SoundLibrarySession(persistence: port, limits: limits)
        let definitions = try await session.snapshot().definitions
        _ = try await session.select(definitions.first { $0.name == "Everyday" }!.id, on: a)
        _ = try await session.select(definitions.first { $0.name == "Filters" }!.id, on: b)
        await session.setEnabled(true)
        _ = try await session.checkpoint()
        return (session, port, try await session.snapshot())
    }
    func test_power_setter_and_restart() async throws {
        let (session, port, initial) = try await setup()
        let bytes = await port.data, count = await port.writes
        try await session.setEnabled(false, on: a)
        let off = try await session.snapshot()
        try requireTrue(!assignment(off, a).isEnabled && off.isEnabled && off.unsaved)
        try requireEqual(assignment(off, b), assignment(initial, b), "A power never changes B")
        try requireEqual(off.uses, initial.uses)
        try requireEqual(off.definitions, initial.definitions)
        try requireEqual(await port.data, bytes, "live OFF is not a durable write")
        try await session.setEnabled(false, on: a)
        try requireEqual(try await session.snapshot(), off, "equal flag is a no-op")
        try await session.setEnabled(true, on: a)
        try requireEqual(try await session.snapshot(), initial, "ON restores clean desired state")
        try requireEqual(await port.writes, count)
        for target in ["test.unknown", a] {
            if target == a { _ = try await session.select(nil, on: a) }
            let before = try await session.snapshot(), writes = await port.writes
            do {
                try await session.setEnabled(false, on: target)
                throw ContractFailure(description: "unknown/unassigned target accepted")
            } catch LibraryError.unknownTarget { }
            try requireEqual(try await session.snapshot(), before)
            try requireEqual(await port.writes, writes)
        }
        do {
            try await session.setEnabled(false, on: "invalid target")
            throw ContractFailure(description: "invalid app key accepted")
        } catch DocumentError.invalidApplicationKey { }
        _ = try await session.select(initial.definitions.first { $0.name == "Everyday" }!.id, on: a)
        try await session.setEnabled(false, on: a)
        _ = try await session.checkpoint()
        let fresh = try await SoundLibrarySession(persistence: port, limits: limits)
        try requireEqual(try await fresh.snapshot(), try await session.snapshot())
        try requireTrue(!assignment(try await fresh.snapshot(), a).isEnabled)
        try requireEqual(try await fresh.snapshot().definitions, initial.definitions)
    }

    func test_suspended_writes_and_reconciliation() async throws {
        for operation in ["checkpoint", "selection", "name"] {
            for mode in PowerGatePort.Mode.allCases where mode != .pass {
                let (session, port, initial) = try await setup()
                let oldBytes = await port.data
                let oldArchive = try JSONDecoder().decode(LibraryArchive.self, from: oldBytes!)
                let binding = try assignment(initial, a)
                let use = try requireValue(initial.uses.first { $0.id == binding.use })
                let control = use.controls.last!.id
                if operation == "checkpoint" { try await session.move(control, on: a, to: .scalar(0.31)) }
                await port.arm(mode)
                let pending = Task {
                    switch operation {
                    case "selection": return try await session.select(initial.definitions.first { $0.name == "Filters" }!.id, on: a)
                    case "name": return try await session.nameUse(on: a, name: "During write")
                    default: return try await session.checkpoint()
                    }
                }
                await port.entered()
                let submitted = await port.pendingData, storedAtGate = await port.data, writes = await port.writes
                await session.setEnabled(false)
                try await session.setEnabled(false, on: a)
                try await session.move(control, on: a, to: .scalar(0.71))
                await session.compareOriginal(true)
                let live = try await session.snapshot()
                try requireTrue(live.writing && !live.isEnabled && !assignment(live, a).isEnabled && live.compareOriginal && live.unsaved,
                                "all live operations finish while storage remains suspended")
                try requireEqual(assignment(live, b), assignment(initial, b))
                try requireEqual(await port.data, storedAtGate, "live calls never rewrite storage")
                try requireEqual(await port.writes, writes)
                let pendingArchive = try JSONDecoder().decode(LibraryArchive.self, from: submitted!)
                try requireTrue(pendingArchive.enabled && pendingArchive.assignments.first { $0.app.bundleIdentifier == a }!.isEnabled,
                                "submitted bytes honestly retain their older power")
                await port.release()
                let result = try await pending.value
                let accepted = mode == .before || mode == .after
                if accepted { try requireEqual(result.outcome, .committed) }
                else if mode == .unchanged { try requireEqual(result.outcome, .refused(.io("injected unchanged"))) }
                else { try requireEqual(result.outcome, .unresolved("injected uncertain replacement")) }
                var state = try await session.snapshot()
                try requireTrue(!state.isEnabled && !assignment(state, a).isEnabled && state.compareOriginal && state.unsaved && !state.writing)
                try requireEqual(assignment(state, a).id, binding.id)
                try requireEqual(assignment(state, b), assignment(initial, b))
                try requireEqual(state.uses.first { $0.id == binding.use }!.positions[control], .scalar(0.71))
                if mode == .candidate || mode == .old || mode == .neither {
                    try requireTrue(state.unresolved)
                    do {
                        _ = try await session.checkpoint()
                        throw ContractFailure(description: "unresolved durable write must refuse")
                    } catch LibraryError.durableStateUnresolved { }
                    try await session.setEnabled(true, on: a)
                    try await session.setEnabled(false, on: a)
                    try await session.move(control, on: a, to: .scalar(0.73))
                    if mode == .neither {
                        let foreign = await port.data
                        try requireEqual(try await session.reconcile(), .unresolved("readback matches neither candidate nor previous committed bytes"))
                        try requireEqual(await port.data, foreign)
                        try requireTrue(try await session.snapshot().unresolved)
                        await port.replaceReadback(oldBytes)
                    }
                    let outcome = try await session.reconcile()
                    try requireEqual(outcome, mode == .candidate ? .committed : .refused(.previousRetained))
                    state = try await session.snapshot()
                    try requireTrue(!state.unresolved && !state.isEnabled && !assignment(state, a).isEnabled && state.compareOriginal && state.unsaved)
                    try requireEqual(state.uses.first { $0.id == binding.use }!.positions[control], .scalar(0.73))
                }
                if operation == "selection" && (accepted || mode == .candidate) {
                    try requireDifferent(assignment(state, a).use, binding.use)
                } else { try requireEqual(assignment(state, a).use, binding.use) }
                _ = try await session.checkpoint()
                let saved = try JSONDecoder().decode(LibraryArchive.self, from: await port.data!)
                try requireEqual(saved.revisions, oldArchive.revisions, "power does not retune archived definitions/native profiles")
                try requireEqual(saved.heads, oldArchive.heads)
                try requireTrue(!saved.enabled && !saved.assignments.first { $0.app.bundleIdentifier == a }!.isEnabled)
                let fresh = try await SoundLibrarySession(persistence: port, limits: limits)
                let reopened = try await fresh.snapshot()
                let now = try await session.snapshot()
                try requireEqual(reopened.assignments, now.assignments)
                try requireEqual(reopened.uses, now.uses)
                try requireEqual(reopened.definitions, now.definitions)
                try requireTrue(!reopened.isEnabled && !reopened.unsaved && !now.unsaved && !reopened.compareOriginal)
                print("PASS power.\(operation).\(mode) responsive OFF, honest durability, reconciliation and reopen")
            }
        }
    }

    func test_identity_and_power_only_generation() async throws {
        for starting in [true, false] {
            for mode in [PowerGatePort.Mode.before, .candidate] {
                let (session, port, _) = try await setup()
                try await session.setEnabled(starting, on: a)
                _ = try await session.checkpoint()
                await port.arm(mode)
                let pending = Task { try await session.nameUse(on: a, name: "Power only") }
                await port.entered()
                try await session.setEnabled(!starting, on: a)
                let during = try await session.snapshot()
                try requireTrue(during.writing && during.isEnabled && !during.compareOriginal)
                try requireEqual(assignment(during, a).isEnabled, !starting)
                await port.release(); _ = try await pending.value
                if mode == .candidate {
                    let uncertain = try await session.snapshot()
                    try requireTrue(uncertain.unresolved && uncertain.isEnabled)
                    try requireEqual(assignment(uncertain, a).isEnabled, !starting)
                    try requireEqual(try await session.reconcile(), .committed)
                }
                let live = try await session.snapshot()
                try requireEqual(assignment(live, a).isEnabled, !starting)
                try requireTrue(live.isEnabled && live.unsaved && !live.unresolved && !live.compareOriginal,
                                "app-only change advances generation through commit and accepted reconciliation")
                _ = try await session.checkpoint()
                let fresh = try await SoundLibrarySession(persistence: port, limits: limits)
                try requireEqual(try await fresh.snapshot(), try await session.snapshot())
                print("PASS power-only.start=\(starting).\(mode) commit/reconcile/reopen without master/move/compare")
            }
        }
        let (session, port, initial) = try await setup()
        await port.arm(.before)
        let add = Task { try await session.select(initial.definitions[0].id, on: "test.power.new") }
        await port.entered()
        try await session.setEnabled(false, on: a)
        await port.release(); _ = try await add.value
        let added = try await session.snapshot()
        try requireTrue(!assignment(added, a).isEnabled && assignment(added, b).isEnabled && assignment(added, "test.power.new").isEnabled)

        // Internal identity mismatches cannot be constructed by the serialized durable facade.
        for sameID in [true, false] {
            let profiles = try LibraryProfiles(), archive = try LibraryArchive.initial(profiles: profiles)
            let (content, metadata) = try archive.validated(profiles: profiles, limits: limits)
            let doc = try SoundDocument(catalog: profiles.recipes.catalog, historyLimit: UndoHistoryLimit(groups: 1))
            let store = PowerGatePort()
            await doc.openLibrary(content: content, metadata: metadata, enabled: true,
                profiles: profiles, persistence: store, limits: limits, committed: nil)
            let target = try ApplicationKey(a)
            _ = try await doc.librarySelect(archive.heads[0].definition, target: target)
            let original = try await doc.librarySnapshot().assignments[0]
            await store.arm(.before)
            let write = Task { try await doc.libraryNameUse(target: target, name: "Pending identity") }
            await store.entered()
            _ = try await doc.perform(.unassign(AssignmentID(original.id)))
            let replacement = PlaybackAssignment(id: sameID ? AssignmentID(original.id) : AssignmentID(),
                root: RootUseID(original.use), app: sameID ? try ApplicationKey("test.power.other") : target, isEnabled: false)
            _ = try await doc.perform(.assign(replacement, initial: UseListeningState(positions: [:])))
            await doc.libraryEnabled(false)
            await store.release(); _ = try await write.value
            let restored = try await doc.librarySnapshot()
            try requireEqual(restored.assignments[0].id, original.id)
            try requireEqual(restored.assignments[0].target, a)
            try requireTrue(restored.assignments[0].isEnabled, "do not transfer power across id/app mismatch")
        }
    }
}

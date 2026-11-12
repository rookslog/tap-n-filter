import Foundation
import SoundModel
import SessionStore

private func isRefused(_ value: LibraryDraftDurability) -> Bool { if case .refused = value { return true }; return false }
private func isUnknown(_ value: LibraryDraftDurability) -> Bool { if case .unresolved = value { return true }; return false }

@MainActor func listeningDurabilityCases(_ root: URL) async throws {
    for checkpointEdit in [false, true] {
        for mode in [1, 2, 3] {
            let f = try await Fixture(root.appendingPathComponent("owner-\(checkpointEdit)-\(mode)"))
            let binding = try await f.startUse(), other = try await f.attach("test.untouched")
            let store = OwnerControlledStore(f.file), session = try await SoundLibrarySession(persistence: store, limits: f.limits)
            let edit = try await session.beginEdit(.use(binding), admission: { _ in })
            let untouched = try await session.beginEdit(.use(other), admission: { _ in })
            let originalDraftFlag = try await session.snapshot().uses.first { $0.id == binding.use }!.hasLocalDraft
            let oldDisk = try Data(contentsOf: f.file)
            try check(edit.generation == 0 && !edit.pendingStructural, "L generation-zero baseline \(checkpointEdit)/\(mode)")
            _ = try await session.move(address, expected: binding, to: .scalar(0.5))
            await store.arm(mode)
            let write = Task { if checkpointEdit { return try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation) }; return try await session.checkpoint() }
            await store.wait(); await store.release(); let result = try await write.value
            let after = try await session.inspectEdit(edit.handle)
            try check(!result.outcome.isAccepted && after.positions[address] == .scalar(0.5) && after.handle == edit.handle && after.generation == 0 && !after.pendingStructural, "L exact live position/owner/generation retained \(checkpointEdit)/\(mode)")
            try check(try await session.snapshot().uses.first { $0.id == binding.use }!.hasLocalDraft == originalDraftFlag, "L listening alone does not change the preexisting local-draft flag \(checkpointEdit)/\(mode)")
            if mode == 1 { try check(isRefused(after.durability), "L matching generation-zero refusal warns \(checkpointEdit)") }
            else {
                try check(isUnknown(after.durability), "L unknown is not refusal before authoritative read \(checkpointEdit)/\(mode)")
                let observed = try await session.reconcile()
                let current = try await session.inspectEdit(edit.handle)
                try check(mode == 2 ? observed.isAccepted && !isRefused(current.durability) : !observed.isAccepted && isRefused(current.durability), "L exact readback resolves only observed outcome \(checkpointEdit)/\(mode)")
            }
            try check(!isRefused(try await session.inspectEdit(untouched.handle).durability), "L untouched unrelated owner not marked \(checkpointEdit)/\(mode)")
            let disk = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
            let diskEdit = try await disk.beginEdit(.use(binding), admission: { _ in })
            try check(diskEdit.positions[address] == .scalar(mode == 2 ? 0.5 : 0), "L actual old/new file value follows real replacement \(checkpointEdit)/\(mode)")
            if mode != 2 { try check(oldDisk == Data(contentsOf: f.file), "L refused/unknown-before retained exact old disk bytes") }
            let saved = try await session.checkpointEdit(edit.handle, expectedGeneration: 0)
            let savedEdit = try await session.inspectEdit(edit.handle)
            try check(saved.outcome.isAccepted && !isRefused(savedEdit.durability), "L genuine accepted save clears matching refusal")
            let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
            try check(try await reopened.beginEdit(.use(binding), admission: { _ in }).positions[address] == .scalar(0.5), "L fresh file/facade retains accepted listening")
        }
    }
    for action in ["done", "close"] {
        for mode in [1, 2, 3] {
            let f = try await Fixture(root.appendingPathComponent("router-\(action)-\(mode)")); let target = try await f.startUse()
            let store = OwnerControlledStore(f.file)
            var router: TNFEditorCommands?
            let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
            await app.start(persistence: store, limits: f.limits)
            let commands = TNFEditorCommands(app: app); router = commands
            try await commands.select(.use(target)); commands.windowPresented = true
            try await commands.move(address, to: 0.5)
            let token = commands.adapter.token
            await store.arm(mode)
            let saving = Task { if action == "done" { try await commands.done() } else { try await commands.close() } }
            await store.wait(); await store.release()
            do { try await saving.value; throw Failure(message: "faulted listening retirement accepted") }
            catch is Failure { throw Failure(message: "faulted listening retirement accepted") }
            catch { commands.fail(error) }
            try await commands.refresh()
            try check(commands.adapter.token == token && commands.windowPresented && commands.edit?.positions[address] == .scalar(0.5) && commands.edit?.generation == 0 && !commands.changedHere, "L faulted \(action) keeps actual owner/live position/window state without Changed Here \(mode)")
            try check(commands.durabilityWarning == (mode == 1 ? "Not Saved" : "Not Yet Confirmed"), "L actual router warning \(action)/\(mode)")
            if mode != 1 { await commands.menuOpened().value; try await commands.refresh() }
            try check(commands.durabilityWarning == (mode == 2 ? nil : "Not Saved"), "L observed router readback warning \(action)/\(mode)")
            try await commands.close()
            app.beginDrain(); _ = await app.finishDrain(.save); app.close()
        }
    }
    try await lateListeningCases(root.appendingPathComponent("late"))
}

@MainActor private func lateListeningCases(_ root: URL) async throws {
    for checkpointEdit in [false, true] {
        for mutation in ["listen", "replace", "retire"] {
            for mode in [1, 2, 3] {
                let f = try await Fixture(root.appendingPathComponent("\(checkpointEdit)-\(mutation)-\(mode)")); let binding = try await f.startUse()
                let store = OwnerControlledStore(f.file), session = try await SoundLibrarySession(persistence: store, limits: f.limits)
                var edit = try await session.beginEdit(.use(binding), admission: { _ in })
                _ = try await session.move(address, expected: binding, to: .scalar(0.5))
                let captured = edit
                await store.arm(mode)
                let writing = Task { if checkpointEdit { return try await session.checkpointEdit(captured.handle, expectedGeneration: captured.generation) }; return try await session.checkpoint() }
                await store.wait()
                if mutation == "listen" { _ = try await session.move(address, expected: binding, to: .scalar(1)) }
                else {
                    _ = try await session.doneEdit(edit.handle, expectedGeneration: edit.generation)
                    if mutation == "replace" { edit = try await session.beginEdit(.use(binding), admission: { _ in }) }
                }
                await store.release(); _ = try await writing.value
                if mode != 1 { _ = try await session.reconcile() }
                if mutation == "retire" {
                    edit = try await session.beginEdit(.use(binding), admission: { _ in })
                }
                let current = try await session.inspectEdit(edit.handle)
                try check(!isRefused(current.durability), "L old completion cannot mark newer listening/replacement/retirement \(checkpointEdit)/\(mutation)/\(mode)")
                try check(current.positions[address] == .scalar(mutation == "listen" ? 1 : 0.5), "L old completion never replaces newer/live listening \(checkpointEdit)/\(mutation)/\(mode)")
            }
        }
    }
    // An accepted older write must not clear the next generation-zero listening failure.
    for checkpointEdit in [false, true] {
        let f = try await Fixture(root.appendingPathComponent("accepted-old-\(checkpointEdit)")); let binding = try await f.startUse()
        let store = OwnerControlledStore(f.file), session = try await SoundLibrarySession(persistence: store, limits: f.limits)
        let edit = try await session.beginEdit(.use(binding), admission: { _ in })
        _ = try await session.move(address, expected: binding, to: .scalar(0.5))
        await store.arm(0)
        let older = Task { if checkpointEdit { return try await session.checkpointEdit(edit.handle, expectedGeneration: 0) }; return try await session.checkpoint() }
        await store.wait(); _ = try await session.move(address, expected: binding, to: .scalar(1))
        let newer = Task { if checkpointEdit { return try await session.checkpointEdit(edit.handle, expectedGeneration: 0) }; return try await session.checkpoint() }
        await Task.yield(); await store.arm(1); await store.release()
        let a = try await older.value, b = try await newer.value
        let current = try await session.inspectEdit(edit.handle)
        try check(a.outcome.isAccepted && !b.outcome.isAccepted && isRefused(current.durability) && current.positions[address] == .scalar(1), "L accepted-old cannot clear newer failure at same authored generation \(checkpointEdit)")
    }
}

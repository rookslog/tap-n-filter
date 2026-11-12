import Foundation
import SoundModel
import SessionStore

private func refused(_ value: LibraryDraftDurability) -> Bool { if case .refused = value { return true }; return false }
private func unresolved(_ value: LibraryDraftDurability) -> Bool { if case .unresolved = value { return true }; return false }

@MainActor func durabilityOwnerCases(_ root: URL) async throws {
    for workspace in [false, true] {
        let f = try await Fixture(root.appendingPathComponent(workspace ? "workspace" : "use"))
        f.edit = try await f.session.edit(f.edit.handle, expectedGeneration: f.edit.generation, command: .addPart(type: "gain", at: 0))
        _ = try await f.publish(); let binding = try await f.attach(), other = try await f.attach("test.other")
        let store = OwnerControlledStore(f.file)
        let session = try await SoundLibrarySession(persistence: store, limits: f.limits)
        let target: LibraryEditTarget = workspace ? .definition(f.definition) : .use(binding)
        var edit = try await session.beginEdit(target, admission: { _ in })
        let part = edit.parts[0].id
        func set(_ value: Double) async throws -> LibraryEditSnapshot {
            let current = try await session.inspectEdit(edit.handle)
            return try await session.edit(current.handle, expectedGeneration: current.generation, command: .setPhysical(part: part, parameter: "gainDb", value: value))
        }
        let untouched = try await session.beginEdit(.use(other), admission: { _ in })
        edit = try await set(-3)
        await store.arm(1)
        let failed = Task { try await session.checkpoint() }
        await store.wait(); edit = try await set(-6); let newest = edit
        await store.release(); let result = try await failed.value
        let refusedSnapshot = try await session.inspectEdit(edit.handle)
        try check(!result.outcome.isAccepted && !refused(refusedSnapshot.durability), "D old refused write cannot mark newer draft \(workspace)")
        try check(try await session.inspectEdit(edit.handle).generation == newest.generation, "D refusal bookkeeping leaves newer generation untouched \(workspace)")
        try check(!refused(try await session.inspectEdit(untouched.handle).durability), "D untouched unrelated owner never gets a false local warning \(workspace)")

        await store.arm(3)
        let unknown = Task { try await session.checkpoint() }
        await store.wait(); await store.release(); _ = try await unknown.value
        try check(unresolved(try await session.inspectEdit(edit.handle).durability), "D real unknown stays unresolved before readback \(workspace)")
        edit = try await set(-9)
        let afterNew = edit
        let readback = try await session.reconcile()
        let readbackSnapshot = try await session.inspectEdit(edit.handle)
        try check(!readback.isAccepted && !refused(readbackSnapshot.durability), "D old unknown-before resolution does not mark newer work \(workspace)")
        try check(try await session.inspectEdit(edit.handle).generation == afterNew.generation, "D readback preserves newer draft generation \(workspace)")

        // A new handle for the same retained draft is not the old writer's editor.
        await store.arm(1)
        let retiring = Task { try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation) }
        await store.wait()
        _ = try await session.doneEdit(edit.handle, expectedGeneration: edit.generation)
        edit = try await session.beginEdit(target, admission: { _ in })
        await store.release(); _ = try await retiring.value
        try check(!refused(try await session.inspectEdit(edit.handle).durability), "D late checkpointEdit wrapper cannot stamp replacement handle \(workspace)")
        let saved = try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation)
        try check(saved.outcome.isAccepted, "D subsequent genuine checkpointEdit saves retained work \(workspace)")
        let before = try await session.inspectEdit(edit.handle)
        await store.arm(1)
        let preview = try await session.previewUpdateLibrary(edit.handle, expectedGeneration: before.generation, places: [LibraryUpdatePlace(use: binding.use)])
        let publication = Task { try await session.confirmUpdateLibrary(preview) }
        await store.wait(); await store.release(); _ = try await publication.value
        let after = try await session.inspectEdit(edit.handle)
        try check(!refused(after.durability), "D refused A25 does not turn already-saved local work into Not Saved \(workspace)")
        try check(after.generation == before.generation && after.parts == before.parts && after.positions == before.positions, "D A25 refusal reporting changes no authored/listening work \(workspace)")
        for turn in 0..<4 {
            edit = try await set(-12)
            await store.arm(0)
            let older = Task { try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation) }
            await store.wait()
            edit = try await set(-15)
            let newer = Task { try await session.checkpointEdit(edit.handle, expectedGeneration: edit.generation) }
            await Task.yield()
            await store.arm(1); await store.release()
            let oldResult = try await older.value, newResult = try await newer.value
            let current = try await session.inspectEdit(edit.handle)
            try check(oldResult.outcome.isAccepted && !newResult.outcome.isAccepted && refused(current.durability) && current.parts[0].settings.first { $0.parameter == "gainDb" }?.physicalValue == -15,
                      "D older accepted checkpointEdit cannot clear newer exact failure \(workspace)/\(turn)")
            let recovered = try await session.checkpointEdit(edit.handle, expectedGeneration: current.generation)
            try check(recovered.outcome.isAccepted, "D matching accepted checkpoint clears current failure \(workspace)/\(turn)")
        }
        let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
        let reopened = try await fresh.beginEdit(target, admission: { _ in })
        try check(reopened.parts[0].settings.first { $0.parameter == "gainDb" }?.physicalValue == -15, "D fresh file retains accepted real work \(workspace)")
    }
}

import Foundation
import SoundModel
import SessionStore

actor AckEditReadGate {
    private var armed = false
    private var captured: LibraryEditSnapshot?
    private var entered: [CheckedContinuation<Void, Never>] = []
    private var releaseRead: CheckedContinuation<Void, Never>?
    func arm() { armed = true; captured = nil }
    func wait() async { if captured == nil { await withCheckedContinuation { entered.append($0) } } }
    func read(_ owner: SoundLibrarySession, _ handle: LibraryEditHandle) async throws -> LibraryEditSnapshot {
        let value = try await owner.inspectEdit(handle)
        if armed {
            armed = false; captured = value
            for waiter in entered { waiter.resume() }; entered = []
            await withCheckedContinuation { releaseRead = $0 }
        }
        return value
    }
    func release() { releaseRead?.resume(); releaseRead = nil }
}

@MainActor func ackSetup(_ root: URL, gate: AckEditReadGate? = nil) async throws -> (Fixture, LibraryAppSession, TNFEditorCommands, LibraryBinding) {
    let f = try await Fixture(root); try await f.map(.create(.slider(id: id(5300), title: "Background", initial: 0, waypoints: [0, 0.5, 1]))); _ = try await f.publish(); let binding = try await f.attach("com.apple.Safari")
    let app = LibraryAppSession(changed: {}, editRead: { owner, handle in
        if let gate { return try await gate.read(owner, handle) }; return try await owner.inspectEdit(handle)
    }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: f.port, limits: f.limits)
    let commands = TNFEditorCommands(app: app)
    try await commands.select(.use(binding))
    return (f, app, commands, binding)
}

@MainActor func ackCases(_ root: URL) async throws {
    let (f, app, c, binding) = try await ackSetup(root)
    let bytes = try Data(contentsOf: f.file), token = c.adapter.token!
    for position in [0.5, 1.0, 0.0] {
        try await c.move(address, to: position)
        try check(c.scalar(address) == position && c.projection?.mappings.controls.first { $0.address == address }?.effective == .scalar(position), "ACK wrapper returns current choice-source projection \(position)")
    }
    for position in [0.5, 1.0, 0.0] {
        let slider = LibraryControlAddress(path: [], control: id(5300))
        try await c.move(slider, to: position)
        try check(c.scalar(slider) == position, "ACK wrapper returns current slider projection \(position)")
    }
    // The production row admits synchronously and consumes on its captured-token operation.
    let receipt = try c.admitMove(address, to: 0.5)
    try c.validateCallback(token); try await c.consume(receipt)
    try check(c.scalar(address) == 0.5, "ACK actual UI admit plus consume returns current projection")
    let before = c.projection!
    try await c.move(address, to: 0.5)
    try check(c.projection?.mappings == before.mappings && c.edit?.generation == 0 && c.edit?.canUndo == false && !c.changedHere, "ACK same listening value neutral, no authored history/generation/Changed Here")
    let (owner, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    try check(owner.uses.first { $0.id == binding.use }?.positions[choice] == .scalar(0.5), "ACK projection equals actual qualified owner")
    try check(try Data(contentsOf: f.file) == bytes, "ACK reading/neutral consume does not itself checkpoint")
    try await c.consume(c.admitEndPositionGesture())
    try check(c.edit?.generation == 0 && c.edit?.canUndo == false, "ACK nil end-gesture has no unrelated authored mutation")
    try await c.close()
    try await c.consume(nil)
    try check(c.adapter.token == nil, "ACK nil consume after retirement is harmless")
    app.cancelPendingSave(); app.beginDrain(); _ = await app.finishDrain(.discard); app.close()
}

@MainActor func ackHeldCases(_ root: URL) async throws {
    let gate = AckEditReadGate(), (_, app, c, _) = try await ackSetup(root, gate: gate)
    await app.editor.displaySettled(); await gate.arm()
    let old = Task { try await c.refresh() }; await gate.wait()
    let first = try c.admitMove(address, to: 0.5), second = try c.admitMove(address, to: 1)
    let started = AckStarted()
    let consume = Task { @MainActor in started.signal(); try await c.consume(first); try await c.consume(second); return c.scalar(address) }
    await started.wait()
    let (owner, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    try check(owner.uses.first { $0.target == "com.apple.Safari" }?.positions[choice] == .scalar(1), "ACK newer live moves settle while old mapping read remains held")
    await gate.release()
    try await old.value
    let delivered = try await consume.value
    try check(delivered == 1 && c.scalar(address) == 1 && c.edit?.generation == 0, "ACK held old read and coalesced rapid consumes return latest generation-zero listening")
    let oldToken = c.adapter.token!
    try await c.select(.definition(app.snapshot!.definitions.first { $0.origin == "custom" }!.id))
    do { try c.validateCallback(oldToken); throw Failure(message: "old UI callback accepted") }
    catch is Failure { throw Failure(message: "old UI callback accepted") }
    catch { try check(c.binding == nil, "ACK stale callback refuses without updating new target") }
    c.prepareQuit(); app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor private final class AckStarted {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { entered = true; for waiter in waiters { waiter.resume() }; waiters = [] }
    func wait() async { if !entered { await withCheckedContinuation { waiters.append($0) } } }
}

@MainActor func ackPublicationCases(_ root: URL) async throws {
    let f = try await Fixture(root); _ = try await f.publish(); let binding = try await f.attach("com.apple.Safari")
    let reads = LateSnapshotGate()
    let app = LibraryAppSession(changed: {}, read: { try await reads.read($0) }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: f.port, limits: f.limits)
    await reads.arm()
    let older = Task { await app.coordinator.refresh() }; _ = await reads.wait()
    _ = try await app.coordinator.submitMove(address, expected: binding, to: .scalar(1)).value
    await app.coordinator.refresh()
    let (current, version) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    try check(app.snapshot == current && app.snapshotGeneration == version, "ACK accepted publication exposes actual current generation/state")
    await reads.release(); await older.value
    try check(app.snapshot == current && app.snapshotGeneration == version, "ACK superseded earlier read cannot relabel delivered generation/state")
    app.cancelPendingSave(); app.beginDrain(); _ = await app.finishDrain(.discard); app.close()
}

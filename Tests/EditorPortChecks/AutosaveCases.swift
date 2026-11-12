import Foundation
import SoundModel
import SessionStore

@MainActor func autosaveSetup(_ root: URL, delay: (@Sendable () async throws -> Void)? = nil) async throws -> (Fixture, OwnerControlledStore, LibraryAppSession, TNFEditorCommands, LibraryBinding, LibraryBinding) {
    let f = try await Fixture(root); _ = try await f.publish()
    let safari = try await f.attach("com.apple.Safari"), iina = try await f.attach("com.colliderli.iina")
    let store = OwnerControlledStore(f.file)
    var router: TNFEditorCommands?
    let changed: () -> Void = { router?.receiveOwnerChange() }
    let app: LibraryAppSession
    if let delay { app = LibraryAppSession(changed: changed, checkpointDelay: delay) }
    else { app = LibraryAppSession(changed: changed) }
    await app.start(persistence: store, limits: f.limits)
    let commands = TNFEditorCommands(app: app); router = commands; commands.windowPresented = true
    try await commands.select(.use(safari)); try commands.startEditing()
    return (f, store, app, commands, safari, iina)
}

@MainActor func autosaveTimingCases(_ root: URL) async throws {
    for action in ["done", "close", "switch"] {
        for mode in 0...3 { try await autosaveManualCase(root.appendingPathComponent("\(action)-\(mode)"), action: action, mode: mode) }
    }
    try await autosaveGesture(root.appendingPathComponent("gesture"))
    try await autosaveIssued(root.appendingPathComponent("issued"))
    try await autosaveIgnoringCancellation(root.appendingPathComponent("cooperative"))
}

@MainActor func autosaveManualCase(_ root: URL, action: String, mode: Int) async throws {
    let (f, store, app, commands, safari, iina) = try await autosaveSetup(root)
    let token = commands.adapter.token!
    try await commands.renameControl(token, path: [], control: choice, title: "Manual before timer")
    let before = await store.submitted.count
    await store.arm(mode)
    let operation = Task {
        switch action {
        case "done": try await commands.done()
        case "close": try await commands.close()
        default: try await commands.select(.use(iina))
        }
    }
    await store.wait(); await store.release()
    let outcome = await operation.result
    if mode == 0 { try outcome.get() }
    else {
        guard case .failure(let error) = outcome else { throw Failure(message: "failed manual checkpoint accepted") }
        commands.fail(error)
        try check(commands.adapter.token == token && commands.target == .use(safari) && commands.edit!.canUndo && commands.controls.first { $0.id == choice }?.title == "Manual before timer", "T \(action)/\(mode) failed default-cadence manual save retains exact history/work/selection")
        try check(commands.editing == (action != "done") && commands.windowPresented && commands.error != nil, "T \(action)/\(mode) correct Use/Edit/window/error on failure")
    }
    if mode == 0 { await app.coordinator.waitForIssuedSaves() }
    let afterManual = await store.submitted.count
    try await Task.sleep(for: .milliseconds(450))
    let afterWait = await store.submitted.count
    print("TIMING \(action)/\(mode) default200ms before=\(before) afterManual=\(afterManual) after450ms=\(afterWait)")
    try check(afterWait == afterManual, "T \(action)/\(mode) no pending-timer write after issued saves settle and two cadences")
    if mode != 0 || action == "done" {
        try check(afterManual == before + 1, "T \(action)/\(mode) exactly one explicit store write")
    }
    if mode != 0 {
        if mode != 1 { await app.coordinator.onMenuOpen() }
        switch action {
        case "done": try await commands.done()
        case "close": try await commands.close()
        default: try await commands.select(.use(iina))
        }
    }
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
    let saved = try await fresh.beginEdit(.use(safari), admission: { _ in })
    try check(saved.controls.first { $0.id == choice }?.title == "Manual before timer", "T \(action)/\(mode) accepted recovery persisted actual work/fresh facade")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func autosaveGesture(_ root: URL) async throws {
    let (_, store, app, commands, _, _) = try await autosaveSetup(root)
    let token = commands.adapter.token!, before = await store.submitted.count
    try commands.beginPositionGesture(address)
    let sample = try commands.admitMove(address, to: 1)
    await store.arm(1)
    let done = Task { try await commands.done() }
    await store.wait(); await store.release()
    do { try await done.value } catch { commands.fail(error) }
    try await commands.consume(sample)
    try await Task.sleep(for: .milliseconds(450))
    let gestureWrites = await store.submitted.count
    print("OBSERVED gesture writes=\(gestureWrites) before=\(before) token=\(commands.adapter.token == token) position=\(String(describing: commands.edit?.positions[address])) canUndo=\(String(describing: commands.edit?.canUndo)) error=\(String(describing: commands.error))")
    try check(gestureWrites == before + 1 && commands.adapter.token == token && commands.edit!.positions[address] == .scalar(1) && commands.edit!.canUndo, "T gesture-end acknowledgement cannot leave a retrying timer after refused Done")
    app.beginDrain(); _ = await app.finishDrain(.discard); app.close()
}

@MainActor func autosaveIssued(_ root: URL) async throws {
    let delay = IssuedAutosaveDelay()
    let (f, store, app, commands, safari, _) = try await autosaveSetup(root, delay: { try await delay.sleep() })
    let before = await store.submitted.count
    await store.arm(0)
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Already writing")
    await store.wait() // The actual default200ms autosave is now issued and held by persistence.
    var manualFinished = false
    let manual = Task { try await commands.done(); manualFinished = true }
    try await Task.sleep(for: .milliseconds(25))
    let heldWrites = await store.submitted.count
    try check(!manualFinished && !commands.editing && heldWrites == before + 1, "T manual Done waits behind issued autosave; issued write not cancelled")
    try await commands.move(address, to: 0.5)
    await app.coordinator.refresh()
    await delay.waitForPending()
    await store.release()
    try await manual.value
    try check(await store.submitted.count == before + 2, "T issued autosave completes before manual checkpoint with newer listening")
    // Public live-owner witness deliberately does not schedule another AppSession sleep.
    // The genuine AppSession listening mutation above already owns the pending save.
    _ = try await app.coordinator.move(address, expected: safari, to: .scalar(1))
    await delay.releasePending()
    try await Task.sleep(for: .milliseconds(100))
    let issuedFinalCount = await store.submitted.count
    print("OBSERVED issued writes before=\(before) afterManual=\(before + 2) afterNew=\(issuedFinalCount)")
    let data = await store.submitted
    let copies = [root.appendingPathComponent("first.json"), root.appendingPathComponent("manual.json"), root.appendingPathComponent("newer.json")]
    for (bytes, file) in zip(data.suffix(3), copies) { try bytes.write(to: file) }
    var positions: [LibraryPosition?] = []
    for file in copies {
        let owner = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: 8_000_000), limits: f.limits)
        positions.append(try await owner.snapshot().uses.first { $0.id == safari.use }?.positions[choice])
    }
    print("OBSERVED issued payloads \(positions)")
    try check(issuedFinalCount == before + 3, "T earlier issued/manual completion cannot cancel newer genuine pending save")
    try check(positions == [.scalar(0), .scalar(0.5), .scalar(1)], "T actual issued/manual/new pending payloads retain ordered0/0.5/1 states")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

actor IssuedAutosaveDelay {
    private var first = true
    private let pending = AutosaveDelayGate()
    func sleep() async throws {
        if first {
            first = false
            try await Task.sleep(for: .milliseconds(200))
        } else { await pending.sleepIgnoringCancellation() }
    }
    func waitForPending() async { await pending.waitFor(0) }
    func releasePending() async { await pending.release(0) }
}

actor AutosaveDelayGate {
    private var waits: [CheckedContinuation<Void, Never>?] = []
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleepIgnoringCancellation() async {
        let index = waits.count
        await withCheckedContinuation { continuation in
            waits.append(continuation)
            let ready = arrivals.filter { $0.0 <= index }
            arrivals.removeAll { $0.0 <= index }
            for (_, arrival) in ready { arrival.resume() }
        }
    }
    func waitFor(_ index: Int) async {
        if waits.count > index { return }
        await withCheckedContinuation { arrivals.append((index, $0)) }
    }
    func release(_ index: Int) { waits[index]?.resume(); waits[index] = nil }
}

@MainActor func autosaveIgnoringCancellation(_ root: URL) async throws {
    let gate = AutosaveDelayGate()
    let (f, store, app, commands, safari, _) = try await autosaveSetup(root, delay: { await gate.sleepIgnoringCancellation() })
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Old sleep")
    await gate.waitFor(0)
    try await commands.done()
    try commands.startEditing()
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "New pending")
    await gate.waitFor(1)
    let writes = await store.submitted.count
    await gate.release(0)
    try await Task.sleep(for: .milliseconds(25))
    try check(await store.submitted.count == writes, "T cancellation-ignoring old delay cannot admit a checkpoint")
    try await commands.done() // Must still cancel the newer sleep, not a stolen/nil debounce reference.
    let afterSecondManual = await store.submitted.count
    await gate.release(1)
    try await Task.sleep(for: .milliseconds(25))
    try check(await store.submitted.count == afterSecondManual, "T cancelled old completion cannot steal newer pending save ownership")
    try commands.startEditing()
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Genuine later save")
    await gate.waitFor(2); await gate.release(2)
    try await Task.sleep(for: .milliseconds(60))
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
    let edit = try await fresh.beginEdit(.use(safari), admission: { _ in })
    try check(edit.controls.first { $0.id == choice }?.title == "Genuine later save", "T later real mutation still saves after cancellation-ignoring delays")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func autosaveNewMutationCases(_ root: URL) async throws {
    for refused in [false, true] {
        for kind in ["edit", "listen", "undo", "redo"] {
            let (f, store, app, commands, safari, _) = try await autosaveSetup(root.appendingPathComponent("\(refused)-\(kind)"))
            try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Intermediate")
            try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Authored")
            if refused { await store.arm(1) }
            let manual = Task { try await commands.done() }
            if refused { await store.wait(); await store.release() }
            do { try await manual.value } catch { commands.fail(error) }
            switch kind {
            case "edit": try commands.startEditing(); try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "New genuine edit")
            case "listen": try await commands.move(address, to: 0.5)
            case "undo": try await commands.history(redo: false)
            default:
                try await commands.history(redo: false)
                try await Task.sleep(for: .milliseconds(450))
                try await commands.history(redo: true)
            }
            try await Task.sleep(for: .milliseconds(450))
            let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
            let saved = try await fresh.beginEdit(.use(safari), admission: { _ in })
            let expectedTitle = kind == "edit" ? "New genuine edit" : kind == "undo" ? "Intermediate" : "Authored"
            try check(saved.controls.first { $0.id == choice }?.title == expectedTitle && (kind != "listen" || saved.positions[address] == .scalar(0.5)), "T new \(kind) after \(refused ? "refused" : "accepted") Done autosaves at actual default cadence")
            try check(commands.editing == (kind == "edit"), "T new mutation does not force Edit for listening/history")
            app.beginDrain(); _ = await app.finishDrain(.save); app.close()
        }
    }
}

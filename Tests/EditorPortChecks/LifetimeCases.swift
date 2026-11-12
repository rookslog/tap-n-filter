import Foundation
import SoundModel
import SessionStore

@MainActor func lifetimeSetup(_ root: URL, delay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }) async throws -> (Fixture, OwnerControlledStore, LibraryAppSession, TNFEditorCommands, LibraryBinding, LibraryBinding) {
    let f = try await Fixture(root); _ = try await f.publish()
    let safari = try await f.attach("com.apple.Safari"), iina = try await f.attach("com.colliderli.iina")
    let store = OwnerControlledStore(f.file)
    var router: TNFEditorCommands?
    let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: delay)
    await app.start(persistence: store, limits: f.limits)
    let commands = TNFEditorCommands(app: app); router = commands; commands.windowPresented = true
    try await commands.select(.use(safari)); try commands.startEditing()
    return (f, store, app, commands, safari, iina)
}

@MainActor func portLifetimeCases(_ root: URL) async throws {
    let (f, _, app, commands, safari, iina) = try await lifetimeSetup(root.appendingPathComponent("accepted"))
    let token = commands.adapter.token!
    try await commands.renameControl(token, path: [], control: choice, title: "Retained edit")
    try await commands.select(.use(safari))
    try await commands.selectInitial(preferredApp: safari.target)
    try check(commands.adapter.token == token && commands.editing && commands.edit!.canUndo, "C same exact target and Open Editor activation preserve handle/history/mode")
    try await commands.done()
    try check(commands.adapter.token == token && !commands.editing && commands.edit!.canUndo, "C Done returns Use without retiring exact handle")
    try await commands.move(address, to: 0.5); await app.coordinator.refresh(); try await commands.refresh()
    try await commands.history(redo: false)
    try check(!commands.editing && commands.controls.first { $0.id == choice }?.title == "Door" && commands.edit!.positions[address] == .scalar(0.5), "C Use Undo changes authored name, not newer listening, and never re-enters Edit")
    try await commands.history(redo: true)
    try check(!commands.editing && commands.controls.first { $0.id == choice }?.title == "Retained edit", "C Use Redo restores authored name without entering Edit")
    try await commands.history(redo: false)
    try commands.requireAccepted(await app.coordinator.submitCheckpoint().value)
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
    let freshEdit = try await fresh.beginEdit(.use(safari), admission: { _ in })
    try check(freshEdit.controls == commands.edit!.controls && freshEdit.positions == commands.edit!.positions, "C Done Undo checkpoint/fresh facade equals actual live authored/listening state")
    try await commands.select(.use(iina)); try await commands.select(.use(safari))
    try check(commands.adapter.token != token && commands.edit?.canUndo == false, "C real target switch and back retires old history")
    try commands.startEditing()
    try await commands.move(address, to: 0.5)
    try await commands.previewOption(address, mutation: .remove(id: b, replacement: a)); try await commands.applyOption()
    for report in commands.reports { commands.acknowledgeReport(report.request.command) }
    try await commands.done(); try await commands.history(redo: false)
    let choiceReports = commands.reports.compactMap { receipt -> LibraryChoiceReport? in if case .choice(let value) = receipt.report { return value }; return nil }
    try check(choiceReports.count == 1 && choiceReports[0].changes.count == 1 && choiceReports[0].changes[0].place == .use(app: safari.target, use: safari.use) && choiceReports[0].changes[0].reason == .explicitReplacement && choiceReports[0].changes[0].address == address && choiceReports[0].changes[0].before == a && choiceReports[0].changes[0].after == b, "C option edit Done reporting Undo delivers exactly the real A-to-B row")
    for report in commands.reports { commands.acknowledgeReport(report.request.command) }; commands.collectReports()
    try check(commands.reports.isEmpty, "C Use option report acknowledged exactly once")
    try commands.startEditing()
    let initial = commands.edit!.positions[address]
    try commands.beginPositionGesture(address)
    let sample = try commands.admitMove(address, to: 1)
    try await commands.done(); try await commands.consume(sample)
    try check(!commands.editing && commands.edit!.positions[address] == .scalar(1), "C Done settles previously admitted active gesture samples")
    try await commands.history(redo: false)
    try check(commands.edit!.positions[address] == initial, "C settled Done gesture retains one real Undo in Use")
    try await commands.close(); try await commands.select(.use(safari))
    try check(commands.edit?.canUndo == false, "C accepted real close ends history")
    commands.prepareQuit(); app.beginDrain(); _ = await app.finishDrain(.save)
    try check(app.cancelDrain(), "C existing cancelable Quit resumes owner")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
    for action in ["done", "close", "switch"] {
        for mode in [1, 2, 3] { try await lifetimeFailure(root.appendingPathComponent("\(action)-\(mode)"), action: action, mode: mode) }
    }
}

@MainActor func lifetimeFailure(_ root: URL, action: String, mode: Int) async throws {
    let (f, store, app, commands, safari, iina) = try await lifetimeSetup(root)
    let token = commands.adapter.token!
    try await commands.renameControl(token, path: [], control: choice, title: "Unsaved retained")
    let bytes = try Data(contentsOf: f.file), count = await store.submitted.count
    await store.arm(mode)
    let operation = Task {
        switch action {
        case "done": try await commands.done()
        case "close": try await commands.close()
        default: try await commands.select(.use(iina))
        }
    }
    await store.wait()
    try check(commands.adapter.token == token && commands.target == .use(safari) && commands.edit!.canUndo, "C \(action)/\(mode) held checkpoint has not retired current work")
    await store.release()
    do { try await operation.value; throw Failure(message: "failed persistence reported success") }
    catch is Failure { throw Failure(message: "failed persistence reported success") }
    catch {
        let actualFailure = commands.error
        commands.fail(error)
        try check(actualFailure != nil && commands.error == actualFailure, "C actual native callback retains checkpoint failure details")
    }
    try await commands.refresh()
    try check(commands.adapter.token == token && commands.target == .use(safari) && commands.edit!.canUndo && commands.controls.first { $0.id == choice }?.title == "Unsaved retained", "C \(action)/\(mode) refused/unknown retains exact handle/history/work/selection")
    try check(commands.windowPresented && commands.error != nil && commands.editing == (action != "done"), "C \(action)/\(mode) required window/mode/error retained")
    if mode != 2 { try check(try Data(contentsOf: f.file) == bytes, "C \(action)/\(mode) no unaccepted replacement") }
    try await Task.sleep(for: .milliseconds(35))
    try check(await store.submitted.count == count + 1, "C \(action)/\(mode) no command replay")
    if mode != 1 { await app.coordinator.onMenuOpen() }
    commands.clearError()
    try commands.requireAccepted(await app.coordinator.submitCheckpoint().value)
    let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
    let edit = try await reopened.beginEdit(.use(safari), admission: { _ in })
    try check(edit.controls.first { $0.id == choice }?.title == "Unsaved retained", "C \(action)/\(mode) later accepted checkpoint/fresh facade retains memory work")
    if action == "switch" {
        try await commands.select(.use(iina)); try await commands.select(.use(safari))
        try check(commands.edit?.canUndo == false, "C recovered switch really ends history")
    } else {
        try await commands.close(); try await commands.select(.use(safari))
        try check(commands.edit?.canUndo == false, "C recovered close really ends history")
    }
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func portLifetimeTimer(_ root: URL) async throws {
    let (_, store, app, commands, _, _) = try await lifetimeSetup(root, delay: { try await Task.sleep(for: .milliseconds(200)) })
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Timer witness")
    let before = await store.submitted.count
    await store.arm(1)
    let done = Task { try await commands.done() }
    await store.wait(); await store.release()
    do { try await done.value } catch { }
    try await Task.sleep(for: .milliseconds(450))
    let after = await store.submitted.count
    app.beginDrain(); _ = await app.finishDrain(.discard); app.close()
    print("OBSERVED refused Done submitted writes before=\(before) after=\(after)")
    try check(after == before + 1, "C refused Done never replays from pending 200ms timer")
}

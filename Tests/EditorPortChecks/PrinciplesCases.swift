import Foundation
import SoundModel
import SessionStore

@MainActor func principlesCases(_ root: URL) async throws {
    let f = try await Fixture(root); _ = try await f.publish(); let target = try await f.attach()
    let store = OwnerControlledStore(f.file)
    var router: TNFEditorCommands?, feedback = 0
    let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: store, limits: f.limits)
    let commands = TNFEditorCommands(app: app, feedback: { feedback += 1 }); router = commands
    try await commands.select(.use(target)); try commands.startEditing()
    try check(!commands.changedHere && commands.durabilityWarning == nil, "P2 untouched open has no invented change/failure mark")
    let before = commands.edit!
    do { try await commands.command(.setPhysical(part: id(999999), parameter: "gainDb", value: 0)); throw Failure(message: "invalid part accepted") }
    catch is Failure { throw Failure(message: "invalid part accepted") }
    catch { commands.fail(error); commands.fail(error) }
    try await commands.refresh()
    try check(commands.edit == before && feedback == 1, "P2 real refusal preserves entire sound and duplicate receipt beeps once (silent spy)")
    let diagnostic = commands.error
    commands.fail(TNFEditorError.stale)
    await app.editor.displaySettled(); try await commands.refresh()
    try check(commands.error == diagnostic && feedback == 1, "P2 stale refresh neither erases genuine failure nor beeps/replays")
    commands.fail(TNFEditorError.readOnly); commands.fail(TNFEditorError.busy)
    try check(feedback == 1, "P2 read-only/busy do not beep")
    try await commands.move(address, to: 0.5)
    try check(!commands.changedHere, "P2 listening position in Edit is not changed-here authorship")
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Door title")
    try check(commands.changedHere, "P2 authoritative rename sets structural changed mark")
    try commands.requireAccepted(await app.coordinator.submitCheckpoint().value); try await commands.refresh()
    try check(commands.changedHere && commands.durabilityWarning == nil, "P2 checkpoint saves but does not publish changed mark")
    let bytes = try Data(contentsOf: f.file), stable = commands.edit!
    for _ in 0..<4 { try await commands.refresh() }
    try check(commands.edit == stable && bytes == (try Data(contentsOf: f.file)), "P2 occurrence metadata reads preserve generation/history/store bytes")
    let fresh = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
    let reopened = try await fresh.beginEdit(.use(target), admission: { _ in })
    try check(reopened.pendingStructural && reopened.controls.first { $0.id == choice }?.title == "Door title", "P2 exact rename/checkpoint/fresh reopen keeps authoritative flag")
    try await commands.done(); try await commands.move(address, to: 0)
    await app.coordinator.editor.displaySettled(); try await commands.refresh()
    try check(commands.changedHere, "P2 ordinary listening cannot clear structural dot")
    commands.toggleOpen(address, at: 10, clicks: 1)
    let opened = commands.openControls
    commands.toggleOpen(address, at: 10.1, clicks: 2)
    try check(commands.openControls == opened, "OpenToggle ignores second click without sound mutation")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

@MainActor func terminalReceiptCases(_ root: URL) async throws {
    let f = try await Fixture(root); _ = try await f.publish(); let target = try await f.attach()
    let port = OwnerControlledStore(f.file)
    var router: TNFEditorCommands?, feedback = 0
    let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: port, limits: f.limits)
    let commands = TNFEditorCommands(app: app, feedback: { feedback += 1 }); router = commands
    try await commands.select(.use(target)); try commands.startEditing()
    try await commands.renameControl(commands.adapter.token!, path: [], control: choice, title: "Changed")
    for iteration in 0..<66 {
        try await commands.previewUpdate(places: [LibraryUpdatePlace(use: target.use)])
        await port.arm(1)
        let update = Task { try await commands.confirmUpdate() }
        await port.wait(); await port.release(); try await update.value
        commands.collectReports()
        try check(commands.adapter.publications.isEmpty && commands.reports.isEmpty, "P1 definitive refusal reservation retired internally \(iteration)")
    }
    try check(feedback == 66 && commands.changedHere, "P1 each distinct refused A25 beeps once, draft retained beyond64 reservations")
    try await commands.previewUpdate(places: [LibraryUpdatePlace(use: target.use)])
    await port.arm(2)
    let update = Task { try await commands.confirmUpdate() }
    await port.wait()
    try check(commands.adapter.publications.count == 1 && commands.reports.isEmpty, "P1 held write is not acknowledged/published")
    commands.collectReports()
    try check(commands.adapter.publications.count == 1, "P1 no-report cleanup retains in-flight exact receipt")
    await port.release(); try await update.value
    commands.collectReports()
    try check(commands.adapter.publications.count == 1 && commands.reports.isEmpty, "P1 unknown-after retained until authoritative menu-open reconcile")
    await commands.menuOpened().value
    try await commands.refresh(); commands.collectReports()
    try check(commands.reports.count == 1, "P1 existing menu reconciliation delivers late accepted Changes once")
    let receipt = commands.reports[0], command = receipt.request.command
    try check(receipt.commit != nil, "P1 accepted report retains actual commit identity")
    commands.collectReports(); try check(commands.reports.count == 1, "P1 repeated owner callback cannot duplicate report")
    commands.acknowledgeReport(command)
    commands.collectReports(); try check(commands.reports.isEmpty && commands.adapter.publications.isEmpty, "P1 intentional Done retires exact report")
    try await commands.close()
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

func axisCases() throws {
    try check(TNFEditorWindowBudget.lastCardClearance > 0 && TNFEditorWindowBudget.lastLibraryClearance > 0,
              "F12 actual card/Library bottom insets clear the floating bar budget")
    try check(TNFEditorWindowBudget.minimumLibraryScrollRoom(height: 480) > 0,
              "F12 minimum480 retains a positive Library scroll viewport; native fit remains unrun")
    for card in [914.0, 1056, 1800] {
        let axis = TNFEditorAxis.cardTrack(width: card)
        for value in [0.0, 0.5, 1] {
            let local = TNFEditorAxis(origin: 0, width: axis.width)
            try check(axis.x(value) == axis.origin + local.x(value), "F15 shared thumb/playhead/point x, card \(card), value \(value)")
        }
    }
}

@MainActor func durabilityProjectionCases(_ root: URL) async throws {
    for mode in [1, 2, 3] {
        let f = try await Fixture(root.appendingPathComponent("mode-\(mode)"))
        f.edit = try await f.session.edit(f.edit.handle, expectedGeneration: f.edit.generation, command: .addPart(type: "gain", at: 0))
        _ = try await f.publish(); let target = try await f.attach()
        let port = OwnerControlledStore(f.file)
        var commands: TNFEditorCommands?
        let app = LibraryAppSession(changed: { commands?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
        await app.start(persistence: port, limits: f.limits)
        let c = TNFEditorCommands(app: app); commands = c
        try await c.select(.use(target)); try c.startEditing()
        let part = c.edit!.parts[0].id, token = c.adapter.token
        try await c.command(.setPhysical(part: part, parameter: "gainDb", value: -6))
        try check(c.edit?.pendingStructural == false && c.changedHere, "P2 setting-only change uses real setting flag, not structural flag \(mode)")
        await port.arm(mode)
        let done = Task { try await c.done() }
        await port.wait(); await port.release()
        do { try await done.value; throw Failure(message: "faulted Done accepted") }
        catch is Failure { throw Failure(message: "faulted Done accepted") }
        catch { c.fail(error) }
        try check(c.adapter.token == token && c.edit?.parts[0].settings.first?.physicalValue == -6 && c.edit?.pendingStructural == false, "P2 refusal/unknown keeps exact owner/work independent of structure \(mode)")
        try check(c.durabilityWarning == (mode == 1 ? "Not Saved" : "Not Yet Confirmed"), "P2 real durability glyph projection \(mode)")
        if mode != 1 { await c.menuOpened().value; try await c.refresh() }
        if mode == 2 { try check(c.durabilityWarning == nil && c.changedHere, "P2 exact accepted readback clears only durability, never changed-here") }
        else if mode == 3 { try check(c.durabilityWarning == "Not Saved" && c.changedHere, "P2 exact unknown-before reconciliation becomes refused, work retained") }
        try await c.close()
        app.beginDrain(); _ = await app.finishDrain(.save); app.close()
    }
}

actor PortReadDelay {
    private var armed = false
    func arm() { armed = true }
    func delay() async { if armed { try? await Task.sleep(for: .milliseconds(350)) } }
}
@MainActor func slowGestureReadCase(_ root: URL) async throws {
    let f = try await Fixture(root); _ = try await f.publish(); let target = try await f.attach()
    let store = OwnerControlledStore(f.file), read = PortReadDelay()
    var commands: TNFEditorCommands?
    let app = LibraryAppSession(changed: { commands?.receiveOwnerChange() }, editRead: { session, handle in
        await read.delay(); return try await session.inspectEdit(handle)
    })
    await app.start(persistence: store, limits: f.limits)
    let c = TNFEditorCommands(app: app); commands = c
    try await c.select(.use(target)); try c.startEditing()
    let before = await store.submitted.count
    try c.beginPositionGesture(address); let sample = try c.admitMove(address, to: 1)
    await read.arm(); await store.arm(1)
    let done = Task { try await c.done() }
    await store.wait(); await store.release()
    do { try await done.value; throw Failure(message: "slow-read refused Done accepted") }
    catch is Failure { throw Failure(message: "slow-read refused Done accepted") }
    catch { c.fail(error) }
    try await c.consume(sample)
    try await Task.sleep(for: .milliseconds(450))
    let after = await store.submitted.count
    try check(after == before + 1 && c.edit!.positions[address] == .scalar(1) && c.edit!.canUndo, "C01 default200ms timer cannot race slow350ms post-gesture display read")
    app.beginDrain(); _ = await app.finishDrain(.discard); app.close()
}

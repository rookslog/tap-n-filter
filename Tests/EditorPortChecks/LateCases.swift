import Foundation
import SoundModel
import SessionStore

@MainActor func portLateCases(_ root: URL) async throws {
    for mode in 0...2 {
        let fixture = try await Fixture(root.appendingPathComponent("mode-\(mode)"))
        _ = try await fixture.publish()
        let safari = try await fixture.attach("com.apple.Safari"), iina = try await fixture.attach("com.colliderli.iina")
        let port = OwnerControlledStore(fixture.file)
        var router: TNFEditorCommands?
        let app = LibraryAppSession(changed: { router?.receiveOwnerChange() }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
        await app.start(persistence: port, limits: fixture.limits)
        let commands = TNFEditorCommands(app: app); router = commands
        try await commands.select(.use(safari)); try commands.startEditing()
        try await commands.previewOption(address, mutation: .remove(id: b, replacement: a)); try await commands.applyOption()
        for report in commands.reports { commands.acknowledgeReport(report.request.command) }
        try await commands.previewUpdate(places: [LibraryUpdatePlace(use: safari.use), LibraryUpdatePlace(use: iina.use)])
        await port.arm(mode == 2 ? 2 : mode)
        let write = Task { try await commands.confirmUpdate() }
        await port.wait()
        let selection = Task { try await commands.select(.use(iina)) }
        let (held, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        guard held.writing, let publicationToken = held.pendingCommit else { throw Failure(message: "held publication token missing") }
        lateScalar("held-publication mode=\(mode)", snapshot: held, binding: iina)
        commands.app.send(.libraryPower(iina, false))
        let powerAcknowledgement = try app.coordinator.enqueueMutation { try await $0.snapshot() }
        commands.app.send(.libraryMove(iina, address, .scalar(1)))
        let moveAcknowledgement = try app.coordinator.enqueueMutation { try await $0.snapshot() }
        let powered = try await powerAcknowledgement.value
        let moved = try await moveAcknowledgement.value
        lateScalar("power-tail-ack mode=\(mode)", snapshot: powered, binding: iina)
        lateScalar("move-tail-ack mode=\(mode)", snapshot: moved, binding: iina)
        try check(powered.assignments.first { $0.id == iina.assignment && $0.use == iina.use && $0.target == iina.target }?.isEnabled == false, "U49 actual App.send OFF acknowledged by exact owner on mutation tail \(mode)")
        try requireLateIntent(moved, binding: iina, label: "U49 actual App.send moved before publication release \(mode)")
        try check(powered.writing && moved.writing && powered.pendingCommit == publicationToken && moved.pendingCommit == publicationToken, "U49 real OFF/listening acknowledgements overlap exact held publication token \(mode)")
        try check(commands.target == .use(safari), "U49 target retirement has not bypassed held publication \(mode)")
        await port.release()
        try await write.value
        do { try await selection.value }
        catch {
            guard mode == 2 else { throw error }
            try check(commands.target == .use(safari), "A unknown publication prevents premature target retirement")
            await commands.reconcilePublication()
            try await commands.select(.use(iina))
        }
        await app.coordinator.waitForIssuedSaves()
        let (owner, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        lateScalar("settled-owner mode=\(mode)", snapshot: owner, binding: iina)
        try requireLateIntent(owner, binding: iina, label: "U49 authoritative post-publication owner \(mode)")
        await app.coordinator.refresh(); commands.collectReports()
        if mode == 2 { await commands.reconcilePublication() }
        if mode == 1 {
            try check(commands.reports.isEmpty && commands.adapter.publications.isEmpty, "A refused update retires terminal no-report receipt, never accepted report")
        } else {
            let reports = commands.reports.filter { if case .update = $0.report { return true }; return false }
            try check(reports.count == 1, "A exact accepted/late report survives changed selection \(mode)")
            let id = reports[0].request.command
            commands.acknowledgeReport(id); commands.collectReports()
            try check(commands.reports.isEmpty && commands.adapter.publications[id] == nil, "A exact report acknowledged once \(mode)")
        }
        let state = app.snapshot!
        lateScalar("settled-projection mode=\(mode)", snapshot: state, binding: iina)
        try requireLateIntent(state, binding: iina, label: "U49 post-acknowledgement projection \(mode)")
        try check(state.assignments.first { $0.id == iina.assignment }?.isEnabled == false && state.uses.first { $0.id == iina.use }?.positions[choice] == .scalar(1), "A newer exact app OFF/listening survives publication \(mode)")
        try await commands.close()
        app.beginDrain()
        guard case .saved(let receipt) = await app.finishDrain(.save) else { throw Failure(message: "late-publication drain did not save") }
        app.close()
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: fixture.file, maximumBytes: 8_000_000), limits: fixture.limits)
        let disk = try await reopened.snapshot()
        print("SCALAR drain-commit mode=\(mode) token=\(receipt.token) outcome=\(receipt.outcome)")
        lateScalar("fresh-facade mode=\(mode)", snapshot: disk, binding: iina)
        try requireLateIntent(disk, binding: iina, label: "U49 fresh facade after drain-save \(mode)")
    }
}

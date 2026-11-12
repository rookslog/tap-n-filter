import Foundation
import SoundModel
import SessionStore

actor LateSnapshotGate {
    private var armed = false
    private var captured: LibrarySnapshot?
    private var entered: [CheckedContinuation<LibrarySnapshot, Never>] = []
    private var releaseRead: CheckedContinuation<Void, Never>?
    func arm() { armed = true; captured = nil }
    func wait() async -> LibrarySnapshot {
        if let captured { return captured }
        return await withCheckedContinuation { entered.append($0) }
    }
    func read(_ owner: SoundLibrarySession) async throws -> LibrarySnapshot {
        let value = try await owner.snapshot()
        if armed {
            armed = false; captured = value
            for waiter in entered { waiter.resume(returning: value) }; entered = []
            await withCheckedContinuation { releaseRead = $0 }
        }
        return value
    }
    func release() { releaseRead?.resume(); releaseRead = nil }
}

@MainActor func lateScalar(_ label: String, snapshot: LibrarySnapshot, binding: LibraryBinding) {
    let assignment = snapshot.assignments.first { $0.id == binding.assignment && $0.use == binding.use && $0.target == binding.target }
    print("SCALAR \(label) assignment=\(binding.assignment) use=\(binding.use) target=\(binding.target) enabled=\(String(describing: assignment?.isEnabled)) position=\(String(describing: snapshot.uses.first { $0.id == binding.use }?.positions[choice])) writing=\(snapshot.writing) unresolved=\(snapshot.unresolved) token=\(String(describing: snapshot.pendingCommit))")
}

@MainActor func requireLateIntent(_ snapshot: LibrarySnapshot, binding: LibraryBinding, label: String) throws {
    try check(snapshot.assignments.first { $0.id == binding.assignment && $0.use == binding.use && $0.target == binding.target }?.isEnabled == false, "\(label) exact assignment OFF")
    try check(snapshot.uses.first { $0.id == binding.use }?.positions[choice] == .scalar(1), "\(label) exact use listening1")
}

@MainActor func lateAcknowledgementCases(_ root: URL) async throws {
    let f = try await Fixture(root); _ = try await f.publish()
    let binding = try await f.attach("com.colliderli.iina")
    let gate = LateSnapshotGate()
    let app = LibraryAppSession(changed: {}, read: { try await gate.read($0) }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: f.port, limits: f.limits)
    await gate.arm()
    let observation = Task { await app.coordinator.refresh() }
    let captured = await gate.wait()
    let off = try app.coordinator.submitEnabled(false, expected: binding)
    let move = try app.coordinator.submitMove(address, expected: binding, to: .scalar(1))
    let offResult = try await off.value, moveResult = try await move.value
    print("SCALAR completed OFF=\(offResult) listening=\(moveResult)")
    try check(offResult == .changed && moveResult == .changed, "U49 actual typed OFF/move complete before releasing older observation")
    let (owner, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    lateScalar("settled-owner", snapshot: owner, binding: binding)
    try requireLateIntent(owner, binding: binding, label: "U49 owner before observation release")
    await gate.release(); await observation.value
    lateScalar("superseded-observation-return", snapshot: app.snapshot!, binding: binding)
    try check(app.snapshot == captured, "U49 superseded refresh returns without publishing old state")
    try check(app.snapshot != owner, "U49 awaited older observation is not an acknowledgement of newer owner state")
    await app.coordinator.refresh()
    lateScalar("acknowledged-new-observation", snapshot: app.snapshot!, binding: binding)
    try requireLateIntent(app.snapshot!, binding: binding, label: "U49 new projection after actual acknowledgements")
    let wrongUse = LibraryBinding(assignment: binding.assignment, use: UUID(), target: binding.target)
    let wrongAssignment = LibraryBinding(assignment: UUID(), use: binding.use, target: binding.target)
    let wrongTarget = LibraryBinding(assignment: binding.assignment, use: binding.use, target: "test.wrong")
    for wrong in [wrongUse, wrongAssignment, wrongTarget] {
        let power = try app.coordinator.submitEnabled(true, expected: wrong)
        let value = try app.coordinator.submitMove(address, expected: wrong, to: .scalar(0))
        let powerResult = try await power.value, valueResult = try await value.value
        try check(powerResult == .superseded && valueResult == .superseded, "U49 wrong exact assignment/use/target returns typed superseded")
    }
    let (after, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    try requireLateIntent(after, binding: binding, label: "U49 stale negatives preserve current owner")
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
    do {
        _ = try app.coordinator.submitMove(address, expected: binding, to: .scalar(0))
        throw Failure(message: "retired coordinator admitted late move")
    } catch LibraryConsumerLifecycleError.unavailable(.closed) {
        print("PASS U49 retired coordinator refuses late move before scheduling")
    }
}

actor LateCallerReads {
    private var count: Int?
    private var entries: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func arm(afterDefinitions: Int) { count = afterDefinitions }
    func read(_ session: SoundLibrarySession) async throws -> LibrarySnapshot {
        let value = try await session.snapshot()
        if let count, value.definitions.count > count {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
                if waiting.count >= 2 { for entry in entries { entry.resume() }; entries = [] }
            }
        }
        return value
    }
    func waitForTwo() async {
        if waiting.count < 2 { await withCheckedContinuation { entries.append($0) } }
    }
    func release() {
        count = nil
        for read in waiting { read.resume() }; waiting = []
    }
}

@MainActor func lateProductCallerCases(_ root: URL) async throws {
    let fixture = try await Fixture(root); _ = try await fixture.publish()
    let binding = try await fixture.attach("com.colliderli.iina")
    let reads = LateCallerReads()
    let app = LibraryAppSession(changed: {}, read: { try await reads.read($0) }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: fixture.port, limits: fixture.limits)
    let commands = TNFEditorCommands(app: app)
    try await commands.select(.use(binding)); try commands.startEditing()
    await app.coordinator.waitForIssuedSaves()
    await app.editor.displaySettled()
    let (initial, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    await reads.arm(afterDefinitions: initial.definitions.count)
    let own = Task { try await commands.makeItsOwn() }
    await reads.waitForTwo()
    let invalidation = try app.coordinator.enqueueMutation { try await $0.snapshot() }
    let current = try await invalidation.value
    let assignment = current.assignments.first { $0.id == binding.assignment && $0.target == binding.target }!
    let expected = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
    print("SCALAR MakeItsOwn committed oldUse=\(binding.use) newUse=\(expected.use) candidate=\(String(describing: app.acceptedCreation?.reference))")
    try check(binding.use != expected.use && app.snapshot?.assignments.first { $0.id == binding.assignment }?.use == binding.use, "U49 creation accepted while last-published assignment is still old")
    await reads.release(); try await own.value
    print("SCALAR MakeItsOwn returned target=\(String(describing: commands.target)) expected=\(expected)")
    try check(commands.target == .use(expected), "U49 real Make Its Own follows authoritative accepted binding despite superseded refresh")
    try check(commands.edit?.handle.target == .use(expected) && commands.editing, "U49 real Make Its Own keeps Edit on newly accepted owner")
    try await commands.close()
    app.beginDrain()
    guard case .saved = await app.finishDrain(.save) else { throw Failure(message: "caller drain did not save") }
    app.close()
    let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: fixture.file, maximumBytes: 8_000_000), limits: fixture.limits)
    let saved = try await reopened.snapshot()
    try check(saved.assignments.first { $0.id == binding.assignment && $0.target == binding.target }?.use == expected.use, "U49 actual accepted binding survives drain and fresh facade")
}

@MainActor func lateDefinitionCallerCase(_ root: URL) async throws {
    let fixture = try await Fixture(root); _ = try await fixture.publish()
    let binding = try await fixture.attach("com.colliderli.iina")
    let reads = LateCallerReads()
    let app = LibraryAppSession(changed: {}, read: { try await reads.read($0) }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) })
    await app.start(persistence: fixture.port, limits: fixture.limits)
    let commands = TNFEditorCommands(app: app)
    try await commands.select(.use(binding))
    await app.coordinator.waitForIssuedSaves(); await app.editor.displaySettled()
    let (initial, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
    await reads.arm(afterDefinitions: initial.definitions.count)
    let create = Task { () throws -> LibraryReference in
        let result = await app.createEmpty(name: "New authoritative block").value
        try commands.requireAccepted(result)
        guard let reference = result.creation?.acceptedReference else { throw Failure(message: "accepted creation reference missing") }
        await app.coordinator.refresh()
        try await commands.select(.definition(reference.definition))
        return reference
    }
    await reads.waitForTwo()
    let invalidation = try app.coordinator.enqueueMutation { try await $0.snapshot() }
    let current = try await invalidation.value
    let reference = app.acceptedCreation!.reference
    try check(current.definitions.contains { $0.id == reference.definition && $0.origin == "custom" } && app.snapshot?.definitions.contains { $0.id == reference.definition } == false, "U49 created custom definition exists in owner, not last published snapshot")
    await reads.release()
    _ = try await create.value
    print("SCALAR new-definition target=\(String(describing:commands.target)) edit=\(String(describing:commands.edit?.handle.target)) readOnly=\(commands.isReadOnly)")
    try check(commands.target == .definition(reference.definition) && commands.edit?.handle.target == .definition(reference.definition) && !commands.isReadOnly && commands.canAuthor, "U49 real New Block selects actual custom editor owner despite superseded refresh")
    try await commands.close()
    app.beginDrain(); _ = await app.finishDrain(.save); app.close()
}

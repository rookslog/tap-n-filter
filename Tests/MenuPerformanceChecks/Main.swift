import Foundation
import SessionStore
import SoundModel
#if SWIFT_PACKAGE
@testable import tap_n_filter
#endif

actor MenuPersistence: LibraryPersistence {
    let file: LibrarySessionFile
    private(set) var writes = 0
    var refuse = false
    init(_ url: URL) { file = LibrarySessionFile(url: url, maximumBytes: 4_000_000) }
    func load() async throws -> Data? { try await file.load() }
    func commit(_ bytes: Data) async -> LibraryWriteOutcome {
        writes += 1
        if refuse { refuse = false; return .refused(.io("owned fake refusal")) }
        return await file.commit(bytes)
    }
    func refuseNext() { refuse = true }
}

enum MenuCheckFailure: Error { case failed(String) }
func require(_ value: Bool, _ name: String) throws {
    guard value else { throw MenuCheckFailure.failed(name) }
    print("PASS \(name)")
}

#if !SWIFT_PACKAGE
@main
#endif
struct MenuPerformanceChecks {
    @MainActor static func main() async throws {
        try await run(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    @MainActor static func run(_ directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json"), store = MenuPersistence(directory.appendingPathComponent("library.json"))
        let limits = try LibraryAppSession.normalLimits()
        let app = LibraryAppSession(changed: {}, checkpointDelay: {})
        await app.start(persistence: store, limits: limits)
        let snapshot = app.presentation!, assignment = snapshot.assignments[0]
        let use = snapshot.uses.first { $0.id == assignment.use }!
        let volume = use.controls.first { $0.title == "Volume" }!
        let address = LibraryControlAddress(path: [], control: volume.id)
        let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
        let initialWrites = await store.writes
        app.send(.beginGesture)
        for value in [0.2, 0.4, 0.9] { app.send(.libraryMove(binding, address, .scalar(value))) }
        app.send(.compare(true))
        let (during, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        app.scheduleSave()
        try await Task.sleep(for: .milliseconds(50))
        try require(await store.writes == initialWrites, "drag has no new disk write even with immediate debounce clock")
        try require(during.uses.first { $0.id == assignment.use }?.positions[volume.id] == .scalar(0.9)
                    && during.compareOriginal, "final live value and comparison update during drag")
        app.send(.compare(false))
        app.send(.endGesture)
        _ = await app.gestureSave?.value; await app.coordinator.waitForIssuedSaves()
        let reopened = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: 4_000_000), limits: limits)
        let after = try await reopened.snapshot()
        try require(await store.writes == initialWrites + 1, "release flush commits once after the queued final move")
        try require(after.uses.first { $0.id == assignment.use }?.positions[volume.id] == .scalar(0.9) && !after.isEnabled,
                    "fresh owner retains exact release value and master OFF")
        await store.refuseNext()
        app.send(.beginGesture)
        app.send(.libraryMove(binding, address, .scalar(0.3)))
        app.send(.endGesture)
        _ = await app.gestureSave?.value; await app.coordinator.waitForIssuedSaves()
        let (refused, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        try require(app.problem != nil && refused.unsaved && refused.uses.first { $0.id == assignment.use }?.positions[volume.id] == .scalar(0.3),
                    "failed release save preserves unsaved final value and reports the failure")
        app.send(.beginGesture)
        app.send(.libraryMove(binding, address, .scalar(0.4)))
        app.send(.endGesture)
        _ = await app.gestureSave?.value; await app.coordinator.waitForIssuedSaves()
        app.send(.beginGesture)
        app.send(.libraryMove(binding, address, .scalar(0.7)))
        app.beginDrain()
        guard case .saved = await app.finishDrain(.save) else { throw MenuCheckFailure.failed("drain") }
        app.close()
        let drained = try await SoundLibrarySession(persistence: LibrarySessionFile(url: file, maximumBytes: 4_000_000), limits: limits)
        try require(try await drained.snapshot().uses.first { $0.id == assignment.use }?.positions[volume.id] == .scalar(0.7),
                    "quit/drain flushes an unreleased drag after recovery without losing final value")
    }
}

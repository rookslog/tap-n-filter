import Foundation
import SessionStore
import SoundModel

enum CheckFailure: Error { case failed(String) }

func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure.failed(message) }
    print("PASS \(message)")
}

public enum SessionStoreChecks {
    public static func run(_ directory: URL) async throws {
        let file = directory.appendingPathComponent("state/session.json")
        let store = ListeningSessionFile(url: file)
        try check(try await store.load() == nil, "missing file is a fresh session, no file created")
        let session = try await ListeningSession()
        try await session.putEveryday(on: "test.disk-player")
        let before = try await session.checkpoint()
        let id = before.snapshot.assignments[0].id
        try await session.move(session.controls[2].id, on: id, to: 0.61)
        try await session.setEnabled(true)
        let latest = try await session.checkpoint()
        try check(try await store.save(latest), "atomic write records a coherent model checkpoint")
        try check(!(try await store.save(before)), "late older save cannot replace current positions")
        try check(!(try await store.save(latest)), "identical save is a no-op")
        let reopenedStore = ListeningSessionFile(url: file)
        let reopened = try await ListeningSession(savedData: reopenedStore.load())
        let state = try await reopened.snapshot()
        try check(state.assignments == latest.snapshot.assignments && state.isEnabled,
                  "fresh store and command owner reload actual saved app positions and desired power")
        let original = try Data(contentsOf: file)
        let limited = ListeningSessionFile(url: file, maximumBytes: 8)
        do {
            _ = try await limited.save(latest)
            throw CheckFailure.failed("oversize save should refuse")
        } catch SessionFileError.tooLarge { }
        try check(try Data(contentsOf: file) == original, "size refusal retains original file bytes")
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let failing = ListeningSessionFile(url: blocker.appendingPathComponent("session.json"))
        do {
            _ = try await failing.save(latest)
            throw CheckFailure.failed("failed I/O should throw")
        } catch is CocoaError { }
        try check(try Data(contentsOf: blocker) == Data("blocker".utf8), "I/O failure is surfaced and leaves existing data alone")
        try await LibraryFileCases.run(in: directory.appendingPathComponent("library"))
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SoundModelTests/Fixtures")
        try await BootstrapFileCases.run(directory.appendingPathComponent("bootstrap"), fixtureDirectory: fixtures)
        print("PASS session file checks; temporary directory only, no app/audio/devices")
    }
}

#if !SWIFT_PACKAGE
@main struct Main {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tnf-session-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await SessionStoreChecks.run(directory)
    }
}
#endif

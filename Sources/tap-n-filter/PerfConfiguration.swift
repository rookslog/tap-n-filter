import Darwin
import Foundation
import EverydayMenu
import SessionStore
import SoundModel

enum PerfScenario: String, CaseIterable { case drag, `switch`, menuOpen = "menu-open", idle }
enum PerfLaunchError: Error { case arguments, path, ownership, existing, claim }

struct PerfConfiguration: Equatable {
    let scenario: PerfScenario
    let library: URL
    let runID: UUID
    var directory: URL { library.deletingLastPathComponent() }

    static func refusalRecord(_ error: Error) -> String {
        let record: [String: Any] = ["phase": "options-refused", "soundOff": true, "error": String(describing: error)]
        return (try? JSONSerialization.data(withJSONObject: record)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func parse(_ arguments: [String], required: Bool) throws -> Self? {
        guard arguments.contains(where: { $0.hasPrefix("--perf") }) else {
            if required { throw PerfLaunchError.arguments }
            return nil
        }
        let allowed: Set<String> = ["--perf-scenario", "--perf-run-id", "--library-session-file"]
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--") else { throw PerfLaunchError.arguments }
            values[flag] = arguments[index + 1]
            index += 2
        }
        guard values.count == 3, let scenario = values["--perf-scenario"].flatMap(PerfScenario.init(rawValue:)),
              let path = values["--library-session-file"], let runID = values["--perf-run-id"].flatMap(UUID.init(uuidString:)) else {
            throw PerfLaunchError.arguments
        }
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.standardizedFileURL.path == path,
              url.resolvingSymlinksInPath().path == path, url.lastPathComponent == "library-v5.json",
              url.deletingLastPathComponent().lastPathComponent == "tnf-perf-" + runID.uuidString.lowercased() else {
            throw PerfLaunchError.path
        }
        return Self(scenario: scenario, library: url, runID: runID)
    }

    func claim() throws {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw PerfLaunchError.ownership }
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        guard Set(names).isSubset(of: ["owner.json", "app.log"]), !manager.fileExists(atPath: library.path) else {
            throw PerfLaunchError.existing
        }
        let marker = directory.appendingPathComponent("owner.json")
        guard marker.resolvingSymlinksInPath() == marker,
              let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              owner["runID"] as? String == runID.uuidString.lowercased(),
              (owner["uid"] as? NSNumber)?.uint32Value == getuid() else { throw PerfLaunchError.ownership }
        let lock = directory.appendingPathComponent("started.lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PerfLaunchError.claim }
        close(descriptor)
    }
}

enum PerfActionPolicy {
    static func permits(_ action: EverydayMenuAction) -> Bool {
        switch action {
        case .setEnabled(let enabled), .libraryPower(_, let enabled): return !enabled
        case .compare(let enabled): return !enabled
        default: return true
        }
    }
}

struct PerfSchedule {
    let scenario: PerfScenario
    static let seconds: Double = 15
    var expected: Int { scenario == .drag ? 900 : scenario == .switch ? 15 : 0 }
    var interval: Double { scenario == .drag ? 1.0 / 60 : 1 }
    func due(at elapsed: Double) -> Int {
        guard elapsed >= 0 else { return 0 }
        return min(expected, Int(elapsed / interval) + 1)
    }
    func value(_ index: Int) -> Double { 0.1 + 0.8 * Double(index) / 899 }
}

actor PerfPersistence: LibraryPersistence {
    struct Commit: Codable {
        let started, finished: Double
        let outcome: String
    }
    let file: LibrarySessionFile
    let url: URL
    private var loaded = false
    private var commits: [Commit] = []
    init(_ url: URL) { self.url = url; file = LibrarySessionFile(url: url, maximumBytes: 4_000_000) }
    func load() async throws -> Data? {
        guard !loaded, !FileManager.default.fileExists(atPath: url.path) else { throw PerfLaunchError.existing }
        loaded = true
        return try await file.load()
    }
    func commit(_ data: Data) async -> LibraryWriteOutcome {
        let started = Date().timeIntervalSince1970
        let result = await file.commit(data)
        commits.append(Commit(started: started, finished: Date().timeIntervalSince1970, outcome: String(describing: result)))
        return result
    }
    func history() -> [Commit] { commits }
}

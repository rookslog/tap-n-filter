import Darwin
import EverydayMenu
import Foundation
import SessionStore
import SoundModel
#if SWIFT_PACKAGE
@testable import tap_n_filter
#endif

enum HarnessCheckFailure: Error { case failed(String) }
func requireHarness(_ value: Bool, _ name: String) throws {
    guard value else { throw HarnessCheckFailure.failed(name) }
    print("PASS \(name)")
}
func refuseHarness(_ name: String, _ body: () throws -> Void) throws {
    do { try body() } catch is HarnessCheckFailure { throw HarnessCheckFailure.failed(name) }
    catch { print("PASS \(name)"); return }
    throw HarnessCheckFailure.failed(name)
}

#if !SWIFT_PACKAGE
@main
#endif
struct PerfHarnessChecks {
    @MainActor static func main() async throws {
        try await run(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    @MainActor static func run(_ root: URL) async throws {
        let root = root.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func configuration() throws -> PerfConfiguration {
            let id = UUID()
            let directory = root.appendingPathComponent("tnf-perf-" + id.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["runID": id.uuidString.lowercased(), "uid": getuid()])
                .write(to: directory.appendingPathComponent("owner.json"))
            return try PerfConfiguration.parse(["app", "--perf-scenario", "drag", "--perf-run-id", id.uuidString,
                "--library-session-file", directory.appendingPathComponent("library-v5.json").path], required: true)!
        }
        try requireHarness(try PerfConfiguration.parse(["app"], required: false) == nil, "normal launch has no perf mode")
        try refuseHarness("perf-only bundle refuses ordinary launch") { _ = try PerfConfiguration.parse(["app"], required: true) }
        let first = try configuration()
        let args = ["app", "--perf-scenario", "drag", "--perf-run-id", first.runID.uuidString,
                    "--library-session-file", first.library.path]
        for extra in [["--smoke"], ["--probe-bundle", "foreign"], ["--session-file", "foreign"], ["--perf-scenario", "idle"]] {
            try refuseHarness("mixed/duplicate perf arguments refuse before boot") { _ = try PerfConfiguration.parse(args + extra, required: false) }
        }
        try first.claim()
        try refuseHarness("one run cannot be claimed twice") { try first.claim() }
        let existing = try configuration()
        let original = Data("owned existing bytes".utf8)
        try original.write(to: existing.library)
        try refuseHarness("existing library refuses without reset") { try existing.claim() }
        try requireHarness(try Data(contentsOf: existing.library) == original, "existing bytes remain exact")
        try requireHarness(!PerfActionPolicy.permits(.setEnabled(true)) && !PerfActionPolicy.permits(.compare(true))
                           && PerfActionPolicy.permits(.setEnabled(false)), "perf action policy cannot enable master or compare")
        let run = try configuration()
        try run.claim()
        let store = PerfPersistence(run.library)
        let app = LibraryAppSession(changed: {}, checkpointDelay: {})
        await app.start(persistence: store, limits: try LibraryAppSession.normalLimits())
        try requireHarness(app.isReady && app.presentation?.isEnabled == false, "real harness owner starts fresh OFF")
        let initialCommits = await store.history()
        try requireHarness(!initialCommits.isEmpty && initialCommits.allSatisfy { $0.outcome == "committed" || $0.outcome == "identical" },
                           "counter records actual owned-file commit outcomes")
        let assignment = app.presentation!.assignments[0]
        let use = app.presentation!.uses.first { $0.id == assignment.use }!
        let slider = use.controls.first { $0.title == "Softer" }!
        let binding = LibraryBinding(assignment: assignment.id, use: assignment.use, target: assignment.target)
        var applied = 0
        app.perfMutationCompleted = { _ in applied += 1 }
        app.send(.beginGesture)
        app.send(.libraryMove(binding, LibraryControlAddress(path: [], control: slider.id), .scalar(0.9)))
        let (during, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        try await Task.sleep(for: .milliseconds(20))
        try requireHarness(await store.history().count == initialCommits.count && !during.isEnabled,
                           "new-source gesture has no persistence call during movement and stays OFF")
        app.send(.endGesture)
        await app.coordinator.waitForIssuedSaves()
        app.beginDrain()
        guard case .saved = await app.finishDrain(.save) else { throw HarnessCheckFailure.failed("drain") }
        app.close()
        let reader = try await SoundLibrarySession(persistence: LibrarySessionFile(url: run.library, maximumBytes: 4_000_000),
                                                  limits: LibraryAppSession.normalLimits())
        let saved = try await reader.snapshot()
        try requireHarness(applied == 1 && !saved.isEnabled && saved.uses.first { $0.id == assignment.use }?.positions[slider.id] == .scalar(0.9),
                           "actual completion hook, final save and fresh readback corroborate positive work")
        let schedule = PerfSchedule(scenario: .drag)
        try requireHarness(schedule.expected == 900 && schedule.due(at: 15) == 900 && schedule.value(899) == 0.9,
                           "drag plan is900 real moves over15seconds at60Hz")
        try requireHarness(PerfSchedule(scenario: .switch).expected == 15, "switch plan requests15 actual option changes")
    }
}

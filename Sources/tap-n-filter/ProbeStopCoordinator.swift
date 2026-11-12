import Foundation

// Probe only. All callers share the first stop task, including callers arriving
// while disarm/startup/drain are suspended. No timeout is called clean teardown.
@MainActor final class ProbeStopCoordinator {
  struct Result: Equatable {
    let reason: String
    let sourceStopped: Bool
    let drained: Bool
    var clean: Bool { sourceStopped && drained }
  }
  private var task: Task<Result, Never>?
  func stop(
    reason: String, disarm: @escaping @MainActor () async -> Bool,
    cancelAndJoinStartup: @escaping @MainActor () async -> Void,
    stopOwnedSource: @escaping @MainActor () async -> Void,
    drain: @escaping @MainActor () async -> Bool
  ) async -> Result {
    if let task { return await task.value }
    let operation = Task { @MainActor in
      let stopped = await disarm()
      await cancelAndJoinStartup()
      await stopOwnedSource()
      let drained = await drain()
      return Result(reason: reason, sourceStopped: stopped, drained: drained)
    }
    task = operation
    return await operation.value
  }
}

// Narrow allowlist shared by the actual app callback and headless checks.
// Ordinary framework/error descriptions never enter the probe's retained log.
enum ProbeDiagnostics {
  static func sourceStopped(in data: Data) -> Bool {
    struct Witness: Decodable {
      let browserStopped: Bool
    }
    return (try? JSONDecoder().decode(Witness.self, from: data))?.browserStopped == true
  }

  static func visible(_ line: String) -> String? {
    line == "PROBE_RUNNING" || line.hasPrefix("PROBE_OUTPUT ") || line.hasPrefix("PROBE_LIFECYCLE ")
      || line.hasPrefix("PROBE_RAW_INPUT ") || line.hasPrefix("PROBE_ADOPTION ")
      ? line : nil
  }
  static func teardownUnconfirmed(_ line: String) -> Bool {
    guard line.hasPrefix("PROBE_LIFECYCLE "),
      let data = line.dropFirst("PROBE_LIFECYCLE ".count).data(using: .utf8),
      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return record["teardownCompleted"] as? Bool == false
      || (record["release"] as? String)?.contains("markerRetained") == true
  }
}

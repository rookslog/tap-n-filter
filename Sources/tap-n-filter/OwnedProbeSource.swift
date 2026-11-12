import Darwin
import Foundation

@MainActor
final class OwnedProbeSource {
  private let process = Process()
  private let commands = Pipe()
  private let log: URL
  private var heartbeat: Task<Void, Never>?

  init(executable: URL, log: URL) throws {
    self.log = log
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    process.executableURL = executable
    process.arguments = ["source", "0"]
    process.standardInput = commands
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try output.close()
  }

  func waitForZeroReady() async throws {
    for _ in 0..<150 {
      guard process.isRunning else { throw CocoaError(.executableNotLoadable) }
      if (try String(contentsOf: log, encoding: .utf8)).contains("event=SOURCE_READY_STILL_ZERO") {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CocoaError(.executableNotLoadable)
  }

  func arm() throws {
    try send("a")
    heartbeat = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(300))
          try self?.send("h")
        } catch { return }
      }
    }
  }

  private func send(_ command: String) throws {
    guard process.isRunning else { throw CocoaError(.executableNotLoadable) }
    try commands.fileHandleForWriting.write(contentsOf: Data(command.utf8))
  }

  var hasStopped: Bool { !process.isRunning }

  func stop() async {
    heartbeat?.cancel()
    heartbeat = nil
    if process.isRunning { try? send("q") }
    try? commands.fileHandleForWriting.close()
    for _ in 0..<200 {
      if !process.isRunning { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    process.terminate()
    for _ in 0..<100 {
      if !process.isRunning { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
}

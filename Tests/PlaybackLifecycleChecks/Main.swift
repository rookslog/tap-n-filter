import Foundation
import PlaybackLifecycle
import PlaybackRuntime
import SoundModel

@MainActor final class Trace {
  var events: [String] = []
  var failStart = false
  var sinks: [Sink] = []
}
@MainActor final class Inner: CaptureSession {
  let trace: Trace
  init(_ trace: Trace) { self.trace = trace }
  func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
    trace.events.append("capture.prepare")
    return CapturePreparation(format: try StreamFormat(sampleRate: 48000, channels: 2))
  }
  func start() async throws {
    trace.events.append("capture.start")
    if trace.failStart { throw RuntimeFailure.start("injected") }
  }
  func stop() async -> TeardownOutcome {
    trace.events.append("capture.stop")
    return .completed
  }
}
@MainActor struct InnerFactory: CaptureSessionFactory {
  let trace: Trace
  func makeSession() -> any CaptureSession { Inner(trace) }
}
@MainActor final class Sink: PlaybackSink {
  let trace: Trace
  private(set) var original: Bool
  private(set) var updates = 0
  init(_ trace: Trace, original: Bool = false) { self.trace = trace; self.original = original; trace.sinks.append(self) }
  func prepare(_ capture: CapturePreparation) async throws { trace.events.append("output.prepare") }
  func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {
    trace.events.append("output.update")
    self.original = original
    updates += 1
  }
  func start() throws { trace.events.append("output.start") }
  func stop() async {
    trace.events.append("output.drain")
    await Task.yield()
    trace.events.append("output.closed")
  }
}
@main struct Check {
  @MainActor static func main() async throws {
    let model = try await ListeningSession()
    try await model.putEveryday(on: "test.lifecycle")
    let assignment = ListeningRenderAssignment(legacy: try await model.snapshot().assignments[0])
    let trace = Trace()
    let factory = PlaybackCaptureFactory(inner: InnerFactory(trace: trace), assignment: assignment)
    { _, original in Sink(trace, original: original) }
    let source = ResolvedProcess(
      binding: try AppBinding(bundleIdentifier: "test.lifecycle"), pid: 1,
      audioProcessID: 1, path: .preferredPID)
    let capture = factory.makeSession()
    _ = try await capture.prepare(source: source)
    try factory.update(assignment, original: true)
    try await capture.start()
    _ = await capture.stop()
    _ = await capture.stop()
    precondition(
      trace.events == [
        "capture.prepare", "output.prepare", "output.update", "output.start", "capture.start",
        "output.drain", "output.closed", "capture.stop",
      ])
    print(
      "PASS output starts before capture mute; output drains/closes before ring teardown; repeated stop is a no-op"
    )
    trace.events = []
    trace.failStart = true
    let refused = factory.makeSession()
    _ = try await refused.prepare(source: source)
    do {
      try await refused.start()
      preconditionFailure("start should fail")
    } catch {}
    _ = await refused.stop()
    precondition(
      trace.events == [
        "capture.prepare", "output.prepare", "output.start", "capture.start", "output.drain",
        "output.closed", "capture.stop",
      ])
    print("PASS failed capture start follows the same output-first teardown")
    trace.failStart = false
    for cycle in 1...4 {
      try factory.update(assignment, original: false)
      let session = factory.makeSession()
      let sink = trace.sinks.last!
      precondition(!sink.original)
      _ = try await session.prepare(source: source)
      try await session.start()
      let old = Array(trace.sinks.dropLast())
      let oldCounts = old.map(\.updates)
      try factory.update(assignment, original: true)
      precondition(sink.original && old.map(\.updates) == oldCounts)
      try factory.update(assignment, original: false)
      precondition(!sink.original)
      try factory.update(assignment, original: true)
      _ = await session.stop()
      try factory.update(assignment, original: false)
      _ = await session.stop()
      precondition(!sink.original)
      print("PASS factory restart cycle \(cycle): fresh sink starts released,current-only hold/release,OFF during hold,cancellation,repeated stop")
    }
    print("PASS fake lifecycle only; no hardware, app windows or audio")
  }
}

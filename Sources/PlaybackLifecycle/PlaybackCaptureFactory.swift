import PlaybackRuntime
import SoundModel

@MainActor
public protocol PlaybackSink: AnyObject {
  func prepare(_ capture: CapturePreparation) async throws
  func update(_ assignment: ListeningRenderAssignment, original: Bool) throws
  func start() throws
  func stop() async
}

// The runtime's guard lease surrounds this entire session. Output and pending
// preparation must drain before the inner capture can release its ring storage.
@MainActor
public final class PlaybackCaptureFactory: CaptureSessionFactory {
  private let inner: any CaptureSessionFactory
  private let makeSink: @MainActor (ListeningRenderAssignment, Bool) -> any PlaybackSink
  private var assignment: ListeningRenderAssignment
  private var original = false
  private weak var current: PlayingCaptureSession?

  public init(
    inner: any CaptureSessionFactory, assignment: ListeningRenderAssignment,
    makeSink: @escaping @MainActor (ListeningRenderAssignment, Bool) -> any PlaybackSink
  ) {
    self.inner = inner
    self.assignment = assignment
    self.makeSink = makeSink
  }

  public func update(_ assignment: ListeningRenderAssignment, original: Bool) throws {
    try current?.sink.update(assignment, original: original)
    self.assignment = assignment
    self.original = original
  }

  public func makeSession() -> any CaptureSession {
    let session = PlayingCaptureSession(
      inner: inner.makeSession(), sink: makeSink(assignment, original))
    current = session
    return session
  }
}

@MainActor
private final class PlayingCaptureSession: CaptureSession {
  private let inner: any CaptureSession
  let sink: any PlaybackSink
  private var stopped = false

  init(inner: any CaptureSession, sink: any PlaybackSink) {
    self.inner = inner
    self.sink = sink
  }

  func prepare(source: ResolvedProcess) async throws -> CapturePreparation {
    try Task.checkCancellation()
    let capture = try await inner.prepare(source: source)
    try Task.checkCancellation()
    try await sink.prepare(capture)
    try Task.checkCancellation()
    return capture
  }

  func start() async throws {
    try Task.checkCancellation()
    try sink.start()
    try await inner.start()
    try Task.checkCancellation()
  }

  func stop() async -> TeardownOutcome {
    guard !stopped else { return .completed }
    stopped = true
    await sink.stop()
    return await inner.stop()
  }
}

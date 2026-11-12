import Foundation

public struct PlaybackTelemetry: Codable, Sendable {
  public let assignment: UUID
  public let state: String
  public let capturedFrames: UInt64
  public let outputCallbacks: UInt64
  public let nonSilentMeasuredFrames: UInt64
  public let underruns: UInt64
  public let errors: UInt64
  public let appliedIntent: UInt64
  public let nativeStatus: Int32
}

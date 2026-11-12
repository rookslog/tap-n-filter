import Foundation

public struct AssignmentID: Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public struct AppBinding: Hashable, Sendable {
    public let bundleIdentifier: String
    public init(bundleIdentifier: String) throws {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SourceResolutionError.invalidBundleIdentity
        }
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct PlanToken: Equatable, Sendable {
    public let intent: UInt64
    public let source: UInt64
    public let format: UInt64
    public init(intent: UInt64, source: UInt64, format: UInt64) {
        self.intent = intent
        self.source = source
        self.format = format
    }

    func isOlder(than other: Self) -> Bool {
        intent < other.intent || source < other.source || format < other.format
    }
}

public struct StreamFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: UInt32
    public init(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0 else {
            throw RuntimeFailure.invalidFormat
        }
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public struct StartRequest: Equatable, Sendable {
    public let assignment: AssignmentID
    public let binding: AppBinding
    public let preferredPID: Int32?
    public let token: PlanToken
    public let expectedFormat: StreamFormat?
    public init(assignment: AssignmentID, binding: AppBinding, preferredPID: Int32? = nil,
                token: PlanToken, expectedFormat: StreamFormat? = nil) {
        self.assignment = assignment
        self.binding = binding
        self.preferredPID = preferredPID
        self.token = token
        self.expectedFormat = expectedFormat
    }
}

public enum ProcessSelection: Equatable, Sendable {
    case sameBundle
    case temporarySafariGraphicsAndMedia
}

public enum ResolutionPath: Equatable, Sendable {
    case preferredPID
    case temporarySafariGraphicsAndMedia
    case sameBundleFallback(previousPID: Int32?)
}

public struct ResolvedProcess: Equatable, Sendable {
    public let binding: AppBinding
    public let pid: Int32
    public let audioProcessID: UInt32
    public let path: ResolutionPath
    public let instanceIdentifier: String?
    public init(binding: AppBinding, pid: Int32, audioProcessID: UInt32, path: ResolutionPath,
                instanceIdentifier: String? = nil) {
        self.binding = binding
        self.pid = pid
        self.audioProcessID = audioProcessID
        self.path = path
        self.instanceIdentifier = instanceIdentifier
    }
}

public enum SourceResolutionError: Error, Equatable, Sendable {
    case invalidBundleIdentity
    case disappeared
    case replaced
    case ambiguousSameBundle(count: Int)
    case fallbackLimitExceeded(limit: Int)
    case lookupFailed(String)
}

public enum RuntimeFailure: Error, Equatable, Sendable {
    case invalidFormat
    case source(SourceResolutionError)
    case prepare(String)
    case start(String)
    case formatMismatch(expected: StreamFormat, actual: StreamFormat)
}

public enum CaptureCondition: Equatable, Sendable {
    case noFrames
    case silence
    case sourceDisappeared
    case sourceReplaced
    case formatChanged
    case readerError(String)
    case captureError(String)

    var isTerminal: Bool {
        switch self {
        case .noFrames, .silence: false
        default: true
        }
    }
}

public enum StopReason: Equatable, Sendable {
    case explicit
    case cancelled
    case superseded
    case condition(CaptureCondition)
}

public enum TeardownOutcome: Equatable, Sendable {
    case completed
    case bestEffort(String)
}

public enum Refusal: Equatable, Sendable {
    case staleToken
    case conflictingEqualToken
    case sourceEpochRequired
    case formatEpochRequired
    case notRunning
}

public enum LifecycleEvent: Equatable, Sendable {
    case queued
    case resolving
    case resolved(ResolvedProcess)
    case guarding
    case guardReady(GuardAcquisition)
    case preparing
    case prepared(StreamFormat)
    case starting
    case running(StreamFormat)
    case condition(CaptureCondition)
    case stopping(StopReason)
    case stopped(StopReason, TeardownOutcome?, LeaseRelease?)
    case failed(RuntimeFailure, TeardownOutcome?, LeaseRelease?)
    case refused(Refusal)
}

public struct LifecycleObservation: Equatable, Sendable {
    public let assignment: AssignmentID
    public let token: PlanToken?
    public let event: LifecycleEvent
    public init(assignment: AssignmentID, token: PlanToken?, event: LifecycleEvent) {
        self.assignment = assignment
        self.token = token
        self.event = event
    }
}

@MainActor
public protocol ProcessResolving {
    func resolve(binding: AppBinding, preferredPID: Int32?) async throws -> ResolvedProcess
    func revalidate(_ process: ResolvedProcess) async throws
}

@MainActor
public protocol CaptureResource: AnyObject {}

@MainActor
public struct CapturePreparation {
    public let format: StreamFormat
    public let resource: (any CaptureResource)?
    public init(format: StreamFormat, resource: (any CaptureResource)? = nil) {
        self.format = format
        self.resource = resource
    }
}

@MainActor
public protocol CaptureSession: AnyObject {
    func prepare(source: ResolvedProcess) async throws -> CapturePreparation
    func start() async throws
    func stop() async -> TeardownOutcome
}

@MainActor
public protocol CaptureSessionFactory {
    func makeSession() -> any CaptureSession
}

import Foundation

public enum GuardEngagement: Equatable, Sendable {
    case engaged(fromUID: String?, toUID: String?)
    case declined(reason: String)
}

public enum GuardRestoration: Equatable, Sendable {
    case noMarker
    case markerCleared
    case markerRetained
}

public struct GuardAcquisition: Equatable, Sendable {
    public let engagement: GuardEngagement
    public let shared: Bool
    public let recovery: GuardRestoration
}

public enum LeaseRelease: Equatable, Sendable {
    case otherLeasesRemain
    case lastLease(GuardRestoration)
    case alreadyReleased
}

public struct InputGuardLease: Hashable, Sendable {
    fileprivate let id: UUID
}

@MainActor
public protocol InputGuardPort {
    func recoverIfStranded() async -> GuardRestoration
    func engage(settingEnabled: Bool) async -> GuardEngagement
    func restore() async -> GuardRestoration
}

@MainActor
public final class InputGuardLeaseCoordinator {
    private let port: any InputGuardPort
    private let settingEnabled: Bool
    private var tail: Task<Void, Never>?
    private var leases: Set<InputGuardLease> = []
    private var recovery: GuardRestoration?
    private var engagement: GuardEngagement?

    public init(port: any InputGuardPort, settingEnabled: Bool) {
        self.port = port
        self.settingEnabled = settingEnabled
    }

    public var activeLeaseCount: Int { leases.count }

    public func acquire() async -> (lease: InputGuardLease, observation: GuardAcquisition) {
        let previous = tail
        let operation = Task { @MainActor in
            await previous?.value
            if self.recovery == nil {
                self.recovery = await self.port.recoverIfStranded()
            }
            let shared = !self.leases.isEmpty
            if !shared {
                self.engagement = await self.port.engage(settingEnabled: self.settingEnabled)
            }
            let lease = InputGuardLease(id: UUID())
            self.leases.insert(lease)
            return (lease, GuardAcquisition(engagement: self.engagement!, shared: shared,
                                             recovery: self.recovery!))
        }
        tail = Task { _ = await operation.value }
        return await operation.value
    }

    public func release(_ lease: InputGuardLease) async -> LeaseRelease {
        let previous = tail
        let operation = Task { @MainActor in
            await previous?.value
            guard self.leases.remove(lease) != nil else { return LeaseRelease.alreadyReleased }
            guard self.leases.isEmpty else { return .otherLeasesRemain }
            let restoration = await self.port.restore()
            self.engagement = nil
            return .lastLease(restoration)
        }
        tail = Task { _ = await operation.value }
        return await operation.value
    }
}

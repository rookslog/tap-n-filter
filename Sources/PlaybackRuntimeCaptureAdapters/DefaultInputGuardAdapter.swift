import Capture
import Foundation
import PlaybackRuntime

@MainActor
public final class DefaultInputGuardAdapter: InputGuardPort {
    private let guardOwner: DefaultInputGuard
    private let defaults: UserDefaults

    public init(control: any DefaultInputControlling, defaults: UserDefaults,
                log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.guardOwner = DefaultInputGuard(control: control, defaults: defaults, log: log)
    }

    public func recoverIfStranded() async -> GuardRestoration {
        let hadMarker = markerPresent
        await guardOwner.recoverIfStranded(captureActive: false)
        return result(hadMarker: hadMarker)
    }

    public func engage(settingEnabled: Bool) async -> GuardEngagement {
        let outcome = await guardOwner.engageIfNeeded(settingEnabled: settingEnabled)
        if outcome.engaged { return .engaged(fromUID: outcome.fromUID, toUID: outcome.toUID) }
        return .declined(reason: outcome.reason ?? "unspecified-decline")
    }

    public func restore() async -> GuardRestoration {
        let hadMarker = markerPresent
        await guardOwner.restore(trigger: "playback-runtime-last-lease")
        return result(hadMarker: hadMarker)
    }

    private var markerPresent: Bool {
        defaults.string(forKey: DefaultInputGuard.strandedInputMarkerKey) != nil
    }

    private func result(hadMarker: Bool) -> GuardRestoration {
        if markerPresent { return .markerRetained }
        return hadMarker ? .markerCleared : .noMarker
    }
}

import Foundation

/// What a card's app is doing, as the card's icon and accessibility value need it (waiting state).
/// A card with no entry behaves as it did before: the icon follows the switch alone.
public struct MenuLaneActivity: Equatable, Sendable {
    /// The app's sound is running through TNF. The icon is in colour only while this is true.
    public let isRunning: Bool
    /// Spoken after the app's name when it is not running; nil leaves the name as it was.
    public let accessibilityValue: String?

    public init(isRunning: Bool, accessibilityValue: String? = nil) {
        self.isRunning = isRunning
        self.accessibilityValue = accessibilityValue
    }

    public static let running = MenuLaneActivity(isRunning: true)
    /// Starting, stopping, failed or off: not running, nothing extra to say.
    public static let notRunning = MenuLaneActivity(isRunning: false)
    /// The coarse state of a lane, as the playback controller reports it.
    public enum Phase: Equatable, Sendable { case running, waiting, other }

    /// One entry per lane. A waiting lane carries the accessibility value "not playing"; a running or other lane
    /// carries none. `bundles` is accepted for callers that have it and is not used.
    public static func cards(
        _ phases: [UUID: Phase], bundles: [UUID: String] = [:]
    ) -> [UUID: MenuLaneActivity] {
        var cards: [UUID: MenuLaneActivity] = [:]
        for (id, phase) in phases {
            switch phase {
            case .running: cards[id] = .running
            case .waiting: cards[id] = .waiting
            case .other: cards[id] = .notRunning
            }
        }
        return cards
    }

    /// Waiting for the app's audio: not running, spoken as "not playing".
    public static let waiting = MenuLaneActivity(isRunning: false, accessibilityValue: "not playing")
}

/// The icon rule: in colour exactly when the app's sound is running through TNF. It goes grey only after the
/// lane has been not running for `delay`, so a route change or restart does not blink it, and returns to
/// colour at once. An off card's icon is grey at once, as before. Time is passed in so a check can drive it.
struct MenuIconSettle: Equatable {
    static let delay: TimeInterval = 0.6
    static let fade: TimeInterval = 0.2

    private(set) var isColoured: Bool
    /// The two numbers the card's icon is drawn with, from one place so a check reads what the view uses.
    var saturation: Double { Self.saturation(isColoured: isColoured) }
    var opacity: Double { Self.opacity(isColoured: isColoured) }
    /// Whether the icon is drawn in colour now. A switch turned off, or a lane that is running, takes effect at
    /// once; only the move to grey of an on card that stopped running waits for the settle delay.
    func shows(on: Bool, running: Bool?) -> Bool { on && (running != false || isColoured) }
    static func saturation(isColoured: Bool) -> Double { isColoured ? 1 : 0 }
    static func opacity(isColoured: Bool) -> Double { isColoured ? 1 : 0.5 }
    private var notRunningSince: TimeInterval?

    /// `running` is nil for a card with no lane information: the icon then follows `on` alone.
    init(on: Bool, running: Bool?) {
        isColoured = on && running != false
        notRunningSince = nil
    }

    /// Feeds the card's current state at `now`.
    mutating func update(on: Bool, running: Bool?, now: TimeInterval) {
        guard on else { isColoured = false; notRunningSince = nil; return }
        if running != false { isColoured = true; notRunningSince = nil; return }
        guard isColoured else { return }
        let since = notRunningSince ?? now
        notRunningSince = since
        if now - since >= Self.delay { isColoured = false; notRunningSince = nil }
    }

    /// When the icon should next be re-evaluated, if a grey-out is pending.
    var deadline: TimeInterval? { notRunningSince.map { $0 + Self.delay } }
}

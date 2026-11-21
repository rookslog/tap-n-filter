// Real-code fixture for the event-table checks: a seeded library session, a menu presentation fed by
// the session's own publications, a persistence port that can hold or refuse one write, and gates.
// Ordering is by gates and completion signals. `quiet()` is the one place that waits without a
// named signal: mid-sequence the gates hold work that the session's own quiescence would wait for.

import Foundation
import AppKit
import SoundModel
@testable import EverydayMenu
import PlaybackRenderBridge
@testable import tap_n_filter

enum TableError: Error { case setup(String) }

/// Which caller a projection read belongs to. Editor completion reads run inside the editor query's
/// own task; driver reads are the explicit refreshes a sequence asks for. Everything else is an
/// automatic menu refresh and parks at the publication gate.
enum ReadTag { @TaskLocal static var current: String? = nil }
/// Set around a menu change's send (click, keyboard step, drag sample). The coordinator's tasks inherit it, so
/// ordered work started by that change carries it and the release's own commit does not.
enum ChangeTag {
    struct Target: Equatable, Sendable { let address: LibraryControlAddress; let position: LibraryPosition }
    @TaskLocal static var current: Target? = nil
}

/// `failApply`: the next admitted change fails to apply, on whichever route it takes. The fast parameter path
/// is reached through the coordinator's apply-failure hook; every ordered route through the coordinator's
/// `menuMove` override (test side only).
@MainActor final class FailNext {
    var armed = false
    /// Consumes the armed failure, if any.
    func fire() throws { if armed { armed = false; throw TableError.setup("injected apply failure") } }
}

/// Parks every caller until released. `open` lets callers straight through.
actor TableGate {
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var watchers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var arrivals = 0
    private(set) var open = false
    func pass() async {
        if open { return }
        await withCheckedContinuation { c in
            parked.append(c); arrivals += 1
            let ready = watchers.filter { arrivals > $0.0 }; watchers.removeAll { arrivals > $0.0 }
            for w in ready { w.1.resume() }
        }
    }
    /// Returns once more than `count` callers have arrived.
    func arrived(after count: Int) async {
        if arrivals > count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }
    func releaseAll() { let p = parked; parked = []; for c in p { c.resume() } }
    func setOpen(_ value: Bool) { open = value; if value { releaseAll() } }
    var parkedCount: Int { parked.count }
}

/// Persistence port: the next write can be held (parks) and, independently, refused.
actor TablePort: LibraryPersistence {
    var bytes: Data?
    private(set) var log: [Bool] = []          // one entry per completed write: refused?
    private var holdNext = false
    private var refuseNext = false
    private(set) var parked = 0
    let gate = TableGate()
    init(_ bytes: Data? = nil) { self.bytes = bytes }
    func load() -> Data? { bytes }
    func hold() { holdNext = true }
    func refuse() { refuseNext = true }
    func disarm() { holdNext = false; refuseNext = false }
    func commit(_ value: Data) async -> LibraryWriteOutcome {
        // A write decides refusal when it starts, as the model does (A-S5/A-S6).
        let refused = refuseNext; refuseNext = false
        if holdNext { holdNext = false; parked += 1; await gate.pass(); parked -= 1 }
        log.append(refused)
        if refused { return .refused(.io("refused by the test port")) }
        bytes = value
        return .committed
    }
}

/// Projection reads, tagged by caller. Counts every attempt.
actor TableReads {
    private(set) var owner: SoundLibrarySession?
    private(set) var attempts = 0
    private var failEditor = false
    private var holdEditor = false
    let menuGate = TableGate()
    /// Holds an editor completion after it has read the state and before it can publish (I6 cases).
    let completionGate = TableGate()
    func armEditorFailure() { failEditor = true }
    func armCompletionHold() { holdEditor = true }
    func disarm() { failEditor = false; holdEditor = false }
    func read(_ owner: SoundLibrarySession, tag: String?) async throws -> LibraryMenuState {
        self.owner = owner; attempts += 1
        switch tag {
        case "editor":
            if failEditor { failEditor = false; throw TableError.setup("injected editor read failure") }
            if holdEditor {
                holdEditor = false
                let state = try await owner.menuState()
                await completionGate.pass()
                return state
            }
        case "driver": break
        default: await menuGate.pass()
        }
        return try await owner.menuState()
    }
}

/// What the menu shows, fed only by the session's publications.
@MainActor final class TableSurface {
    weak var app: LibraryAppSession?
    var view: MenuPresentation?
    var actions: [EverydayMenuAction] = []
    var fullChanges = 0, contextChanges = 0, attentionChanges = 0
    var problems: [String?] = []
    func full() {
        fullChanges += 1
        problems.append(app?.problem)
        guard let app, let presentation = app.presentation, let data = app.menuData else { return }
        if view == nil {
            view = MenuPresentation(presentation: presentation, glyph: NSImage(size: NSSize(width: 1, height: 1)),
                perform: { [weak self] in self?.actions.append($0); self?.app?.send($0) })
        }
        view?.positionContext = app.coordinator.positionContext
        if view?.snapshot != data { view?.snapshot = data }
    }
    func attention() { attentionChanges += 1; problems.append(app?.problem) }
    func context(_ c: MenuPositionContext) { contextChanges += 1; view?.installPositionContext(c) }
    func positions(_ delta: LibraryMenuDelta, _ c: MenuPositionContext) -> Bool { view?.applyPositions(delta, context: c) ?? false }
}

/// Holds the next ordered menu move (the drag's commit at release) until released. Unarmed it passes.
actor MoveHold {
    private var armed = false
    let gate = TableGate()
    func arm() { armed = true }
    func pass() async { if armed { armed = false; await gate.pass() } }
}

@MainActor final class TableFixture {
    let app: LibraryAppSession
    let surface: TableSurface
    let reads: TableReads
    let port: TablePort
    let debounce = TableGate()
    let failNext = FailNext()
    let owner: SoundLibrarySession
    let otherDefinitions: [UUID]       // definitions to alternate on the second app (structural commands)
    var playbackDeliveries = 0
    var lastPlayback: ListeningRenderSnapshot?        // what playback last received
    var lastCompare: Bool?                            // the compare flag playback last received
    var deliveryModes: [LibraryDeliveryMode] = []     // every delivery's mode, in order
    var deliveredSnapshots: [ListeningRenderSnapshot] = []

    init(attachCounter: Bool = true, moveHold: MoveHold? = nil) async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = TablePort()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else {
            throw TableError.setup("seed")
        }
        let definitions = try await seedOwner.snapshot().definitions
        guard let everyday = definitions.first(where: { $0.name == "Everyday" }), let filters = definitions.first(where: { $0.name == "Filters" }) else {
            throw TableError.setup("builtin definitions")
        }
        _ = try await seedOwner.select(everyday.id, on: "com.apple.Safari")
        _ = try await seedOwner.select(filters.id, on: "test.other")
        _ = try await seedOwner.checkpoint()
        let port = TablePort(await seed.bytes), reads = TableReads(), surface = TableSurface(), debounce = self.debounce
        let failNext = self.failNext
        await reads.menuGate.setOpen(true)
        let app = LibraryAppSession(changed: { surface.full() }, attentionChanged: { surface.attention() },
            contextChanged: { surface.context($0) }, positionsChanged: { surface.positions($0, $1) },
            read: { owner in let tag = ReadTag.current; return try await reads.read(owner, tag: tag) },
            checkpointDelay: { await debounce.pass(); try Task.checkCancellation() },
            menuMove: { session, address, expected, option, value in
                if let moveHold { await moveHold.pass() }
                if let tag = ChangeTag.current, tag.address == address, tag.position == value {
                    try failNext.fire()                              // failApply on the change's own ordered route
                }
                return try await session.moveForMenu(address, expected: expected, optionGesture: option, to: value)
            })
        surface.app = app
        await app.start(persistence: port, limits: limits)
        guard let owner = await reads.owner else { throw TableError.setup("owner") }
        self.app = app; self.surface = surface; self.reads = reads; self.port = port; self.owner = owner
        otherDefinitions = [everyday.id, filters.id]
        if attachCounter { _ = await app.coordinator.attachPlayback { [weak self] snapshot, compare, mode in self?.playbackDeliveries += 1; self?.lastPlayback = snapshot; self?.lastCompare = compare; self?.deliveryModes.append(mode); self?.deliveredSnapshots.append(snapshot) } }
        surface.full()
        await reads.menuGate.setOpen(false)
        guard surface.view != nil else { throw TableError.setup("menu view") }
    }

    var view: MenuPresentation { surface.view! }
    /// The card the menu shows now for the first app.
    var shownCard: MenuSoundCard { view.snapshot.assignments.first { $0.bundleIdentifier == "com.apple.Safari" }! }
    func slider(on card: MenuSoundCard) -> MenuSoundControl? { (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.title == "Softer" } }
    func choice(on card: MenuSoundCard) -> MenuSoundControl? {
        card.controls.first { if case .choice = $0.face { return true }; return false }
    }

    /// Yields and round-trips to the owner until nothing observable changes for two rounds.
    /// Returns false if it never settles.
    @discardableResult
    func quiet(rounds: Int = 60) async -> Bool {
        // `quiescent()` can't be used here: mid-sequence the gates hold reads, writes or the debounce, and it
        // waits for all of them. It is used when settling, once every gate is open (AdmissionDriver.drain).
        var last: [Int] = [], stable = 0
        for _ in 0..<rounds {
            for _ in 0..<8 { await Task.yield() }
            _ = try? await owner.liveState()
            let signature = [await reads.attempts, await reads.menuGate.arrivals, await port.log.count, await port.parked,
                             await debounce.arrivals, surface.fullChanges, surface.contextChanges, surface.attentionChanges, playbackDeliveries]
            if signature == last { stable += 1; if stable >= 2 { return true } } else { stable = 0; last = signature }
        }
        return false
    }

    /// Values of the first app's slider and choice in a library snapshot.
    func positions(_ snapshot: LibrarySnapshot, slider: MenuSoundControl, choice: MenuSoundControl) -> (Double?, Double?) {
        guard let use = snapshot.uses.first(where: { $0.target == "com.apple.Safari" }) else { return (nil, nil) }
        func scalar(_ p: LibraryPosition?) -> Double? { if case .scalar(let v)? = p { return v }; return nil }
        return (scalar(use.positions[slider.id]), scalar(use.positions[choice.id]))
    }
    func reopenedSnapshot() async throws -> LibrarySnapshot {
        let reopened = try await SoundLibrarySession(persistence: TablePort(await port.bytes), limits: LibraryAppSession.normalLimits())
        return try await reopened.snapshot()
    }
    func close() async {
        app.close()
        await debounce.setOpen(true); await port.gate.setOpen(true); await reads.menuGate.setOpen(true)
    }
}

@MainActor final class WatchBox<T> {
    var continuation: CheckedContinuation<T?, Never>?
    func finish(_ value: T?) -> Bool {
        guard let c = continuation else { return false }
        continuation = nil; c.resume(returning: value); return true
    }
}
/// Turns a hang into a named failure. It orders nothing: the timer only decides when to stop
/// waiting for a signal that never came. A hung body is left behind with its fixture.
var watchdogFirings = 0
@MainActor func watched<T>(_ label: String, seconds: Double = 10, _ body: @escaping @MainActor () async -> T) async -> T? {
    let box = WatchBox<T>()
    return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        box.continuation = c
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled, box.finish(nil) { watchdogFirings += 1; print("WATCHDOG \(label) did not complete in \(seconds) s") }
        }
        Task { @MainActor in let v = await body(); if box.finish(v) { timer.cancel() } }
    }
}

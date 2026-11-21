// Real-code fixture for the drag-commit reset checks: a seeded library session, a menu presentation fed by the
// session's own publications, a persistence port that can hold one write, a playback recorder, an observer wired to
// the coordinator's and session's callbacks, and a fault that the ordered menu-move override can inject into one
// drag commit. The count runs with no fault armed.

import Foundation
import AppKit
import SoundModel
@testable import EverydayMenu
import PlaybackRenderBridge
@testable import tap_n_filter

struct ResetError: Error, CustomStringConvertible { let description: String }

let draggedApp = "com.apple.Safari"
let otherApp = "test.other"

actor ResetPort: LibraryPersistence {
    private(set) var data: Data?
    private(set) var writes = 0
    private var holdNext = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var parked: Int { held.count }
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    /// The next write parks until `release()`.
    func holdNextWrite() { holdNext = true }
    func release() { let waiting = held; held = []; for c in waiting { c.resume() } }
    func commit(_ value: Data) async -> LibraryWriteOutcome {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in held.append(continuation) }
        }
        writes += 1; data = value; return .committed
    }
}

/// Outcomes of ordered moves, by what the session returned.
struct Tally {
    var ok = 0, noChange = 0, superseded = 0, threw = 0
    var total: Int { ok + superseded + threw }
    mutating func record(_ outcome: LibraryLiveMutation) {
        switch outcome {
        case .superseded: superseded += 1
        case .noChange: ok += 1; noChange += 1
        case .changed: ok += 1
        }
    }
    mutating func add(_ other: Tally) {
        ok += other.ok; noChange += other.noChange; superseded += other.superseded; threw += other.threw
    }
}

/// One fault for one drag commit, recognised by the commit's control and value (the drag's last live sample). The
/// override consumes it at that ordered move. The count never arms one.
@MainActor final class FaultArm {
    enum Kind { case throwIt, supersede }
    private var kind: Kind?
    private var address: LibraryControlAddress?
    private var value: Double?
    private(set) var fired = 0
    var armed: Bool { kind != nil }
    func arm(_ kind: Kind, address: LibraryControlAddress, value: Double) {
        self.kind = kind; self.address = address; self.value = value
    }
    func take(_ address: LibraryControlAddress, _ position: LibraryPosition) -> Kind? {
        guard let kind, address == self.address, let expected = value, case .scalar(let x) = position,
              abs(x - expected) < 1e-12 else { return nil }
        self.kind = nil; fired += 1
        return kind
    }
}

@MainActor final class ResetObserver {
    /// Drag commits that returned, by outcome (the coordinator's commit callback).
    var commits = Tally()
    /// Resets the coordinator reported to the session: thrown (a problem) or superseded (none).
    var thrownResets = 0, supersededResets = 0
    var resets: Int { thrownResets + supersededResets }
    /// Value writes the coordinator found stale and dropped (requested seam).
    var staleDrops = 0
    /// Every ordered menu move that reached the session through the override (drag commits included), by outcome.
    var ordered = Tally()
    var orderedSupersededDragged = 0, orderedSupersededChoice = 0, orderedSupersededOther = 0
    var draggedAddress: LibraryControlAddress?
    var choiceAddress: LibraryControlAddress?
    /// Drag samples delivered live.
    var liveSamples = 0
    /// What the session told its measurement callback, in order.
    var completed: [LibraryLiveMutation] = []
    var debounces = 0
    var reads = 0
    var deliveries: [(mode: LibraryDeliveryMode, snapshot: ListeningRenderSnapshot)] = []
    var problemAppearances = 0
    var admitted: [String: Int] = [:], refused: [String: Int] = [:], failed: [String: Int] = [:]
    var whileDragging: [String: Int] = [:]

    func noteDebounce() { debounces += 1 }
    /// The session's owner, captured from the first read.
    var owner: SoundLibrarySession?
    func noteRead(_ owner: SoundLibrarySession) { reads += 1; self.owner = owner }
    func noteOrdered(_ address: LibraryControlAddress, _ outcome: LibraryLiveMutation) {
        ordered.record(outcome)
        guard outcome == .superseded else { return }
        if address == draggedAddress { orderedSupersededDragged += 1 }
        else if address == choiceAddress { orderedSupersededChoice += 1 }
        else { orderedSupersededOther += 1 }
    }
    var activations: Int { deliveries.filter { $0.mode == .activation }.count }
}

@MainActor final class ResetSurface {
    weak var app: LibraryAppSession?
    var observer: ResetObserver?
    var view: MenuPresentation?
    var lastGesture: UUID?
    private var lastProblem: String?
    private func noteProblem() {
        let problem = app?.problem
        if problem != nil, problem != lastProblem { observer?.problemAppearances += 1 }
        lastProblem = problem
    }
    func full() {
        noteProblem()
        guard let app, let presentation = app.presentation, let data = app.menuData else { return }
        if view == nil {
            view = MenuPresentation(presentation: presentation, glyph: NSImage(size: NSSize(width: 1, height: 1)),
                perform: { [weak self] action in
                    if case .beginMenuGesture(let id) = action { self?.lastGesture = id }
                    self?.app?.send(action)
                })
        }
        view?.positionContext = app.coordinator.positionContext
        if view?.snapshot != data { view?.snapshot = data }
    }
    func attention() { noteProblem() }
    func positions(_ delta: LibraryMenuDelta, _ context: MenuPositionContext) -> Bool {
        view?.applyPositions(delta, context: context) ?? false
    }
}

/// Which control drag G holds: the top-level Softer slider, or the child slider of the clicked parent choice's
/// current option (the parent starts on an option that owns it, and every click moves the parent off that option).
enum DragTarget: String, CaseIterable { case top, child }

@MainActor final class ResetFixture {
    let app: LibraryAppSession
    let surface: ResetSurface
    let port: ResetPort
    let observer: ResetObserver
    let fault: FaultArm
    let everyday: UUID
    let filters: UUID
    let choiceAddress: LibraryControlAddress
    let choiceTitle: String
    let choiceParentOptions: Int
    let target: DragTarget
    private(set) var childControl: MenuSoundControl?
    private(set) var childOption: UUID?
    /// The discard epoch once setup is done (requested seam).
    private(set) var startEpoch: LibraryDiscardEpoch?

    init(target: DragTarget, observer: ResetObserver, fault: FaultArm) async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = ResetPort()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else {
            throw ResetError(description: "seed library did not open fresh")
        }
        let definitions = try await seedOwner.snapshot().definitions
        guard let everyday = definitions.first(where: { $0.name == "Everyday" }), let filters = definitions.first(where: { $0.name == "Filters" }) else {
            throw ResetError(description: "builtin definitions missing")
        }
        _ = try await seedOwner.select(everyday.id, on: draggedApp)
        _ = try await seedOwner.select(filters.id, on: otherApp)
        _ = try await seedOwner.checkpoint()
        let port = ResetPort(await seed.data), surface = ResetSurface()
        surface.observer = observer
        let app = LibraryAppSession(changed: { surface.full() },
            attentionChanged: { surface.attention() },
            contextChanged: { surface.view?.installPositionContext($0) },
            positionsChanged: { surface.positions($0, $1) },
            read: { owner in await observer.noteRead(owner); return try await owner.menuState() },
            checkpointDelay: { await observer.noteDebounce(); await Task.yield(); try Task.checkCancellation() },
            menuMove: { session, address, expected, option, value in
                if let kind = fault.take(address, value) {
                    switch kind {
                    case .throwIt: throw ResetError(description: "injected drag-commit failure")
                    case .supersede: return .superseded
                    }
                }
                do {
                    let result = try await session.moveForMenu(address, expected: expected, optionGesture: option, to: value)
                    observer.noteOrdered(address, result.outcome)
                    return result
                } catch {
                    observer.ordered.threw += 1
                    throw error
                }
            })
        surface.app = app
        await app.start(persistence: port, limits: limits)
        _ = await app.coordinator.attachPlayback { snapshot, _, mode in observer.deliveries.append((mode, snapshot)) }
        surface.full()
        guard let view = surface.view else { throw ResetError(description: "menu view was not built") }

        guard let card = view.snapshot.assignments.first(where: { $0.bundleIdentifier == draggedApp }),
              ResetFixture.slider(on: card) != nil, let choice = ResetFixture.choice(on: card),
              case .choice(let options) = choice.face else {
            throw ResetError(description: "the dragged app's card needs the Softer slider and a choice")
        }
        let parents = options.filter { !(choice.optionChildren[$0.id] ?? []).isEmpty }
        guard parents.count >= 2 else {
            throw ResetError(description: "the clicked choice (\(choice.title)) has fewer than two options with child controls")
        }
        self.app = app; self.surface = surface; self.port = port; self.observer = observer; self.fault = fault
        self.everyday = everyday.id; self.filters = filters.id
        choiceAddress = choice.address; choiceTitle = choice.title; choiceParentOptions = parents.count
        self.target = target

        if target == .child {
            // Put the parent on its first child-owning option. The pick is followed by a debounced save, which clears
            // live-sample eligibility until the next read, so wait until the child is shown, eligible and has a live
            // plan on two checks in a row.
            guard let identity = card.menuIdentity, let epoch = card.menuEpoch, let owning = parents.first else {
                throw ResetError(description: "the dragged app's card has no menu identity for the child setup")
            }
            app.send(.menuMove(identity, epoch, choice.address, choice.optionGesture, .scalar(owning.position)))
            var found: MenuSoundControl?, why = "not checked", passes = 0
            for _ in 0..<12 {
                _ = await watched("child setup") { await app.quiescent() }
                let coordinator = app.coordinator
                _ = await watched("child setup saves") { await coordinator.waitForIssuedSaves() }
                for _ in 0..<16 { await Task.yield() }
                _ = await coordinator.refresh()
                for _ in 0..<8 { await Task.yield() }
                guard let shown = shownCard, let binding = shown.binding, let shownIdentity = shown.menuIdentity,
                      let tab = shown.optionTabs.first(where: { $0.parent == choice.address && $0.option.id == owning.id }),
                      let child = tab.controls.first, case .slider = child.face else {
                    why = "the card does not show the child slider"; passes = 0; continue
                }
                guard coordinator.sliderCanCoalesce(child.address, expected: binding, optionGesture: child.optionGesture) else {
                    why = "the child slider is not eligible for live samples"; passes = 0; continue
                }
                let planned = app.presentation?.parameterPlans.contains { plan in
                    plan.identity == shownIdentity && plan.address == child.address && plan.option == child.optionGesture && plan.lease.isValid
                } ?? false
                guard planned else { why = "the child slider has no live plan"; passes = 0; continue }
                passes += 1
                if passes >= 2 { found = child; break }
            }
            guard let child = found else { throw ResetError(description: "child setup: \(why)") }
            childControl = child; childOption = owning.id
        }
        // Setup traffic is not part of any check.
        observer.ordered = Tally(); observer.orderedSupersededDragged = 0; observer.orderedSupersededChoice = 0
        observer.orderedSupersededOther = 0; observer.deliveries = []; observer.completed = []
        observer.debounces = 0; observer.reads = 0; observer.problemAppearances = 0

        observer.choiceAddress = choice.address
        observer.draggedAddress = childControl?.address ?? ResetFixture.slider(on: card)?.address
        let coordinator = app.coordinator
        coordinator.perfParameterEvaluated = { _, _ in observer.liveSamples += 1 }
        coordinator.perfParameterDocumentCommit = { outcome in observer.commits.record(outcome) }
        // Requested seam: told each time a value write is found stale and dropped.
        coordinator.staleWriteDroppedForTesting = { observer.staleDrops += 1 }
        let reportReset = coordinator.dragCommitFailed
        coordinator.dragCommitFailed = { problem in
            if problem == nil { observer.supersededResets += 1 } else { observer.thrownResets += 1 }
            reportReset?(problem)
        }
        app.perfMutationCompleted = { outcome in observer.completed.append(outcome) }
        let address = choiceAddress
        app.admissionDecided = { [weak coordinator] action, outcome in
            let kind: String
            switch action {
            case .gestureMove: kind = "move"
            case .menuMove(_, _, let moved, _, _): kind = moved == address ? "click" : "nudge"
            default: kind = "other"
            }
            switch outcome {
            case .admitted:
                observer.admitted[kind, default: 0] += 1
                if coordinator?.isDragging == true { observer.whileDragging[kind, default: 0] += 1 }
            case .superseded: observer.refused[kind, default: 0] += 1
            case .failed: observer.failed[kind, default: 0] += 1
            }
        }
        startEpoch = coordinator.discardEpochForTesting
    }

    /// The card the menu shows now for the dragged app, if it still shows one.
    var shownCard: MenuSoundCard? { surface.view?.snapshot.assignments.first { $0.bundleIdentifier == draggedApp } }
    static func slider(on card: MenuSoundCard, title: String = "Softer") -> MenuSoundControl? {
        (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.title == title }
    }
    /// The card's first top-level choice. On the quick-menu Everyday sound this is Place.
    static func choice(on card: MenuSoundCard) -> MenuSoundControl? {
        card.controls.first { if case .choice = $0.face { return true }; return false }
    }
    /// The epoch has not moved since setup.
    var epochUnmoved: Bool { app.coordinator.discardEpochForTesting == startEpoch }
    /// The epoch moved exactly once since setup.
    var epochMovedOnce: Bool { startEpoch.map { app.coordinator.discardEpochForTesting == $0.next } ?? false }

    /// The dragged app's value of a control in the live document and in the saved bytes.
    func documentValue(_ control: LibraryControlAddress) async -> Double? {
        guard let owner = observer.owner, let snapshot = try? await owner.snapshot() else { return nil }
        return Self.value(of: control, in: snapshot)
    }
    func savedValue(_ control: LibraryControlAddress) async -> Double? {
        guard let reopened = try? await SoundLibrarySession(persistence: ResetPort(await port.data), limits: LibraryAppSession.normalLimits()),
              let snapshot = try? await reopened.snapshot() else { return nil }
        return Self.value(of: control, in: snapshot)
    }
    static func value(of control: LibraryControlAddress, in snapshot: LibrarySnapshot) -> Double? {
        guard let use = snapshot.uses.first(where: { $0.target == draggedApp }),
              case .scalar(let v)? = use.positions[control.control] else { return nil }
        return v
    }
    func close() { app.close() }
}

@MainActor final class WatchBox {
    var continuation: CheckedContinuation<Bool, Never>?
    func finish(_ value: Bool) -> Bool {
        guard let c = continuation else { return false }
        continuation = nil; c.resume(returning: value); return true
    }
}
/// Turns a hang into a named, counted failure. It orders nothing: the timer only decides when to stop waiting.
@MainActor func watched(_ label: String, seconds: Double = 20, _ body: @escaping @MainActor () async -> Void) async -> Bool {
    let box = WatchBox()
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        box.continuation = c
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled, box.finish(false) { print("COMMIT-RESET-WATCHDOG \(label) did not finish in \(Int(seconds)) s") }
        }
        Task { @MainActor in await body(); if box.finish(true) { timer.cancel() } }
    }
}

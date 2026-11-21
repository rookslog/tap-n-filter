// Real-code fixture for the drag-commit outcome count: a seeded library session, a menu presentation fed by the
// session's own publications, an always-accepting persistence port, and a counter wired to the coordinator's
// commit-site seam and to its ordered menu-move override. Nothing here holds a read, a write or a debounce.

import Foundation
import AppKit
import SoundModel
@testable import EverydayMenu
@testable import tap_n_filter

struct CountError: Error, CustomStringConvertible { let description: String }

let draggedApp = "com.apple.Safari"
let otherApp = "test.other"

actor CountPort: LibraryPersistence {
    private(set) var data: Data?
    private(set) var writes = 0
    init(_ data: Data? = nil) { self.data = data }
    func load() -> Data? { data }
    func commit(_ value: Data) async -> LibraryWriteOutcome { writes += 1; data = value; return .committed }
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

@MainActor final class OutcomeCounter {
    /// A fault for the self-check only. The real count never arms one.
    enum Fault { case off, throwNext, supersedeNext }
    var fault: Fault = .off
    /// Set by the commit-site seam just before the drag commit's ordered move reaches the override.
    var dragCommitEntering = false
    var dragStarted = 0
    /// Drag commits: counted at the commit site, so an injected fault is counted like a real one.
    var drag = Tally()
    /// Every other ordered menu move (a click's or a step's own move), counted in the override.
    var other = Tally()
    /// Admission receipts by event kind ("move", "click", "nudge").
    var admitted: [String: Int] = [:]
    var refused: [String: Int] = [:]
    var failed: [String: Int] = [:]
    /// Events that landed while a drag was held: admitted clicks, steps and samples, and issued selects and removes.
    var whileDragging: [String: Int] = [:]
    var unfinished: Int { dragStarted - drag.total }
}

@MainActor final class CountSurface {
    weak var app: LibraryAppSession?
    var view: MenuPresentation?
    var lastGesture: UUID?
    func full() {
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
    func positions(_ delta: LibraryMenuDelta, _ context: MenuPositionContext) -> Bool {
        view?.applyPositions(delta, context: context) ?? false
    }
}

/// Which control drag G holds: the top-level Softer slider, or the child slider of the clicked parent choice's
/// current option (the parent starts on an option that owns it, and every click moves the parent off that option).
enum DragTarget: String, CaseIterable { case top, child }

@MainActor final class CountFixture {
    let app: LibraryAppSession
    let surface: CountSurface
    let port: CountPort
    let counter: OutcomeCounter
    let everyday: UUID
    let filters: UUID
    /// The clicked control's address, so receipts can tell a click from a keyboard step.
    let choiceAddress: LibraryControlAddress
    let choiceTitle: String
    /// How many of the clicked choice's options own a child control.
    let choiceParentOptions: Int
    let target: DragTarget
    /// Child target only: the dragged child control and the parent option that owns it.
    private(set) var childControl: MenuSoundControl?
    private(set) var childOption: UUID?

    init(counter: OutcomeCounter, target: DragTarget = .top) async throws {
        let limits = try LibraryAppSession.normalLimits(), seed = CountPort()
        guard case .fresh(let seedOwner) = await SoundLibrarySession.open(persistence: seed, limits: limits, builtins: .quickMenu) else {
            throw CountError(description: "seed library did not open fresh")
        }
        let definitions = try await seedOwner.snapshot().definitions
        guard let everyday = definitions.first(where: { $0.name == "Everyday" }), let filters = definitions.first(where: { $0.name == "Filters" }) else {
            throw CountError(description: "builtin definitions missing")
        }
        _ = try await seedOwner.select(everyday.id, on: draggedApp)
        _ = try await seedOwner.select(filters.id, on: otherApp)
        _ = try await seedOwner.checkpoint()
        let port = CountPort(await seed.data), surface = CountSurface()
        let app = LibraryAppSession(changed: { surface.full() },
            contextChanged: { surface.view?.installPositionContext($0) },
            positionsChanged: { surface.positions($0, $1) },
            checkpointDelay: { await Task.yield(); try Task.checkCancellation() },
            menuMove: { session, address, expected, option, value in
                let isDragCommit = counter.dragCommitEntering
                counter.dragCommitEntering = false
                if isDragCommit {
                    switch counter.fault {
                    case .throwNext: counter.fault = .off; throw CountError(description: "injected drag-commit failure")
                    case .supersedeNext: counter.fault = .off; return .superseded
                    case .off: return try await session.moveForMenu(address, expected: expected, optionGesture: option, to: value)
                    }
                }
                do {
                    let result = try await session.moveForMenu(address, expected: expected, optionGesture: option, to: value)
                    counter.other.record(result.outcome)
                    return result
                } catch {
                    counter.other.threw += 1
                    throw error
                }
            })
        surface.app = app
        await app.start(persistence: port, limits: limits)
        _ = await app.coordinator.attachPlayback { _, _, _ in }
        surface.full()
        guard let view = surface.view else { throw CountError(description: "menu view was not built") }

        // The count is only meaningful if the clicked control is a parent choice: its options own child controls.
        guard let card = view.snapshot.assignments.first(where: { $0.bundleIdentifier == draggedApp }),
              CountFixture.slider(on: card) != nil, let choice = CountFixture.choice(on: card),
              case .choice(let options) = choice.face else {
            throw CountError(description: "the dragged app's card needs the Softer slider and a choice")
        }
        let parents = options.filter { !(choice.optionChildren[$0.id] ?? []).isEmpty }
        guard parents.count >= 2 else {
            throw CountError(description: "the clicked choice (\(choice.title)) has fewer than two options with child controls")
        }
        self.app = app; self.surface = surface; self.port = port; self.counter = counter
        self.everyday = everyday.id; self.filters = filters.id
        choiceAddress = choice.address; choiceTitle = choice.title; choiceParentOptions = parents.count
        self.target = target

        if target == .child {
            // Put the parent on its first child-owning option, so the card shows that option's child slider.
            guard let identity = card.menuIdentity, let epoch = card.menuEpoch, let owning = parents.first else {
                throw CountError(description: "the dragged app's card has no menu identity for the child setup")
            }
            app.send(.menuMove(identity, epoch, choice.address, choice.optionGesture, .scalar(owning.position)))
            let settled = await watched("child setup") { await app.quiescent() }
            for _ in 0..<16 { await Task.yield() }
            _ = await app.coordinator.refresh()
            guard settled, let shown = shownCard,
                  let tab = shown.optionTabs.first(where: { $0.parent == choice.address && $0.option.id == owning.id }),
                  let child = tab.controls.first, case .slider = child.face else {
                throw CountError(description: "the parent choice did not show its child slider for the child drag")
            }
            childControl = child; childOption = owning.id
            counter.other = Tally()     // the setup pick is not part of the count
        }

        app.coordinator.parameterCommitForTesting = { event in
            switch event {
            case .started: counter.dragStarted += 1; counter.dragCommitEntering = true
            case .finished(let outcome): counter.drag.record(outcome)
            case .threw: counter.drag.threw += 1
            }
        }
        let address = choiceAddress, coordinator = app.coordinator
        app.admissionDecided = { [weak coordinator] action, outcome in
            let kind: String
            switch action {
            case .gestureMove: kind = "move"
            case .menuMove(_, _, let moved, _, _): kind = moved == address ? "click" : "nudge"
            default: kind = "other"
            }
            switch outcome {
            case .admitted:
                counter.admitted[kind, default: 0] += 1
                if coordinator?.isDragging == true { counter.whileDragging[kind, default: 0] += 1 }
            case .superseded: counter.refused[kind, default: 0] += 1
            case .failed: counter.failed[kind, default: 0] += 1
            }
        }
    }

    /// The card the menu shows now for the dragged app, if it still shows one.
    var shownCard: MenuSoundCard? { surface.view?.snapshot.assignments.first { $0.bundleIdentifier == draggedApp } }
    static func slider(on card: MenuSoundCard) -> MenuSoundControl? {
        (card.controls + card.optionTabs.flatMap(\.controls)).first { $0.title == "Softer" }
    }
    /// The card's first top-level choice. On the quick-menu Everyday sound this is Place.
    static func choice(on card: MenuSoundCard) -> MenuSoundControl? {
        card.controls.first { if case .choice = $0.face { return true }; return false }
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
            if !Task.isCancelled, box.finish(false) { print("COMMIT-OUTCOMES-WATCHDOG \(label) did not finish in \(Int(seconds)) s") }
        }
        Task { @MainActor in await body(); if box.finish(true) { timer.cancel() } }
    }
}

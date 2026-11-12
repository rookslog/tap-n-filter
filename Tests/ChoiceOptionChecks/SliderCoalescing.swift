import Foundation
import EverydayMenu
import SessionStore
@testable import SoundModel
#if SWIFT_PACKAGE
@testable import tap_n_filter
#endif

struct SliderFailure: Error { let message: String }
func demand(_ value: Bool, _ name: String) throws {
    guard value else { throw SliderFailure(message: name) }
    print("PASS \(name)")
}
struct MoveEvent: Sendable {
    let address: LibraryControlAddress
    let position: LibraryPosition
    var outcome: LibraryLiveMutation?
}
actor SliderGate {
    private var armed = false
    private var entered = false
    private var entrants: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    private(set) var events: [MoveEvent] = []
    func arm() { armed = true; entered = false; events = [] }
    func reset() { events = [] }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { entrants.append($0) }
    }
    func release() { held?.resume(); held = nil }
    func execute(_ owner: SoundLibrarySession, _ address: LibraryControlAddress, _ binding: LibraryBinding,
                 _ option: LibraryOptionGesture?, _ position: LibraryPosition) async throws -> LibraryLiveMutation {
        let index = events.count
        events.append(MoveEvent(address: address, position: position))
        if armed {
            armed = false; entered = true
            for entrant in entrants { entrant.resume() }; entrants = []
            await withCheckedContinuation { held = $0 }
        }
        let result: LibraryLiveMutation
        if let option { result = try await owner.move(address, expected: binding, optionGesture: option, to: position) }
        else { result = try await owner.move(address, expected: binding, to: position) }
        events[index].outcome = result
        return result
    }
}
actor StructuralGate {
    private var entered = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        for arrival in arrivals { arrival.resume() }; arrivals = []
        await withCheckedContinuation { held = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrivals.append($0) } } }
    func release() { held?.resume(); held = nil }
}
actor SliderStore: LibraryPersistence {
    let file: LibrarySessionFile
    private(set) var outcomes: [String] = []
    init(_ url: URL) { file = LibrarySessionFile(url: url, maximumBytes: 4_000_000) }
    func load() async throws -> Data? { try await file.load() }
    func commit(_ bytes: Data) async -> LibraryWriteOutcome {
        let result = await file.commit(bytes); outcomes.append(String(describing: result)); return result
    }
}

struct SliderCoalescingChecks {
    @MainActor static func fixture(_ root: URL, unknown: Bool = false) async throws -> (LibraryAppSession, SliderGate, SliderStore, URL) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.json"), store = SliderStore(root.appendingPathComponent("library.json"))
        let gate = SliderGate()
        let app = LibraryAppSession(changed: {}, read: { owner in
            let snapshot = try await owner.menuState()
            guard unknown else { return snapshot }
            var uses = snapshot.uses
            for index in uses.indices { uses[index].directSliderControls = nil }
            return LibraryMenuState(ownerID: snapshot.ownerID, liveGeneration: snapshot.liveGeneration,
                stateRevision: snapshot.stateRevision, live: snapshot.live,
                definitions: snapshot.definitions, uses: uses, assignments: snapshot.assignments)
        }, checkpointDelay: { try await Task.sleep(for: .seconds(30)) },
            move: { try await gate.execute($0, $1, $2, $3, $4) })
        await app.start(persistence: store, limits: try LibraryAppSession.normalLimits())
        return (app, gate, store, url)
    }
    @MainActor static func card(_ app: LibraryAppSession) -> MenuSoundCard { app.menuData!.assignments[0] }
    @MainActor static func settled(_ app: LibraryAppSession) async throws -> LibrarySnapshot {
        let (value, _) = try await app.coordinator.editorQuery { try await $0.snapshot() }
        while !(await app.coordinator.refresh()) { await Task.yield() }
        return value
    }
    @MainActor static func save(_ app: LibraryAppSession, _ url: URL) async throws -> LibrarySnapshot {
        app.send(.endGesture)
        _ = await app.gestureSave?.value; await app.coordinator.waitForIssuedSaves()
        app.beginDrain()
        guard case .saved = await app.finishDrain(.save) else { throw SliderFailure(message: "final drain") }
        app.close()
        let owner = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: 4_000_000),
                                                  limits: try LibraryAppSession.normalLimits())
        return try await owner.snapshot()
    }
    @MainActor static func run(_ root: URL) async throws {
        setbuf(stdout, nil)
        do {
            let (app, gate, store, url) = try await fixture(root.appendingPathComponent("latest"))
            let card = card(app), slider = card.controls.first { $0.title == "Softer" }!, binding = card.binding!
            let initialWrites = await store.outcomes.filter { $0 == "committed" }.count
            var coalesced = 0, maxFlight = 0, maxPending = 0
            app.coordinator.perfSliderCoalesced = { coalesced += 1 }
            app.coordinator.perfSliderQueueChanged = { maxFlight = max(maxFlight, $0); maxPending = max(maxPending, $1) }
            app.send(.beginGesture); await gate.arm()
            app.send(.libraryMove(binding, slider.address, .scalar(0.1))); await gate.wait()
            for index in 1..<900 { app.send(.libraryMove(binding, slider.address, .scalar(0.1 + 0.8 * Double(index) / 899))) }
            try demand(coalesced == 898 && maxFlight == 1 && maxPending == 1,
                       "900 requested slow-owner scalar moves retain one flight/one latest pending with898 explicit replacements")
            app.send(.endGesture)
            await gate.release(); _ = await app.gestureSave?.value; await app.coordinator.waitForIssuedSaves()
            let value = try await settled(app), events = await gate.events
            try demand(events.map(\.position) == [.scalar(0.1), .scalar(0.9)] && events.allSatisfy { $0.outcome == .changed },
                       "release runs only original in-flight and latest final value, never pending old positions")
            try demand(value.uses[0].positions[slider.id] == .scalar(0.9) && !value.isEnabled,
                       "query joins the actual latest scalar value and retains OFF")
            try demand(await store.outcomes.filter { $0 == "committed" }.count == initialWrites + 1,
                       "release makes one actual committed save after the latest owner move")
            let reopened = try await save(app, url)
            try demand(reopened.uses[0].positions[slider.id] == .scalar(0.9) && reopened.assignments[0].parts == value.assignments[0].parts,
                       "save/reopen retains exact latest scalar and rendered physical parameters")
            let measuredOwner = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: 4_000_000), limits: LibraryAppSession.normalLimits())
            let measurement = try await measuredOwner.measuredMove(slider.address, expected: binding, to: .scalar(0.8))
            let measuredSnapshot = try await measuredOwner.snapshot()
            try demand(measurement.outcome == .changed && measurement.finishedUptime >= measurement.startedUptime
                       && measuredSnapshot.uses[0].positions[slider.id] == .scalar(0.8),
                       "owner-body measurement executes actual scalar operation and records ordered monotonic timestamps, no timing threshold")
        }
        do {
            let (app, gate, _, url) = try await fixture(root.appendingPathComponent("barriers"))
            let card = card(app), binding = card.binding!, softer = card.controls.first { $0.title == "Softer" }!
            let volume = card.controls.first { $0.title == "Volume" }!
            app.send(.beginGesture); await gate.arm()
            app.send(.libraryMove(binding, softer.address, .scalar(0.2))); await gate.wait()
            app.send(.libraryMove(binding, softer.address, .scalar(0.4)))
            let checkpoint = app.coordinator.submitCheckpoint()
            app.send(.libraryMove(binding, softer.address, .scalar(0.6)))
            app.send(.libraryMove(binding, volume.address, .scalar(0.3)))
            app.send(.libraryMove(binding, softer.address, .scalar(0.9)))
            await gate.release(); _ = await checkpoint.value
            _ = try await settled(app)
            let events = await gate.events
            try demand(events.map(\.position) == [.scalar(0.2), .scalar(0.4), .scalar(0.6), .scalar(0.3), .scalar(0.9)],
                       "checkpoint and different-control barriers retain all ordered segment finals")
            let wrong = LibraryBinding(assignment: UUID(), use: binding.use, target: binding.target)
            let stale = try app.coordinator.submitSliderMove(softer.address, expected: wrong, to: .scalar(0))
            guard case .executed(.superseded) = try await stale.value else { throw SliderFailure(message: "stale exact binding") }
            try demand(true, "coalesced route rechecks exact assignment/use/target at actual execution")
            app.send(.libraryMove(binding, softer.address, .scalar(0.7)))
            app.beginDrain()
            guard case .saved = await app.finishDrain(.save) else { throw SliderFailure(message: "unreleased drain") }
            app.close()
            let reader = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: 4_000_000), limits: try LibraryAppSession.normalLimits())
            try demand(try await reader.snapshot().uses[0].positions[softer.id] == .scalar(0.7), "unreleased drain saves latest admitted value")
            do { _ = try app.coordinator.submitSliderMove(softer.address, expected: binding, to: .scalar(0)); throw SliderFailure(message: "closed admission") }
            catch LibraryConsumerLifecycleError.unavailable(.closed) { print("PASS retired owner refuses late slider before scheduling") }
        }
        do {
            let (app, _, _, url) = try await fixture(root.appendingPathComponent("shipped-classification"))
            let use = app.presentation!.uses[0]
            let sliders = use.controls.filter { if case .slider = $0.face { return true }; return false }
                .map { LibraryControlAddress(path: [], control: $0.id) }
            try demand(sliders.count == 7 && use.directSliderControls?.count == sliders.count
                       && sliders.allSatisfy { use.directSliderControls!.contains($0) },
                       "coherent compiled facts prove both quick root sliders and all five child sliders are direct")
            let filters = app.presentation!.definitions.first { $0.builtin == .filters }!
            _ = await app.coordinator.submitSelect(filters.id, on: card(app).bundleIdentifier).value
            _ = try await settled(app)
            let filterCard = card(app), filterUse = app.presentation!.uses.first { $0.id == filterCard.binding!.use }!
            try demand(filterCard.controls.count == 6 && filterUse.directSliderControls?.count == 6
                       && filterCard.controls.allSatisfy { app.coordinator.sliderCanCoalesce($0.address, expected: filterCard.binding!) },
                       "all six shipped Filters scalar controls have direct facts and coherent coalescing eligibility")
            _ = try await save(app, url)
        }
        do {
            let (app, gate, _, url) = try await fixture(root.appendingPathComponent("unknown-classification"), unknown: true)
            let c = card(app), slider = c.controls.first { $0.title == "Softer" }!, binding = c.binding!
            var replacements = 0; app.coordinator.perfSliderCoalesced = { replacements += 1 }
            try demand(!app.coordinator.sliderCanCoalesce(slider.address, expected: binding), "unknown compiled facts fail closed despite scalar UI metadata")
            app.send(.beginGesture); await gate.arm()
            app.send(.libraryMove(binding, slider.address, .scalar(0.2))); await gate.wait()
            app.send(.libraryMove(binding, slider.address, .scalar(0.4)))
            app.send(.libraryMove(binding, slider.address, .scalar(0.9)))
            await gate.release(); _ = try await settled(app)
            let events = await gate.events
            try demand(replacements == 0 && events.map(\.position) == [.scalar(0.2), .scalar(0.4), .scalar(0.9)],
                       "unknown eligibility preserves every ordered scalar hand update")
            _ = try await save(app, url)
        }
        do {
            let (app, gate, _, url) = try await fixture(root.appendingPathComponent("new-incoming-link"))
            let c = card(app), slider = c.controls.first { $0.title == "Softer" }!, binding = c.binding!
            app.send(.beginGesture); app.send(.libraryMove(binding, slider.address, .scalar(0.5)))
            _ = try await settled(app)
            try demand(app.coordinator.sliderCanCoalesce(slider.address, expected: binding), "initial coherent builtin scalar eligibility is direct")
            let barrier = StructuralGate(), first = UUID(), second = UUID()
            let mutation = try app.coordinator.enqueueMutation { owner in
                var edit = try await owner.beginEdit(.use(binding), admission: { _ in })
                for (id, title) in [(first, "First"), (second, "Second")] {
                    edit = try await owner.edit(edit.handle, expectedGeneration: edit.generation,
                        command: .mapping(path: [], .create(.slider(id: id, title: title, initial: 0.5, waypoints: [0, 0.5, 1]))))
                }
                let lane = try LibraryMappingLane(points: [LibraryLanePoint(0, 0), LibraryLanePoint(1, 1)], stretches: [.straight])
                for source in [first, second] {
                    let link = UUID()
                    edit = try await owner.edit(edit.handle, expectedGeneration: edit.generation,
                        command: .mapping(path: [], .connect(id: link, source: LibraryMappingSource(source),
                            target: .control(site: nil, control: slider.id, axis: .value))))
                    edit = try await owner.edit(edit.handle, expectedGeneration: edit.generation,
                        command: .mapping(path: [], .lane(binding: link, option: nil, lane: lane)))
                }
                for source in [first, second] {
                    _ = try await owner.move(LibraryControlAddress(path: [], control: source), expected: binding, to: .scalar(1))
                }
                _ = try await owner.checkpoint()
                await barrier.pause()
            }
            await barrier.wait(); await gate.reset()
            let referenceOwner = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: 4_000_000),
                                                               limits: LibraryAppSession.normalLimits())
            for position in [0.9, 0.7, 0.8] { _ = try await referenceOwner.move(slider.address, expected: binding, to: .scalar(position)) }
            let referencePosition = try await referenceOwner.snapshot().uses.first { $0.id == binding.use }!.positions[slider.id]
            try demand(app.presentation!.uses.first { $0.id == binding.use }!.hasLocalDraft == false
                       && !app.coordinator.sliderCanCoalesce(slider.address, expected: binding),
                       "new incoming link invalidates eligibility before stale UI snapshot or held structural mutation can be trusted")
            app.send(.libraryMove(binding, slider.address, .scalar(0.9)))
            app.send(.libraryMove(binding, slider.address, .scalar(0.7)))
            app.send(.libraryMove(binding, slider.address, .scalar(0.8)))
            await barrier.release(); _ = try await mutation.value
            let snapshot = try await settled(app), events = await gate.events
            let changed = snapshot.uses.first { $0.id == binding.use }!
            print("DRIVEN events=\(events.map(\.position)) final=\(String(describing: changed.positions[slider.id])) direct=\(String(describing: changed.directSliderControls?.contains(slider.address))) eligible=\(app.coordinator.sliderCanCoalesce(slider.address, expected: binding))")
            try demand(events.map(\.position) == [.scalar(0.9), .scalar(0.7), .scalar(0.8)]
                       && changed.positions[slider.id] == referencePosition
                       && changed.directSliderControls?.contains(slider.address) == false
                       && !app.coordinator.sliderCanCoalesce(slider.address, expected: binding),
                       "stale-UI/new-link hand stream matches actual ordered reference owner; coherent incoming classification stays refused")
            let reopened = try await save(app, url)
            try demand(reopened.uses.first { $0.id == binding.use }!.positions[slider.id] == referencePosition,
                       "driven legacy hand result survives actual save/reopen without semantic retune")
        }
        do {
            let f = try await Fixture(root.appendingPathComponent("original-driven-counterexample"))
            let first = UUID(), second = UUID(), target = UUID()
            for (id, title) in [(first, "First"), (second, "Second"), (target, "Target")] {
                try await f.map(.create(.slider(id: id, title: title, initial: 0.5, waypoints: [0, 0.5, 1])))
            }
            let lane = try LibraryMappingLane(points: [LibraryLanePoint(0, 0), LibraryLanePoint(1, 1)], stretches: [.straight])
            for source in [first, second] {
                let link = UUID()
                try await f.map(.connect(id: link, source: LibraryMappingSource(source), target: .control(site: nil, control: target, axis: .value)))
                try await f.map(.lane(binding: link, option: nil, lane: lane))
            }
            _ = try await f.publish(); let binding = try await f.attach("test.counterexample")
            for source in [first, second] { _ = try await f.session.move(LibraryControlAddress(path: [], control: source), expected: binding, to: .scalar(1)) }
            _ = try await f.session.checkpoint()
            let gate = SliderGate(), address = LibraryControlAddress(path: [], control: target)
            let app = LibraryAppSession(changed: {}, move: { try await gate.execute($0, $1, $2, $3, $4) })
            await app.start(persistence: f.port, limits: f.limits)
            try demand(app.presentation!.uses.first { $0.id == binding.use }!.directSliderControls?.contains(address) == false
                       && !app.coordinator.sliderCanCoalesce(address, expected: binding),
                       "original counterexample target is authoritatively incoming, not a coalescible scalar")
            app.send(.beginGesture); await gate.arm()
            app.send(.libraryMove(binding, address, .scalar(0.9))); await gate.wait()
            app.send(.libraryMove(binding, address, .scalar(0.7)))
            app.send(.libraryMove(binding, address, .scalar(0.8)))
            let latest = try await SoundLibrarySession(persistence: LibrarySessionFile(url: f.file, maximumBytes: 8_000_000), limits: f.limits)
            for position in [0.9, 0.8] { _ = try await latest.move(address, expected: binding, to: .scalar(position)) }
            let incorrectLatest = try await latest.snapshot().uses.first { $0.id == binding.use }!.positions[target]
            await gate.release(); let ordered = try await settled(app), events = await gate.events
            try demand(events.map(\.position) == [.scalar(0.9), .scalar(0.7), .scalar(0.8)]
                       && ordered.uses.first { $0.id == binding.use }!.positions[target] == .scalar(0.9)
                       && incorrectLatest == .scalar(1),
                       "actual menu-owner route preserves original ordered0.9 counterexample; unsafe latest-only reference remains1.0")
            _ = try await save(app, f.file)
        }
        for index in 0..<5 {
            let (app, gate, _, url) = try await fixture(root.appendingPathComponent("child-\(index)"))
            let relation = app.presentation!.uses[0].optionControls[index]
            var card = card(app); let binding = card.binding!
            let parent = card.controls.first { $0.address == relation.parent }!
            guard case .choice(let options) = parent.face, let selected = options.firstIndex(where: { $0.id == relation.option }) else {
                throw SliderFailure(message: "actual option metadata")
            }
            app.send(.beginGesture)
            app.send(.libraryMove(binding, parent.address, .scalar(options[selected].position)))
            _ = try await settled(app); card = self.card(app)
            let child = card.optionTabs.flatMap(\.controls).first { $0.address == relation.child }!
            let context = child.optionGesture!
            try demand(app.coordinator.sliderCanCoalesce(child.address, expected: binding, optionGesture: context),
                       "\(child.title) active exact option context has coherent direct eligibility")
            var coalesced = 0; app.coordinator.perfSliderCoalesced = { coalesced += 1 }
            await gate.arm()
            app.send(.libraryOptionMove(binding, child.address, context, .scalar(0.2))); await gate.wait()
            app.send(.libraryOptionMove(binding, child.address, context, .scalar(0.4)))
            app.send(.libraryOptionMove(binding, child.address, context, .scalar(0.9)))
            let next = options[(selected + 1) % options.count]
            app.send(.libraryMove(binding, parent.address, .scalar(next.position)))
            app.send(.libraryOptionMove(binding, child.address, context, .scalar(0.1)))
            await gate.release()
            let value = try await settled(app), events = await gate.events
            try demand(coalesced == 1 && events.map(\.position) == [.scalar(0.2), .scalar(0.9), .scalar(next.position), .scalar(0.1)],
                       "\(child.title) same-context scalar child is latest-wins; parent choice seals old context in order")
            try demand(events.last?.outcome == .superseded && value.uses[0].positions[child.id] == .scalar(0.9),
                       "\(child.title) stale option context refuses without overwriting old option's latest value")
            let reopened = try await save(app, url)
            try demand(reopened.uses[0].positions[child.id] == .scalar(0.9) && !reopened.isEnabled,
                       "\(child.title) latest per-option child survives actual save/reopen OFF")
            let measuredOwner = try await SoundLibrarySession(persistence: LibrarySessionFile(url: url, maximumBytes: 4_000_000), limits: LibraryAppSession.normalLimits())
            _ = try await measuredOwner.move(parent.address, expected: binding, to: .scalar(options[selected].position))
            let measurement = try await measuredOwner.measuredMove(child.address, expected: binding, optionGesture: context, to: .scalar(0.8))
            let measuredSnapshot = try await measuredOwner.snapshot()
            try demand(measurement.outcome == .changed && measurement.finishedUptime >= measurement.startedUptime
                       && measuredSnapshot.uses[0].positions[child.id] == .scalar(0.8),
                       "\(child.title) actual owner-body measurement retains option-context semantics without dispatch timing fiction")
        }
        print("PASS gated-owner latest-wins and ordered identity/context/save barriers; no fake100ms claim")
    }
}

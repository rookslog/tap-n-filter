import Foundation
@testable import SoundModel
import SessionStore

/// A library store in memory whose writes can be held open, so a check can act while a save is pending.
actor QMSHeldStore: LibraryPersistence {
    private(set) var data: Data?
    private(set) var pending = 0
    private var holding = false

    init(data: Data? = nil) { self.data = data }

    func load() async throws -> Data? { data }

    func commit(_ data: Data) async -> LibraryWriteOutcome {
        if holding {
            pending += 1
            // Held until `release()`, ten seconds at most so a broken check cannot hang the run.
            var waited = 0
            while holding && waited < 1_000 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
            pending -= 1
        }
        if self.data == data { return .identical }
        self.data = data
        return .committed
    }

    func hold() { holding = true }
    func release() { holding = false }

    /// Waits, a bounded time, until a write is being held open.
    func waitForHeldWrite() async -> Bool {
        for _ in 0..<500 {
            if pending > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

extension QMSSession {
    static func open(_ store: QMSHeldStore, existing: Bool, scratch: URL) async throws -> QMSSession {
        switch await SoundLibrarySession.open(persistence: store, limits: QMS.limits, builtins: .quickMenu) {
        case .fresh(let session) where !existing: return QMSSession(session: session, file: scratch)
        case .existing(let session) where existing: return QMSSession(session: session, file: scratch)
        default: throw QMSFailure("a Quick Menu library in memory did not open as \(existing ? "existing" : "fresh")")
        }
    }
}

extension QuickMenuSoundsChecks {
    // 12. Per-app memory when one app switches between two sounds during a gesture or a save.
    // The app keeps one use per sound. A gesture value addressed to the sound the app has just
    // left must not land anywhere, and a save that is still being written when the app switches
    // must leave the stored library in a state that reopens to the same thing.
    static func switchMemoryGroup(_ c: QMSContext) async throws {
        let r = c.report
        let scratch = c.scratch.appendingPathComponent("switch")
        let store = QMSHeldStore()
        var s = try await QMSSession.open(store, existing: false, scratch: scratch)
        let app = "switch.app", bigRef = "switch.ref.big-space", oldRef = "switch.ref.old-recording"
        try await s.select("Big space", on: bigRef)
        try await s.select("Old recording", on: oldRef)

        // Big space on the app, Hall's "Where you stand" at 0.2; the reference sounds the same.
        try await s.select("Big space", on: app)
        try await s.choose("Space", "Hall", on: app)
        r.check(try await s.moveChild("Space", "Hall", on: app, to: 0.2) == .changed, "Big space Hall moves on the app")
        try await s.choose("Space", "Hall", on: bigRef)
        _ = try await s.moveChild("Space", "Hall", on: bigRef, to: 0.2)
        let bigBinding = try await s.binding(app)
        guard let hall = try await s.relation("Space", "Hall", on: app) else { r.fail("Big space Hall carries a sub-control"); return }
        let hallGesture = LibraryOptionGesture(parent: hall.parent, option: hall.option)

        // A gesture is under way on Big space when the app switches to Old recording; its next value arrives late.
        try await s.select("Old recording", on: app)
        let oldBinding = try await s.binding(app)
        r.check(oldBinding.use != bigBinding.use, "switching the app to Old recording gives it its own use")
        var late: LibraryLiveMutation? = nil
        do { late = try await s.session.move(hall.child, expected: bigBinding, optionGesture: hallGesture, to: .scalar(0.8)) } catch {}
        r.check(late != .changed, "a Big space gesture value arriving after the switch is refused (got \(late.map { "\($0)" } ?? "an error"))")
        r.check(try await s.native(app).parts == (try await s.native(oldRef).parts),
                "the late Big space value does not reach Old recording")
        let keptBig = try await s.use(app, sound: "Big space")
        r.check(keptBig?.positions[hall.child.control] == .scalar(0.2),
                "the app keeps Big space Hall at 0.2 while it plays Old recording, got \(String(describing: keptBig?.positions[hall.child.control]))")

        // On Old recording: Tape's Wear at 0.9. Then back to Big space, and a late Tape value.
        try await s.choose("Era", "Tape", on: app)
        r.check(try await s.moveChild("Era", "Tape", on: app, to: 0.9) == .changed, "Old recording Tape moves on the app after the switch")
        try await s.choose("Era", "Tape", on: oldRef)
        _ = try await s.moveChild("Era", "Tape", on: oldRef, to: 0.9)
        guard let tape = try await s.relation("Era", "Tape", on: app) else { r.fail("Old recording Tape carries a sub-control"); return }
        let tapeBinding = try await s.binding(app)
        try await s.select("Big space", on: app)
        late = nil
        do {
            late = try await s.session.move(tape.child, expected: tapeBinding,
                optionGesture: LibraryOptionGesture(parent: tape.parent, option: tape.option), to: .scalar(0.1))
        } catch {}
        r.check(late != .changed, "an Old recording gesture value arriving after the switch back is refused (got \(late.map { "\($0)" } ?? "an error"))")
        r.check(try await s.binding(app).use == bigBinding.use, "switching back to Big space returns the app to its Big space use")
        r.check(try await s.position(hall.child.control, on: app) == 0.2, "Big space Hall is still at 0.2 after the round trip")
        r.check(try await s.native(app).parts == (try await s.native(bigRef).parts), "the app sounds as Big space Hall at 0.2 after the round trip")
        r.check(try await s.use(app, sound: "Old recording")?.positions[tape.child.control] == .scalar(0.9),
                "the app keeps Old recording Tape at 0.9, untouched by the late value")

        // A save held open while the app switches. First a plain save, then an unsaved change the held
        // save will carry (Hall to 0.3). The switch starts only once that write is pending.
        _ = try await s.session.checkpoint()
        let savedBefore = await store.data
        _ = try await s.moveChild("Space", "Hall", on: app, to: 0.3)
        _ = try await s.moveChild("Space", "Hall", on: bigRef, to: 0.3)
        await store.hold()
        let held = s
        async let saving = held.session.checkpoint()
        let pending = await store.waitForHeldWrite()
        r.check(pending, "a save is being written when the app switches")
        async let switching = held.select("Old recording", on: app)
        try? await Task.sleep(nanoseconds: 100_000_000)
        r.check(await store.data == savedBefore, "while the save is held, the stored library is still the last one saved")
        await store.release()
        _ = try await saving
        _ = try await switching

        // The stored library now, before any further save: reopened on its own, it must hold the switch.
        guard let stored = await store.data else { r.fail("the stored library is present after the held save"); return }
        let reread = try await QMSSession.open(QMSHeldStore(data: stored), existing: true, scratch: scratch)
        let oldID = try await s.definition("Old recording").id
        r.check(try await reread.session.snapshot().assignments.first { $0.target == app }?.definition == oldID,
                "stored straight after the held save and the switch: the app plays Old recording")
        r.check(try await reread.use(app, sound: "Old recording")?.positions[tape.child.control] == .scalar(0.9),
                "stored straight after the held save and the switch: Old recording Tape at 0.9")
        r.check(try await reread.use(app, sound: "Big space")?.positions[hall.child.control] == .scalar(0.3),
                "stored straight after the held save and the switch: the kept Big space Hall at 0.3, the held save's value")
        r.check(try await reread.native(app).parts == (try await s.native(oldRef).parts),
                "stored straight after the held save and the switch: the app sounds as Old recording Tape at 0.9")
        let liveOld = try await s.use(app, sound: "Old recording")?.positions, storedOld = try await reread.use(app, sound: "Old recording")?.positions
        let liveBig = try await s.use(app, sound: "Big space")?.positions, storedBig = try await reread.use(app, sound: "Big space")?.positions
        r.check(liveOld == storedOld && liveBig == storedBig, "the stored positions for both sounds equal the session's")

        // Reopened from the stored bytes, switching back finds Big space as it was left.
        s = reread
        try await s.select("Big space", on: app)
        r.check(try await s.position(hall.child.control, on: app) == 0.3, "after reopening and switching back, Big space Hall is at 0.3")
        r.check(try await s.native(app).parts == (try await s.native(bigRef).parts),
                "after reopening and switching back, the app sounds as Big space Hall at 0.3")
    }
}

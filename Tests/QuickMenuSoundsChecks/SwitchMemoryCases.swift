import Foundation
@testable import SoundModel
import SessionStore

extension QuickMenuSoundsChecks {
    // 12. Per-app memory when one app switches between two sounds during a gesture or a save.
    // The app keeps one use per sound. A gesture value addressed to the sound the app has just
    // left must not land anywhere, and a save that overlaps a switch must reopen to the same state:
    // the current sound, its positions, and the positions the app keeps for the other sound.
    static func switchMemoryGroup(_ c: QMSContext) async throws {
        let r = c.report
        let file = c.scratch.appendingPathComponent("switch/library.json")
        var s = try await QMSSession.fresh(file)
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

        // A save that overlaps a switch. Whichever lands first, the saved file reopens to the state the session ends in.
        let session = s.session
        async let overlapping = session.checkpoint()
        try await s.select("Old recording", on: app)
        _ = try await overlapping
        _ = try await s.session.checkpoint()
        let activeDefinition = try await s.session.snapshot().assignments.first { $0.target == app }?.definition
        let oldPositions = try await s.use(app, sound: "Old recording")?.positions
        let bigPositions = try await s.use(app, sound: "Big space")?.positions
        let sounding = try await s.native(app).parts
        r.check(activeDefinition == (try await s.definition("Old recording")).id, "the app plays Old recording after the overlapping save and switch")
        r.check(sounding == (try await s.native(oldRef).parts), "the app sounds as Old recording Tape at 0.9 before reopening")

        s = try await QMSSession.reopen(file)
        r.check(try await s.session.snapshot().assignments.first { $0.target == app }?.definition == activeDefinition,
                "after reopening, the app still plays Old recording")
        r.check(try await s.use(app, sound: "Old recording")?.positions == oldPositions, "after reopening, the app's Old recording positions are as saved")
        r.check(try await s.use(app, sound: "Big space")?.positions == bigPositions, "after reopening, the app's kept Big space positions are as saved")
        r.check(try await s.native(app).parts == sounding, "after reopening, the app sounds as it did")
        try await s.select("Big space", on: app)
        r.check(try await s.position(hall.child.control, on: app) == 0.2, "after reopening and switching back, Big space Hall is at 0.2")
        r.check(try await s.native(app).parts == (try await s.native(bigRef).parts),
                "after reopening and switching back, the app sounds as Big space Hall at 0.2")
    }
}

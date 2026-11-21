import Foundation
@testable import SoundModel
import SessionStore

extension QuickMenuSoundsChecks {
    // 7. Memory: each sub-control keeps its own position per option per app, acts only while
    // its option is chosen, and survives the app's positions being saved and read back.
    static func memoryGroup(_ c: QMSContext) async throws {
        let r = c.report
        let file = c.scratch.appendingPathComponent("memory/library.json")
        var s = try await QMSSession.fresh(file)
        let pairs: [(sound: String, choice: String, first: String, second: String, plain: String?)] = [
            ("Big space", "Space", "Hall", "Church", nil),
            ("Old recording", "Era", "Vinyl", "Tape", "Shellac"),
        ]
        var expected: [(target: String, control: UUID, value: Double, label: String)] = []
        var expectedNative: [String: [ListeningRenderPart]] = [:]
        for pair in pairs {
            let slug = pair.sound.replacingOccurrences(of: " ", with: "-").lowercased()
            let a = "memory.a." + slug, b = "memory.b." + slug, ref = "memory.ref." + slug
            for target in [a, b, ref] { try await s.select(pair.sound, on: target) }
            guard let firstChild = try await s.childControl(pair.choice, pair.first, on: a),
                  let secondChild = try await s.childControl(pair.choice, pair.second, on: a) else {
                r.fail("\(pair.sound) has sub-controls under \(pair.first) and \(pair.second)"); continue
            }
            try await s.choose(pair.choice, pair.first, on: a)
            r.check(try await s.moveChild(pair.choice, pair.first, on: a, to: 0.2) == .changed, "\(pair.sound) \(pair.first) sub-control moves while chosen")
            try await s.choose(pair.choice, pair.second, on: a)
            r.check(try await s.moveChild(pair.choice, pair.second, on: a, to: 0.9) == .changed, "\(pair.sound) \(pair.second) sub-control moves while chosen")
            r.check(try await s.position(firstChild.id, on: a) == 0.2, "\(pair.sound) \(pair.first) keeps 0.2 after \(pair.second)'s moved")
            r.check(try await s.position(secondChild.id, on: a) == 0.9, "\(pair.sound) \(pair.second) holds 0.9")
            let otherFirst = try await s.position(firstChild.id, on: b), otherSecond = try await s.position(secondChild.id, on: b)
            r.check(otherFirst == 0.5 && otherSecond == 0.5,
                    "\(pair.sound) another app's sub-controls stay at 0.5")

            // Hidden: a gesture on the unchosen option's sub-control is refused and changes nothing.
            let refused = try await s.moveChild(pair.choice, pair.first, on: a, to: 0.7)
            r.check(refused == .superseded, "\(pair.sound) \(pair.first) sub-control does not move while \(pair.second) is chosen (got \(refused))")
            r.check(try await s.position(firstChild.id, on: a) == 0.2, "\(pair.sound) refused move left \(pair.first) at 0.2")

            // Acts only while chosen: the second option sounds as if the first's value were default.
            try await s.choose(pair.choice, pair.second, on: ref)
            _ = try await s.moveChild(pair.choice, pair.second, on: ref, to: 0.9)
            r.check(try await s.native(a).parts == (try await s.native(ref).parts),
                    "\(pair.sound) \(pair.first)'s value does nothing while \(pair.second) is chosen")
            if let plain = pair.plain {
                try await s.choose(pair.choice, plain, on: a)
                try await s.choose(pair.choice, plain, on: ref)
                r.check(try await s.native(a).parts == (try await s.native(ref).parts),
                        "\(pair.sound) \(plain) ignores both other options' sub-control values")
            }
            try await s.choose(pair.choice, pair.first, on: a)
            try await s.choose(pair.choice, pair.first, on: ref)
            _ = try await s.moveChild(pair.choice, pair.first, on: ref, to: 0.2)
            r.check(try await s.position(firstChild.id, on: a) == 0.2, "\(pair.sound) returning to \(pair.first) restores 0.2")
            r.check(try await s.native(a).parts == (try await s.native(ref).parts),
                    "\(pair.sound) returning to \(pair.first) sounds as \(pair.first) at 0.2 regardless of \(pair.second)'s value")
            expected += [(a, firstChild.id, 0.2, "\(pair.sound) \(pair.first) on app A"),
                         (a, secondChild.id, 0.9, "\(pair.sound) \(pair.second) on app A"),
                         (b, firstChild.id, 0.5, "\(pair.sound) \(pair.first) on app B"),
                         (b, secondChild.id, 0.5, "\(pair.sound) \(pair.second) on app B")]
            expectedNative[a] = try await s.native(a).parts
        }
        try await s.select("Underwater", on: "memory.a.underwater")
        try await s.moveRow("Depth", on: "memory.a.underwater", to: 0.35)
        let depth = try await s.control("Depth", on: "memory.a.underwater")
        expected.append(("memory.a.underwater", depth.id, 0.35, "Underwater Depth on app A"))
        expectedNative["memory.a.underwater"] = try await s.native("memory.a.underwater").parts

        // Save, then read the saved positions back: through the archive codec and a real reopen.
        _ = try await s.session.checkpoint()
        let saved = try Data(contentsOf: file)
        let archive = try SoundLibrarySession.storedArchive(saved, limits: QMS.limits)
        let again = try SoundLibrarySession.storedArchive(try archive.encoded(), limits: QMS.limits)
        r.check(again.uses == archive.uses, "the app's positions survive an encode and decode unchanged")
        for item in expected {
            let stored = archive.uses.first { $0.target.bundleIdentifier == item.target }?.positions.first { $0.id.rawValue == item.control }.map { LibraryPosition($0.value) }
            if let stored, stored != .scalar(item.value) { r.fail("\(item.label) saved as \(stored), expected \(item.value)") }
            else { r.check(true, "") }
        }
        s = try await QMSSession.reopen(file)
        for item in expected {
            let value = try await s.position(item.control, on: item.target)
            r.check(value == item.value, "\(item.label) is \(item.value) after reopening, got \(QMS.describe(value))")
        }
        for (target, parts) in expectedNative {
            r.check(try await s.native(target).parts == parts, "\(target) sounds the same after reopening")
        }
    }
}

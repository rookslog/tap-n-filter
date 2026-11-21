import Foundation
@testable import SoundModel

extension QuickMenuSoundsChecks {
    static func identities(_ sound: any BuiltinSound) -> [(role: String, id: UUID)] {
        var out: [(String, UUID)] = [("definition", sound.definition.id.rawValue), ("version", sound.definition.version.rawValue),
                                     ("root", sound.root.rawValue)]
        let content = sound.definition.content
        for control in content.controls {
            out.append(("control", control.id.rawValue))
            if case .choice(let choice) = control.face { out += choice.options.map { ("option", $0.rawValue) } }
        }
        for piece in content.pieces { if case .part(let part) = piece { out.append(("part", part.id.rawValue)) } }
        for binding in content.bindings ?? [] { out.append(("binding", binding.id)) }
        return out
    }

    static func golden(_ sound: any BuiltinSound) -> [String] {
        identities(sound).map { $0.role + " " + $0.id.uuidString }.sorted()
    }

    // 3. IDs: unique, no clash with Everyday's or Filters', the same on every construction, frozen.
    static func identityGroup(_ c: QMSContext) async throws {
        let r = c.report
        let first = try QMSNames.recipes(), second = try QMSNames.recipes()
        let old: [any BuiltinSound] = [try Everyday(), try QuickMenuEveryday(), try Filters()]
        let oldIDs = Set(old.flatMap { identities($0).map(\.id) })
        var seen: [UUID: String] = [:]
        for ((name, sound), (_, again)) in zip(first, second) {
            let ids = identities(sound)
            r.check(ids.count >= 8, "\(name) has its definition, version, root, controls, options or parts identified (\(ids.count) IDs)")
            r.check(Set(ids.map(\.id)).count == ids.count, "\(name) IDs are unique within the sound")
            let clash = ids.filter { oldIDs.contains($0.id) }
            r.check(clash.isEmpty, "\(name) IDs never reuse an Everyday or Filters ID: \(clash.map { "\($0.role) \($0.id)" })")
            for id in ids {
                if let other = seen[id.id] { r.fail("\(name) \(id.role) \(id.id) is also used by \(other)") }
                seen[id.id] = name
            }
            r.check(golden(sound) == golden(again), "\(name) IDs are the same on every construction")
            r.check(sound.definition == again.definition && sound.presentation == again.presentation,
                    "\(name) definition and presentation are the same on every construction")
            r.check(sound.presentation.map(\.id) == sound.definition.content.controls.map(\.id.rawValue),
                    "\(name) has presentation for exactly its controls, in order")
        }
        let file = c.root.appendingPathComponent("Tests/QuickMenuSoundsChecks/Fixtures/new-sound-ids.json")
        guard let data = try? Data(contentsOf: file),
              let frozen = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            r.fail("ID golden list not frozen yet (Fixtures/new-sound-ids.json); current IDs: \(Dictionary(uniqueKeysWithValues: first.map { ($0.name, golden($0.sound)) }))")
            return
        }
        r.check(Set(frozen.keys) == Set(QMS.newNames), "ID golden covers the three sounds")
        for (name, sound) in first {
            let now = golden(sound), was = frozen[name] ?? []
            r.check(now == was, "\(name) IDs match the frozen list; added \(Set(now).subtracting(was).sorted()), removed \(Set(was).subtracting(now).sorted())")
        }
    }
}

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

    /// Every entity in declaration order, each named by what it is: a control or option by its title
    /// (a repeated title gets " #2"), a part by its type, a binding by its source control and the part
    /// setting it drives. Swapping two mappings, even two from one control, moves an ID to another name.
    static func roles(_ sound: any BuiltinSound) -> [String] {
        let content = sound.definition.content
        var titles: [UUID: String] = [:], optionTitles: [UUID: String] = [:], seen: [String: Int] = [:]
        for control in sound.presentation {
            let count = (seen[control.title] ?? 0) + 1
            seen[control.title] = count
            titles[control.id] = count == 1 ? control.title : "\(control.title) #\(count)"
            if case .choice(let options) = control.face { for option in options { optionTitles[option.id] = option.title } }
        }
        var partTypes: [UUID: String] = [:]
        for piece in content.pieces { if case .part(let part) = piece { partTypes[part.id.rawValue] = part.type } }
        func name(_ control: UUID) -> String { titles[control] ?? "untitled \(control.uuidString)" }

        var out = ["definition " + sound.definition.id.rawValue.uuidString, "version " + sound.definition.version.rawValue.uuidString,
                   "root " + sound.root.rawValue.uuidString]
        for control in content.controls {
            out.append("control \(name(control.id.rawValue)) \(control.id.rawValue.uuidString)")
            if case .choice(let choice) = control.face {
                out += choice.options.map { "option \(optionTitles[$0.rawValue] ?? "untitled") \($0.rawValue.uuidString)" }
            }
        }
        for piece in content.pieces { if case .part(let part) = piece { out.append("part \(part.type) \(part.id.rawValue.uuidString)") } }
        for binding in content.bindings ?? [] {
            let target: String
            if case .setting(let part, let parameter) = binding.target { target = "\(partTypes[part] ?? "unknown part").\(parameter)" }
            else { target = String(describing: binding.target) }
            out.append("binding \(name(binding.source.control)) -> \(target) \(binding.id.uuidString)")
        }
        return out
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

        // Pinned by role, in declaration order: the sorted list above cannot see two IDs trade places.
        let rolesFile = c.root.appendingPathComponent("Tests/QuickMenuSoundsChecks/Fixtures/new-sound-roles.json")
        guard let rolesData = try? Data(contentsOf: rolesFile),
              let pinned = try? JSONDecoder().decode([String: [String]].self, from: rolesData) else {
            r.fail("role list unreadable (Fixtures/new-sound-roles.json); current: \(Dictionary(uniqueKeysWithValues: first.map { ($0.name, roles($0.sound)) }))")
            return
        }
        r.check(Set(pinned.keys) == Set(QMS.newNames), "role list covers the three sounds")
        for (name, sound) in first {
            let now = roles(sound), was = pinned[name] ?? []
            let firstDifference = zip(now, was).enumerated().first { $0.element.0 != $0.element.1 }
            r.check(now == was, "\(name) IDs match their pinned roles in declaration order (\(now.count) now, \(was.count) pinned)"
                    + (firstDifference.map { "; entry \($0.offset): \($0.element.0), pinned \($0.element.1)" } ?? ""))
        }
    }
}

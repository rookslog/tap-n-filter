import Foundation
import AppKit
import SwiftUI
@testable import SoundModel
@testable import EverydayMenu
import SessionStore

extension QuickMenuSoundsChecks {
    struct ChildSpec { let option: String; let title: String; let ends: (String, String) }
    struct RosterSpec {
        let name: String
        let rows: [String]
        let choice: String?
        let options: [String]
        let children: [ChildSpec]
        let slider: (title: String, ends: (String, String))?
        let controlCount: Int
    }
    static let roster: [RosterSpec] = [
        RosterSpec(name: "Big space", rows: ["Space", "Volume"], choice: "Space", options: ["Hall", "Church"],
                   children: [ChildSpec(option: "Hall", title: "Where you stand", ends: ("Front", "Back")),
                              ChildSpec(option: "Church", title: "Where you stand", ends: ("Front", "Back"))],
                   slider: nil, controlCount: 4),
        RosterSpec(name: "Old recording", rows: ["Era", "Volume"], choice: "Era", options: ["Shellac", "Vinyl", "Tape"],
                   children: [ChildSpec(option: "Vinyl", title: "Wear", ends: ("New", "Worn")),
                              ChildSpec(option: "Tape", title: "Wear", ends: ("New", "Worn"))],
                   slider: nil, controlCount: 4),
        RosterSpec(name: "Underwater", rows: ["Depth", "Volume"], choice: nil, options: [], children: [],
                   slider: (title: "Depth", ends: ("Surface", "Deep")), controlCount: 2),
    ]

    static func card(_ data: MenuSoundData, _ target: String) throws -> MenuSoundCard {
        guard let card = data.assignments.first(where: { $0.bundleIdentifier == target }) else {
            throw QMSFailure("no menu card on \(target)")
        }
        return card
    }

    // 1. Roster and structure.
    static func rosterGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("roster/library.json"))
        let snapshot = try await s.session.snapshot()
        let builtins = snapshot.definitions.filter { $0.origin == "builtin" }
        r.check(builtins.map(\.name) == QMS.chooserOrder,
                "fresh Quick Menu built-ins in chooser order \(QMS.chooserOrder), got \(builtins.map(\.name))")
        let data = MenuSoundData(library: snapshot)
        r.check(data.choices.map(\.title) == QMS.chooserOrder,
                "menu sound chooser lists \(QMS.chooserOrder), got \(data.choices.map(\.title))")
        for (name, block) in QMSNames.blocks {
            r.check(builtins.first { $0.name == name }?.builtin == block, "\(name) is marked as built-in block \(block)")
            r.check(data.choices.first { $0.title == name }?.decoration == .builtin(block), "\(name) chooser entry carries its own decoration")
            r.check(builtins.first { $0.name == name }?.inTheMenu == true, "\(name) is in the menu")
        }
        for (name, sound) in try QMSNames.recipes() {
            r.check(sound.definition.name == name, "definition type for \(name) is named \(name), got \(sound.definition.name)")
            r.check(QMSNames.blocks.first { $0.name == name }?.block == QMSNames.kind(sound), "\(name) definition kind matches its block")
        }

        // Everyday's Volume is the reference for every new Volume.
        try await s.select("Everyday", on: "roster.everyday")
        let everydayVolume = try await s.control("Volume", on: "roster.everyday")
        let everydayVolumeDefault = try await s.position(everydayVolume.id, on: "roster.everyday")

        for spec in roster {
            let target = "roster." + spec.name.replacingOccurrences(of: " ", with: "-").lowercased()
            try await s.select(spec.name, on: target)
            let use = try await s.use(target)
            let rows = try await s.topLevel(target)
            r.check(rows.map(\.title) == spec.rows, "\(spec.name) rows are \(spec.rows), got \(rows.map(\.title))")
            r.check(use.controls.count == spec.controlCount, "\(spec.name) has exactly \(spec.controlCount) controls, got \(use.controls.count)")
            r.check(use.controls.allSatisfy { $0.placement == .primary }, "\(spec.name) puts nothing behind More")

            let volume = try await s.control("Volume", on: target)
            r.check(volume.face == everydayVolume.face && volume.readout == everydayVolume.readout && volume.placement == everydayVolume.placement,
                    "\(spec.name) Volume has Everyday's face, ends and readout")
            r.check(volume.face == .slider("−24 dB", "+6 dB"), "\(spec.name) Volume ends are −24 dB and +6 dB")
            let volumeDefault = try await s.position(volume.id, on: target)
            r.check(volumeDefault != nil && volumeDefault == everydayVolumeDefault,
                    "\(spec.name) Volume starts where Everyday's does (\(QMS.describe(everydayVolumeDefault))), got \(QMS.describe(volumeDefault))")

            if let choiceTitle = spec.choice {
                let choice = try await s.control(choiceTitle, on: target)
                guard case .choice(let options) = choice.face else { r.fail("\(spec.name) \(choiceTitle) is a choice"); continue }
                r.check(options.map(\.title) == spec.options, "\(spec.name) \(choiceTitle) options are \(spec.options), got \(options.map(\.title))")
                var seen: Set<UUID> = []
                for option in spec.options {
                    let child = try await s.childControl(choiceTitle, option, on: target)
                    let wanted = spec.children.first { $0.option == option }
                    if let wanted {
                        guard let child else { r.fail("\(spec.name) \(option) carries \(wanted.title)"); continue }
                        r.check(child.title == wanted.title, "\(spec.name) \(option) sub-control is titled \(wanted.title), got \(child.title)")
                        r.check(child.face == .slider(wanted.ends.0, wanted.ends.1), "\(spec.name) \(option) \(wanted.title) ends are \(wanted.ends.0)–\(wanted.ends.1)")
                        r.check(!seen.contains(child.id), "\(spec.name) \(option) has its own \(wanted.title) control, not a shared one")
                        seen.insert(child.id)
                        let start = try await s.position(child.id, on: target)
                        r.check(start == 0.5, "\(spec.name) \(option) \(wanted.title) starts at 0.5, got \(QMS.describe(start))")
                    } else {
                        r.check(child == nil, "\(spec.name) \(option) carries no sub-control")
                    }
                }
                r.check(use.optionControls.count == spec.children.count, "\(spec.name) has \(spec.children.count) option sub-controls, got \(use.optionControls.count)")
            } else {
                r.check(use.optionControls.isEmpty, "\(spec.name) has no sub-controls")
            }
            if let slider = spec.slider {
                let row = try await s.control(slider.title, on: target)
                r.check(row.face == .slider(slider.ends.0, slider.ends.1), "\(spec.name) \(slider.title) ends are \(slider.ends.0)–\(slider.ends.1)")
                let start = try await s.position(row.id, on: target)
                r.check(start == 0.5, "\(spec.name) \(slider.title) starts at 0.5, got \(QMS.describe(start))")
            }

            // The real menu projection: which tab sits under which option, folded by default.
            if let choiceTitle = spec.choice {
                for option in spec.options {
                    try await s.choose(choiceTitle, option, on: target)
                    let data = MenuSoundData(library: try await s.session.snapshot())
                    let card = try card(data, target)
                    r.check(card.controls.map(\.title) == spec.rows, "\(spec.name) \(option) menu card rows are \(spec.rows), got \(card.controls.map(\.title))")
                    let wanted = spec.children.first { $0.option == option }
                    if let wanted {
                        r.check(card.optionTabs.count == 1 && card.optionTabs.first?.option.title == option
                                && card.optionTabs.first?.controls.map(\.title) == [wanted.title],
                                "\(spec.name) \(option) shows one tab holding \(wanted.title)")
                        var folds = MenuFoldState()
                        folds.observe(data)
                        r.check(folds.visibleTabHeight(on: card, expanded: true) == 0, "\(spec.name) \(option) tab starts folded")
                        let parent = card.controls.first { $0.title == choiceTitle }
                        if let parent, case .choice(let options) = parent.face, let selected = options.first(where: { $0.title == option }) {
                            let action = folds.activate(selected, control: parent, on: card, current: data)
                            r.check(action == .toggle && folds.visibleTabHeight(on: card, expanded: true) > 0,
                                    "\(spec.name) clicking the chosen \(option) opens its tab")
                        } else { r.fail("\(spec.name) menu card has its \(choiceTitle) choice") }
                    } else {
                        r.check(card.optionTabs.isEmpty, "\(spec.name) \(option) shows no tab")
                    }
                }
            } else {
                let card = try card(MenuSoundData(library: try await s.session.snapshot()), target)
                r.check(card.optionTabs.isEmpty && card.controls.map(\.title) == spec.rows, "\(spec.name) menu card shows \(spec.rows) and no tab")
            }
        }
    }

    // 2. Words: every string the three sounds can put on screen.
    static func wordsGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("words/library.json"))
        var strings: [(String, String)] = []
        var readouts: [(String, ListeningReadout)] = []
        func face(_ where_: String, _ face: LibraryFace) {
            switch face {
            case .slider(let a, let b): strings += [(where_ + " start", a), (where_ + " end", b)]
            case .choice(let options): strings += options.map { (where_ + " option", $0.title) }
            case .xy: strings.append((where_, "an XY face"))
            }
        }
        let snapshot = try await s.session.snapshot()
        for name in QMS.newNames {
            guard let definition = snapshot.definitions.first(where: { $0.name == name }) else { r.fail("no sound \(name)"); continue }
            strings.append(("sound name", definition.name))
            for control in definition.controls {
                strings.append((name + " control", control.title))
                face(name + " " + control.title, control.face)
                if let readout = control.readout { readouts.append((name + " " + control.title, readout)) }
            }
        }
        for spec in roster {
            let target = "words." + spec.name.replacingOccurrences(of: " ", with: "-").lowercased()
            try await s.select(spec.name, on: target)
            let use = try await s.use(target)
            strings.append((spec.name + " use name", use.name))
            for control in use.controls {
                strings.append((spec.name + " use control", control.title))
                face(spec.name + " use " + control.title, control.face)
                if let readout = control.readout { readouts.append((spec.name + " " + control.title, readout)) }
            }
            let options = spec.choice == nil ? [nil] : spec.options.map(Optional.some)
            for option in options {
                if let option, let choice = spec.choice { try await s.choose(choice, option, on: target) }
                let card = try card(MenuSoundData(library: try await s.session.snapshot()), target)
                strings.append((spec.name + " card title", card.title))
                if let help = card.nameHelp { strings.append((spec.name + " card help", help)) }
                strings += card.heldNames.map { (spec.name + " held name", $0) }
                strings += card.heldHelp.map { (spec.name + " held help", $0) }
                for row in card.controls + card.optionTabs.flatMap(\.controls) {
                    strings.append((spec.name + " card row", row.title))
                    switch row.face {
                    case .slider(let a, let b): strings += [(spec.name + " card end", a), (spec.name + " card end", b)]
                    case .choice(let options): strings += options.map { (spec.name + " card option", $0.title) }
                    }
                    for children in row.optionChildren.values { strings += children.map { (spec.name + " option child", $0) } }
                }
                strings += card.optionTabs.map { (spec.name + " tab", $0.option.title) }
            }
        }
        let outside = strings.filter { !QMS.allowedWords.contains($0.1) }
        r.check(!strings.isEmpty, "collected the new sounds' on-screen strings")
        r.check(outside.isEmpty, "every title, label and end is an approved word; outside the list: \(outside.map { "\($0.0): \"\($0.1)\"" })")
        print("NOTE words checked: \(Set(strings.map(\.1)).sorted())")
        for (where_, readout) in readouts {
            for position in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let text = try readout.text(at: position)
                let words = text.split { !$0.isLetter }.map(String.init)
                let extra = words.filter { !QMS.readoutUnits.contains($0) }
                r.check(extra.isEmpty, "\(where_) readout at \(position) shows no word (\"\(text)\")")
            }
        }
    }

    // 9. Symbols and tints: named icons resolve on this Mac; the menu tables use them.
    static func symbolsGroup(_ c: QMSContext) async throws {
        let r = c.report
        for symbol in ["building.columns", "music.note.house", "bell", "hourglass", "water.waves", "speaker.wave.2"] {
            r.check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "SF Symbol \(symbol) resolves on this Mac")
        }
        let expected: [(String, String)] = [("Big space", "building.columns"), ("Old recording", "hourglass"), ("Underwater", "water.waves")]
        for (name, symbol) in expected {
            guard let block = QMSNames.blocks.first(where: { $0.name == name })?.block else { continue }
            r.check(QMSNames.symbol(block) == symbol, "\(name) chooser icon is \(symbol), got \(QMSNames.symbol(block))")
        }
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("symbols/library.json"))
        try await s.select("Everyday", on: "symbols.everyday")
        let everydayVolume = controlSymbol(try await s.control("Volume", on: "symbols.everyday").id)
        r.check(everydayVolume != nil, "Everyday's Volume has an icon to reuse")
        let rows: [(String, String, String?)] = [
            ("Big space", "Space", "building.columns"), ("Old recording", "Era", "hourglass"), ("Underwater", "Depth", "water.waves"),
        ]
        for (name, row, symbol) in rows {
            let target = "symbols." + name.replacingOccurrences(of: " ", with: "-").lowercased()
            try await s.select(name, on: target)
            let control = try await s.control(row, on: target)
            r.check(controlSymbol(control.id) == symbol, "\(name) \(row) icon is \(symbol ?? "none"), got \(controlSymbol(control.id) ?? "none")")
            let volume = try await s.control("Volume", on: target)
            r.check(everydayVolume != nil && controlSymbol(volume.id) == everydayVolume, "\(name) Volume reuses Everyday's volume icon")
        }
        let options: [(String, String, String, String?)] = [
            ("Big space", "Space", "Hall", "music.note.house"), ("Big space", "Space", "Church", "bell"),
            ("Old recording", "Era", "Shellac", nil), ("Old recording", "Era", "Vinyl", nil), ("Old recording", "Era", "Tape", nil),
        ]
        for (name, choice, option, symbol) in options {
            let target = "symbols." + name.replacingOccurrences(of: " ", with: "-").lowercased()
            let (_, found) = try await s.option(choice, option, on: target)
            r.check(optionSymbol(found.id) == symbol, "\(name) \(option) option icon is \(symbol ?? "none (text segment)"), got \(optionSymbol(found.id) ?? "none")")
        }

        // Tints: Big space system indigo, Old recording system brown, Underwater system mint.
        func components(_ color: NSColor, _ appearance: NSAppearance.Name) -> [Double]? {
            var out: [Double]?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                if let rgb = color.usingColorSpace(.sRGB) { out = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(Double.init) }
            }
            return out
        }
        func matches(_ tint: Color, _ system: NSColor) -> [String] {
            [NSAppearance.Name.aqua, .darkAqua].compactMap { appearance in
                guard let a = components(NSColor(tint), appearance), let b = components(system, appearance) else { return nil }
                return zip(a, b).allSatisfy { abs($0 - $1) <= 2.0 / 255 } ? appearance.rawValue : nil
            }
        }
        for (name, system, label) in [("Big space", NSColor.systemIndigo, "system indigo"), ("Old recording", NSColor.systemBrown, "system brown"),
                                      ("Underwater", NSColor.systemMint, "system mint")] {
            guard let block = QMSNames.blocks.first(where: { $0.name == name })?.block else { continue }
            let hits = matches(QMSNames.tint(block), system)
            r.check(!hits.isEmpty, "\(name) tint is \(label) in light or dark")
            r.note("\(name) tint equals \(label) in: \(hits)")
        }
        r.note("Everyday's tint equals system teal in: \(matches(BuiltinBlock.everyday.tint, .systemTeal)); Filters' equals system blue in: \(matches(BuiltinBlock.filters.tint, .systemBlue))")
        for (name, block) in QMSNames.blocks {
            r.check(matches(QMSNames.tint(block), NSColor(BuiltinBlock.filters.tint)).isEmpty, "\(name) tint differs from Filters'")
            r.check(matches(QMSNames.tint(block), NSColor(BuiltinBlock.everyday.tint)).isEmpty, "\(name) tint differs from Everyday's")
        }
    }
}

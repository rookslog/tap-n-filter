import Foundation
import EffectCatalog
import PlaybackRenderBridge
import PlaybackDSP
@testable import SoundModel
import SessionStore

extension QuickMenuSoundsChecks {
    /// One row of the sound spec's starting-value tables: native values at 0, 0.5 and 1, or one fixed value.
    struct ValueRow { let type: String; let key: String; let at: [Double] }
    struct OptionValues {
        let sound: String
        let choice: String?
        let option: String?
        /// The control the positions move: a sub-control under the option, a row, or nothing.
        let mover: Mover
        let presets: [(type: String, native: String)]
        let sizeHalf: Bool
        let rows: [ValueRow]
        let neutral: [String]
        let dynamicsOff: Bool
        var label: String { [sound, option].compactMap { $0 }.joined(separator: " ") }
    }
    enum Mover { case child, row(String), none }

    static let reverb = "AVAudioUnitReverbPreset", radio = "AVAudioUnitDistortionPresetSpeechRadioTower"
    static let values: [OptionValues] = {
        let recordingCommon = [ValueRow(type: "deviceColour", key: "preGainDb", at: [-6])]
        return [
            OptionValues(sound: "Big space", choice: "Space", option: "Hall", mover: .child,
                         presets: [("reverb", reverb + "LargeHall")], sizeHalf: true,
                         rows: [ValueRow(type: "reverb", key: "wetPercent", at: [15, 32, 55]),
                                ValueRow(type: "placeEQ", key: "lowPassHz", at: [16_000, 11_000, 7_000]),
                                ValueRow(type: "gain", key: "gainDb", at: [0, -1, -2.5])],
                         neutral: ["deviceEQ", "deviceColour"], dynamicsOff: true),
            OptionValues(sound: "Big space", choice: "Space", option: "Church", mover: .child,
                         presets: [("reverb", reverb + "Cathedral")], sizeHalf: true,
                         rows: [ValueRow(type: "reverb", key: "wetPercent", at: [22, 42, 68]),
                                ValueRow(type: "placeEQ", key: "lowPassHz", at: [14_000, 9_000, 5_500]),
                                ValueRow(type: "gain", key: "gainDb", at: [0, -1.5, -3])],
                         neutral: ["deviceEQ", "deviceColour"], dynamicsOff: true),
            OptionValues(sound: "Old recording", choice: "Era", option: "Shellac", mover: .none,
                         presets: [("deviceColour", radio)], sizeHalf: false,
                         rows: recordingCommon + [ValueRow(type: "deviceEQ", key: "highPassHz", at: [280]),
                                ValueRow(type: "deviceEQ", key: "lowPassHz", at: [3_200]),
                                ValueRow(type: "deviceColour", key: "wetPercent", at: [12]),
                                // No option adds gain on the stage Volume uses: 0 dB.
                                ValueRow(type: "gain", key: "gainDb", at: [0])],
                         neutral: ["placeEQ", "reverb"], dynamicsOff: true),
            OptionValues(sound: "Old recording", choice: "Era", option: "Vinyl", mover: .child,
                         presets: [("deviceColour", radio)], sizeHalf: false,
                         rows: recordingCommon + [ValueRow(type: "deviceEQ", key: "highPassHz", at: [40, 65, 110]),
                                ValueRow(type: "deviceEQ", key: "lowPassHz", at: [12_000, 8_000, 5_200]),
                                ValueRow(type: "deviceColour", key: "wetPercent", at: [0, 4, 10])],
                         neutral: ["placeEQ", "reverb", "gain"], dynamicsOff: true),
            OptionValues(sound: "Old recording", choice: "Era", option: "Tape", mover: .child,
                         presets: [("deviceColour", radio)], sizeHalf: false,
                         rows: recordingCommon + [ValueRow(type: "deviceEQ", key: "highPassHz", at: [35, 50, 70]),
                                ValueRow(type: "deviceEQ", key: "lowPassHz", at: [13_500, 9_000, 5_800]),
                                ValueRow(type: "deviceColour", key: "wetPercent", at: [0, 3, 8]),
                                ValueRow(type: "dynamics", key: "thresholdDb", at: [-14, -19, -24]),
                                ValueRow(type: "dynamics", key: "headroomDb", at: [12, 8, 5]),
                                ValueRow(type: "dynamics", key: "attackSeconds", at: [0.01]),
                                ValueRow(type: "dynamics", key: "releaseSeconds", at: [0.15]),
                                ValueRow(type: "dynamics", key: "makeupDb", at: [2])],
                         neutral: ["placeEQ", "reverb", "gain"], dynamicsOff: false),
            OptionValues(sound: "Underwater", choice: nil, option: nil, mover: .row("Depth"),
                         presets: [("reverb", reverb + "LargeRoom")], sizeHalf: true,
                         rows: [ValueRow(type: "placeEQ", key: "lowPassHz", at: [20_000, 1_100, 280]),
                                ValueRow(type: "reverb", key: "wetPercent", at: [0, 12, 25]),
                                // Depth does not touch gain: 0 dB throughout.
                                ValueRow(type: "gain", key: "gainDb", at: [0, 0, 0])],
                         neutral: ["deviceEQ", "deviceColour"], dynamicsOff: true),
        ]
    }()

    static func target(_ spec: OptionValues, _ prefix: String) -> String {
        prefix + "." + spec.sound.replacingOccurrences(of: " ", with: "-").lowercased()
    }

    /// Selects the option (if any) and moves its control to `position`, then reads native values.
    static func sample(_ s: QMSSession, _ spec: OptionValues, _ target: String, _ position: Double) async throws -> QMSNative {
        if let choice = spec.choice, let option = spec.option { try await s.choose(choice, option, on: target) }
        switch spec.mover {
        case .child:
            let result = try await s.moveChild(spec.choice!, spec.option!, on: target, to: position)
            if result == .superseded { throw QMSFailure("\(spec.label) sub-control move was superseded while its option was chosen") }
        case .row(let title): try await s.moveRow(title, on: target, to: position)
        case .none: break
        }
        return try await s.native(target)
    }

    static func structureProblems(_ n: QMSNative) -> [String] {
        let known: Set<String> = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"]
        var problems = n.parts.map(\.type).filter { !known.contains($0) }.map { "unknown part type \($0)" }
        for type in known where n.all(type).count > 1 { problems.append("\(n.all(type).count) \(type) parts") }
        return problems
    }

    /// Every value one option's spec row fixes, at one position (0, 0.5 or 1 -> index 0, 1, 2).
    static func valueProblems(_ n: QMSNative, _ spec: OptionValues, index: Int, table: QMSTable) -> [String] {
        var problems = structureProblems(n)
        for row in spec.rows {
            let wanted = row.at.count == 1 ? row.at[0] : row.at[index]
            let value = n.value(row.type, row.key)
            if !QMS.near(value, wanted) { problems.append("\(row.type).\(row.key)=\(QMS.describe(value)), spec \(wanted)") }
        }
        for preset in spec.presets {
            guard let key = table.effects[preset.type]?.presetKey else { problems.append("table has no preset key for \(preset.type)"); continue }
            let name = table.presetName(preset.type, n.value(preset.type, key))
            if name != preset.native { problems.append("\(preset.type) preset \(name ?? QMS.describe(n.value(preset.type, key))), spec \(preset.native)") }
        }
        if spec.sizeHalf {
            let size = n.value("reverb", "roomSize")
            if !QMS.near(size, 0.5) { problems.append("reverb roomSize=\(QMS.describe(size)), spec 0.5 (required)") }
        }
        for type in spec.neutral { problems += n.neutralProblems(type) }
        if spec.dynamicsOff { for part in n.all("dynamics") { problems += n.dynamicsOffProblems(part) } }
        else if let ratio = n.value("dynamics", "expansionRatio"), !QMS.near(ratio, 1) { problems.append("dynamics expansion ratio \(ratio)") }
        return problems
    }

    /// Straight between waypoints in Everyday's domains: logarithmic for cutoffs, linear otherwise.
    static func between(_ a: Double, _ b: Double, key: String) -> Double {
        key.hasSuffix("Hz") ? exp((log(a) + log(b)) / 2) : (a + b) / 2
    }

    // 4. Values at 0, 0.5 and 1 for every row of the starting-value tables; Volume as Everyday's.
    static func valuesGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("values/library.json"))
        for name in QMS.newNames { try await s.select(name, on: "values." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        for spec in values {
            let target = target(spec, "values")
            let positions: [Double] = { if case .none = spec.mover { return [0.5] }; return [0, 0.5, 1] }()
            for (index, position) in positions.enumerated() {
                let n = try await sample(s, spec, target, position)
                let problems = valueProblems(n, spec, index: positions.count == 1 ? 1 : index, table: c.table)
                r.check(problems.isEmpty, "\(spec.label) at \(position): \(problems) [\(n.line)]")
            }
            if case .none = spec.mover {
                // Shellac has no Wear; moving another option's Wear must not reach it.
                continue
            }
            for (position, pair) in [(0.25, (0, 1)), (0.75, (1, 2))] {
                let n = try await sample(s, spec, target, position)
                for row in spec.rows where row.at.count == 3 {
                    let wanted = between(row.at[pair.0], row.at[pair.1], key: row.key)
                    let value = n.value(row.type, row.key)
                    r.check(QMS.near(value, wanted, relative: 5e-3, absolute: 1e-3),
                            "\(spec.label) \(row.type).\(row.key) at \(position) is straight between waypoints (\(wanted)), got \(QMS.describe(value))")
                }
            }
            _ = try await sample(s, spec, target, 0.5)
        }

        // Volume: same mapping as Everyday's, checked where the table's gain is 0.
        try await s.select("Everyday", on: "values.everyday")
        let neutralCases: [(String, String?, String?, Double)] = [
            ("Big space", "Space", "Hall", 0), ("Old recording", "Era", "Vinyl", 0), ("Underwater", nil, nil, 0),
        ]
        for (name, choice, option, position) in neutralCases {
            let spec = values.first { $0.sound == name && $0.option == option }!
            let target = target(spec, "values")
            _ = try await sample(s, spec, target, position)
            let volume = try await s.control("Volume", on: target)
            let start = try await s.position(volume.id, on: target) ?? 0.8
            for v in [0.0, 0.25, 0.5, 0.8, 1.0] {
                try await s.moveRow("Volume", on: target, to: v)
                try await s.moveRow("Volume", on: "values.everyday", to: v)
                let mine = try await s.native(target).value("gain", "gainDb")
                let everyday = try await s.native("values.everyday").value("gain", "gainDb")
                r.check(everyday != nil && mine != nil && QMS.near(mine, everyday!),
                        "\(name)\(choice.map { _ in " " + option! } ?? "") Volume at \(v) gives Everyday's gain \(QMS.describe(everyday)) dB, got \(QMS.describe(mine))")
            }
            try await s.moveRow("Volume", on: target, to: start)
        }
    }

    static func nonIncreasing(_ values: [Double?]) -> Bool {
        let v = values.map { $0 ?? .nan }
        guard v.allSatisfy(\.isFinite) else { return false }
        return zip(v, v.dropFirst()).allSatisfy { $1 <= $0 + 1e-9 * max(1, abs($0)) }
    }
    static func nonDecreasing(_ values: [Double?]) -> Bool { nonIncreasing(values.map { $0.map { -$0 } }) }

    // 5. Laws across 21 positions.
    static func lawsGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("laws/library.json"))
        for name in QMS.newNames { try await s.select(name, on: "laws." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        func sweep(_ spec: OptionValues) async throws -> [QMSNative] {
            var out: [QMSNative] = []
            for p in QMS.positions21 { out.append(try await sample(s, spec, target(spec, "laws"), p)) }
            _ = try await sample(s, spec, target(spec, "laws"), 0.5)
            return out
        }
        func series(_ n: [QMSNative], _ type: String, _ key: String, absent: Double? = nil) -> [Double?] {
            n.map { $0.value(type, key) ?? ($0.all(type).isEmpty ? absent : nil) }
        }
        for option in ["Hall", "Church"] {
            let n = try await sweep(values.first { $0.option == option }!)
            r.check(nonDecreasing(series(n, "reverb", "wetPercent")), "Big space \(option): toward Back is never drier (reverb wet \(series(n, "reverb", "wetPercent")))")
            r.check(nonIncreasing(series(n, "placeEQ", "lowPassHz")), "Big space \(option): toward Back is never brighter (place low-pass)")
            r.check(nonIncreasing(series(n, "deviceEQ", "lowPassHz", absent: 20_000)), "Big space \(option): toward Back is never brighter (device low-pass)")
        }
        let shellac = try await sample(s, values.first { $0.option == "Shellac" }!, target(values[2], "laws"), 0.5)
        for option in ["Vinyl", "Tape"] {
            let n = try await sweep(values.first { $0.option == option }!)
            let high = series(n, "deviceEQ", "highPassHz"), low = series(n, "deviceEQ", "lowPassHz")
            r.check(nonDecreasing(high), "Old recording \(option): more Wear never widens the band (high-pass \(high))")
            r.check(nonIncreasing(low), "Old recording \(option): more Wear never widens the band (low-pass \(low))")
            r.check(nonIncreasing(series(n, "placeEQ", "lowPassHz", absent: 20_000)), "Old recording \(option): more Wear never brightens the place filter")
            r.check(nonDecreasing(series(n, "deviceColour", "wetPercent")), "Old recording \(option): more Wear never cleans the sound (colour wet)")
            if option == "Tape" {
                r.check(nonIncreasing(series(n, "dynamics", "thresholdDb")) && nonIncreasing(series(n, "dynamics", "headroomDb")),
                        "Old recording Tape: more Wear never weakens the compression")
            }
            let sh = shellac.value("deviceEQ", "highPassHz"), sl = shellac.value("deviceEQ", "lowPassHz")
            for (index, p) in QMS.positions21.enumerated() {
                guard let sh, let sl, let h = high[index], let l = low[index] else { r.fail("Shellac/\(option) band edges present at \(p)"); continue }
                r.check(sh >= h - 1e-9 && sl <= l + 1e-9 && sl / sh < l / h,
                        "Shellac (\(sh)–\(sl) Hz) is narrower than \(option) at Wear \(p) (\(h)–\(l) Hz)")
            }
        }
        let depth = try await sweep(values.last!)
        r.check(nonIncreasing(series(depth, "placeEQ", "lowPassHz")), "Underwater: more Depth is never brighter (place low-pass \(series(depth, "placeEQ", "lowPassHz")))")
        r.check(nonIncreasing(series(depth, "deviceEQ", "lowPassHz", absent: 20_000)), "Underwater: more Depth is never brighter (device low-pass)")
        let surface = depth[0]
        let problems = ["deviceEQ", "deviceColour", "placeEQ", "reverb", "dynamics", "gain"].flatMap { surface.neutralProblems($0) }
        r.check(problems.isEmpty, "Underwater Surface is the original sound: every part neutral \(problems) [\(surface.line)]")
    }

    // 6. Engine table: every part, parameter, value and preset is a table entry; the real mapper accepts each.
    static func engineTableGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("engine/library.json"))
        for name in QMS.newNames { try await s.select(name, on: "engine." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        for (type, native) in [("reverb", reverb + "LargeHall"), ("reverb", reverb + "Cathedral"), ("reverb", reverb + "LargeRoom"), ("deviceColour", radio)] {
            r.check(c.table.effects[type]?.presets.values.contains(native) == true, "engine table lists \(native)")
        }
        // The values each sound asks for, before any clamping, lie inside the table's range. The range
        // check further down reads delivered values, which the model has already clamped, so on its own it
        // cannot see an over-range request; group 4 holds delivered equal to these requested values, and
        // group 10 holds the gain Volume adds. A value sitting exactly on a range end (Surface's 20 kHz)
        // cannot be told apart from a clamped over-range request without the model's pre-clamp value.
        for spec in values {
            for row in spec.rows {
                guard let entry = EffectCatalog.effect(row.type)?.parameters.first(where: { $0.key == row.key }) else {
                    r.fail("\(spec.label): \(row.type).\(row.key) is a table knob"); continue
                }
                let outside = row.at.filter { !($0 >= entry.lower - 1e-9 && $0 <= entry.upper + 1e-9) }
                r.check(outside.isEmpty, "\(spec.label): requested \(row.type).\(row.key) \(row.at) inside the table's \(entry.lower)…\(entry.upper)")
            }
        }
        let format = try RenderProcessingFormat(sampleRate: 48_000, channels: 2, maximumFrames: 512)
        for spec in values {
            let target = target(spec, "engine")
            let positions: [Double] = { if case .none = spec.mover { return [0.5] }; return [0, 0.5, 1] }()
            let volume = try await s.control("Volume", on: target)
            let start = try await s.position(volume.id, on: target) ?? 0.8
            for v in [start, 0, 1] {
                try await s.moveRow("Volume", on: target, to: v)
                for p in positions {
                    let n = try await sample(s, spec, target, p)
                    var problems: [String] = []
                    for part in n.parts {
                        guard part.type != "sizedReverb", let effect = EffectCatalog.effect(part.type) else {
                            problems.append("part \(part.type) is not a table effect"); continue
                        }
                        for parameter in part.parameters {
                            if parameter.key == effect.presetKey {
                                let id = parameter.value.rounded() == parameter.value ? UInt32(exactly: parameter.value) : nil
                                if id == nil || !effect.presets.contains(id!) || c.table.presetName(part.type, parameter.value) == nil {
                                    problems.append("\(part.type) preset \(parameter.value) is not in the table")
                                }
                            } else if let entry = effect.parameters.first(where: { $0.key == parameter.key }) {
                                if !(parameter.value >= entry.lower - 1e-9 && parameter.value <= entry.upper + 1e-9) {
                                    problems.append("\(part.type).\(parameter.key)=\(parameter.value) outside table range \(entry.lower)…\(entry.upper)")
                                }
                            } else { problems.append("\(part.type).\(parameter.key) is not a table knob") }
                        }
                    }
                    r.check(problems.isEmpty, "\(spec.label) at \(p), Volume \(v): every value is a table entry \(problems)")
                    var admitted = true
                    do { try RenderAssignmentMapper.admitParts(n.parts) } catch { admitted = false; r.fail("\(spec.label) at \(p), Volume \(v): render mapper refuses: \(error)") }
                    if admitted { r.check(true, "") }
                    do {
                        var mapper = RenderAssignmentMapper()
                        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
                        _ = try mapper.lower(ListeningRenderAssignment(id: UUID(), bundleIdentifier: "engine.check", isEnabled: true, parts: n.parts), format: format, token: token)
                        r.check(true, "")
                    } catch { r.fail("\(spec.label) at \(p), Volume \(v): render mapper cannot lower: \(error)") }
                }
            }
            try await s.moveRow("Volume", on: target, to: start)
        }
    }
}

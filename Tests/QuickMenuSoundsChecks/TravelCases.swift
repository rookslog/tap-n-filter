import Foundation
import EffectCatalog
@testable import SoundModel
import SessionStore

extension QuickMenuSoundsChecks {
    // 10. Volume has live travel along its whole length for every sound and choice.
    // An option's own gain and Volume share one gain stage. Volume is swept in 1% steps, and the gain
    // the stage receives must rise at every step: a plateau anywhere, from a flat mapping or from the
    // stage's cap clamping the request, fails. The value delivered is the clamped one, so a strict rise
    // in it also proves the request rose and was never clamped.
    static func volumeTravelGroup(_ c: QMSContext) async throws {
        let r = c.report
        guard let stage = EffectCatalog.effect("gain")?.parameters.first(where: { $0.key == "gainDb" }) else {
            r.fail("the engine table has a gain stage with gainDb"); return
        }
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("travel/library.json"))
        let sweep = (0...100).map { Double($0) / 100 }

        func gain(_ target: String) async throws -> Double? { try await s.native(target).value("gain", "gainDb") }

        /// Sweeps Volume on `target` and checks every step. `expected`, when given, is the exact gain at
        /// each Volume position.
        func travel(_ label: String, _ target: String, expected: ((Double) -> Double)? = nil) async throws {
            let volume = try await s.control("Volume", on: target)
            let start = try await s.position(volume.id, on: target) ?? 0.8
            var gains: [Double?] = []
            for v in sweep {
                try await s.moveRow("Volume", on: target, to: v)
                gains.append(try await gain(target))
            }
            try await s.moveRow("Volume", on: target, to: start)
            guard gains.allSatisfy({ $0 != nil }) else { r.fail("\(label): a gain stage is present at every Volume position"); return }
            let g = gains.map { $0! }
            let flat = zip(sweep.indices.dropFirst(), zip(g, g.dropFirst())).filter { $0.1.1 <= $0.1.0 + 1e-6 }.map { sweep[$0.0] }
            r.check(flat.isEmpty, "\(label): every 1% of Volume raises the gain (no rise at \(flat.prefix(5)))")
            r.check(g.allSatisfy { $0 >= stage.lower - 1e-9 && $0 <= stage.upper + 1e-9 },
                    "\(label): the gain stays inside the stage's \(stage.lower)…\(stage.upper) dB (\(g.first!)…\(g.last!))")
            if let expected {
                let off = zip(sweep, g).filter { !QMS.near($0.1, expected($0.0), relative: 1e-4, absolute: 1e-3) }
                r.check(off.isEmpty, "\(label): the gain is the option's own plus Volume's −24…+6 dB at every step; first miss \(off.first.map { "\($0.0): \($0.1) dB, expected \(expected($0.0))" } ?? "")")
            }
        }

        // The three new sounds, every option and sub-control position. Volume maps −24…+6 dB straight,
        // so with Volume at its start the gain is the option's own and every other position adds 30 dB per unit.
        for name in QMS.newNames { try await s.select(name, on: "travel." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        for spec in values {
            let target = target(spec, "travel")
            let positions: [Double] = { if case .none = spec.mover { return [0.5] }; return [0, 0.5, 1] }()
            let start = try await s.position(try await s.control("Volume", on: target).id, on: target) ?? 0.8
            for p in positions {
                try await s.moveRow("Volume", on: target, to: start)
                _ = try await sample(s, spec, target, p)
                guard let own = try await gain(target) else { r.fail("\(spec.label) at \(p): a gain stage is present"); continue }
                try await travel("\(spec.label) at \(p)", target) { own + 30 * ($0 - start) }
            }
            _ = try await sample(s, spec, target, 0.5)
        }

        // Everyday, each Place and each Device option, and Filters: the same rise, without an exact formula.
        let everyday = "travel.everyday"
        try await s.select("Everyday", on: everyday)
        for (choice, options) in [("Place", ["Here", "Next room", "Corner", "Far away"]), ("Device", ["Speakers", "TV", "Phone", "Radio"])] {
            for option in options {
                try await s.choose(choice, option, on: everyday)
                try await travel("Everyday \(option)", everyday)
            }
            try await s.choose(choice, options[0], on: everyday)
        }
        try await s.select("Filters", on: "travel.filters")
        try await travel("Filters", "travel.filters")
    }
}

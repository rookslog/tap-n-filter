import Foundation
import EffectCatalog
@testable import SoundModel
import SessionStore

extension QuickMenuSoundsChecks {
    // 10. Volume has live travel at both ends for every new sound, option and sub-control position.
    // An option's own gain and Volume share one gain stage. If the gain the stage is asked for at
    // Volume's top lies above the stage's cap, the top of Volume's travel does nothing.
    static func volumeTravelGroup(_ c: QMSContext) async throws {
        let r = c.report
        guard let stage = EffectCatalog.effect("gain")?.parameters.first(where: { $0.key == "gainDb" }) else {
            r.fail("the engine table has a gain stage with gainDb"); return
        }
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("travel/library.json"))
        let reference = "travel.everyday"
        try await s.select("Everyday", on: reference)
        for name in QMS.newNames { try await s.select(name, on: "travel." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        let start = try await s.position(try await s.control("Volume", on: reference).id, on: reference) ?? 0.8

        func gain(_ target: String) async throws -> Double? { try await s.native(target).value("gain", "gainDb") }
        func volume(_ value: Double, _ targets: String...) async throws {
            for target in targets { try await s.moveRow("Volume", on: target, to: value) }
        }

        for spec in values {
            let target = target(spec, "travel")
            let positions: [Double] = { if case .none = spec.mover { return [0.5] }; return [0, 0.5, 1] }()
            for p in positions {
                let label = "\(spec.label) at \(p)"
                try await volume(start, target, reference)
                _ = try await sample(s, spec, target, p)
                guard let own = try await gain(target), let referenceStart = try await gain(reference) else {
                    r.fail("\(label): a gain stage is present with Volume at its start"); continue
                }
                for v in [0.0, 1.0] {
                    try await volume(v, target, reference)
                    guard let mine = try await gain(target), let everyday = try await gain(reference) else {
                        r.fail("\(label): a gain stage is present with Volume at \(v)"); continue
                    }
                    // What the stage is asked for: this option's gain plus Volume's own contribution at v.
                    let asked = own + (everyday - referenceStart)
                    r.check(asked >= stage.lower - 1e-9 && asked <= stage.upper + 1e-9,
                            "\(label): Volume at \(v) asks the gain stage for \(asked) dB, inside its \(stage.lower)…\(stage.upper) dB range")
                    r.check(QMS.near(mine, asked, relative: 1e-4, absolute: 1e-3),
                            "\(label): Volume at \(v) gives the asked \(asked) dB, got \(mine) dB")
                }
                for (inner, end) in [(0.95, 1.0), (0.05, 0.0)] {
                    try await volume(inner, target)
                    let a = try await gain(target)
                    try await volume(end, target)
                    let b = try await gain(target)
                    r.check(a != nil && b != nil && abs(b! - a!) > 1e-3,
                            "\(label): Volume from \(inner) to \(end) still moves the gain (\(QMS.describe(a)) -> \(QMS.describe(b)) dB)")
                }
            }
            try await volume(start, target, reference)
            _ = try await sample(s, spec, target, 0.5)
        }
    }
}

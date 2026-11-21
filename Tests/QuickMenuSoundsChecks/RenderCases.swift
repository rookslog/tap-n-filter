import Foundation
import FixedRender
import PlaybackDSP
import PlaybackRenderBridge
@testable import SoundModel

// One cheap check per law on rendered output. The fixed renderer runs the native
// effect chain in the audio engine's manual rendering mode: no device, no sound.
enum QMSRender {
    static let rate = 48_000.0
    static let block = 256

    static func noise(seconds: Double, silenceAfter: Double = 0, amplitude: Float = 0.05) -> [Float] {
        var state: UInt32 = 0x1234_5678
        let sounding = Int(rate * seconds), total = sounding + Int(rate * silenceAfter)
        var out = [Float](repeating: 0, count: total)
        for i in 0..<sounding {
            state = state &* 1_664_525 &+ 1_013_904_223
            out[i] = amplitude * (Float(state >> 8) / Float(1 << 24) * 2 - 1)
        }
        return out
    }

    static func render(_ parts: [ListeningRenderPart], _ input: [Float]) throws -> [Float] {
        let format = try RenderProcessingFormat(sampleRate: rate, channels: 2, maximumFrames: 512)
        var mapper = RenderAssignmentMapper()
        let token = FRToken(assignment: 1, source_epoch: 1, format_epoch: 1, topology: 1, intent: 1)
        var lowered = try mapper.lower(ListeningRenderAssignment(id: UUID(), bundleIdentifier: "render.check", isEnabled: true, parts: parts),
                                       format: format, token: token)
        var config = format.configuration
        var made: OpaquePointer? = nil
        guard fr_create(&config, &made) == FR_OK, let renderer = made else { throw QMSFailure("renderer could not be created") }
        defer { fr_destroy(renderer) }
        guard fr_set_desired(renderer, &lowered.program, &lowered.frame) == FR_OK else { throw QMSFailure("renderer refused the program") }
        var bank: OpaquePointer? = nil
        var status: Int32 = 0
        let prepared = fr_prepare(&config, &lowered.program, &lowered.frame, &bank, &status)
        guard prepared == FR_OK else { throw QMSFailure("preparation failed: \(prepared.rawValue) native \(status)") }
        let published = fr_publish(renderer, &bank, &status)
        guard published == FR_OK else {
            if let bank { fr_prepared_dispose(bank) }
            throw QMSFailure("publication failed: \(published.rawValue) native \(status)")
        }
        var output = [Float](repeating: 0, count: input.count)
        var source = [Float](repeating: 0, count: block)
        var left = [Float](repeating: 0, count: block), right = [Float](repeating: 0, count: block)
        var start = 0
        while start + block <= input.count {
            for i in 0..<block { source[i] = input[start + i] }
            let result: FRResult = source.withUnsafeBufferPointer { s in
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        var a = FRInput(); a.planes = (s.baseAddress, s.baseAddress); a.channels = 2; a.capacity_frames = UInt32(block)
                        var b = FROutput(); b.planes = (l.baseAddress, r.baseAddress); b.channels = 2; b.capacity_frames = UInt32(block)
                        var report = FRRenderReport()
                        return fr_render(renderer, &a, &b, UInt32(block), &report)
                    }
                }
            }
            guard result == FR_OK else { throw QMSFailure("render failed: \(result.rawValue)") }
            for i in 0..<block { output[start + i] = left[i] }
            start += block
        }
        _ = fr_collect(renderer)
        guard output.allSatisfy(\.isFinite) else { throw QMSFailure("render produced non-finite samples") }
        return output
    }

    /// Mean power in each band (Hz) over Hann-windowed 2048-sample frames, at most 24 bins per band.
    static func bands(_ x: [Float], from: Int, to: Int, _ bands: [(Double, Double)]) -> [Double] {
        let n = 2048
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
        var sums = [Double](repeating: 0, count: bands.count), counts = [Int](repeating: 0, count: bands.count)
        var start = from
        while start + n <= min(to, x.count) {
            let frame = (0..<n).map { Double(x[start + $0]) * window[$0] }
            for (index, band) in bands.enumerated() {
                let k0 = max(1, Int(ceil(band.0 * Double(n) / rate))), k1 = min(n / 2 - 1, Int(floor(band.1 * Double(n) / rate)))
                guard k1 >= k0 else { continue }
                let step = max(1, (k1 - k0 + 1) / 24)
                for k in stride(from: k0, through: k1, by: step) {
                    let w = 2 * Double.pi * Double(k) / Double(n), coefficient = 2 * cos(w)
                    var s1 = 0.0, s2 = 0.0
                    for sample in frame { let s0 = sample + coefficient * s1 - s2; s2 = s1; s1 = s0 }
                    sums[index] += s1 * s1 + s2 * s2 - coefficient * s1 * s2
                    counts[index] += 1
                }
            }
            start += n
        }
        return zip(sums, counts).map { $1 == 0 ? .nan : $0 / Double($1) }
    }

    static func energy(_ x: [Float], from: Double, to: Double) -> Double {
        x[Int(from * rate)..<min(x.count, Int(to * rate))].reduce(0) { $0 + Double($1) * Double($1) }
    }

    static let low = (50.0, 120.0), mid = (300.0, 3_000.0), high = (5_000.0, 16_000.0), upperMid = (3_000.0, 8_000.0)

    struct Measure { let lowRatio: Double; let highRatio: Double; let bands: [Double] }
    static func measure(_ parts: [ListeningRenderPart], _ input: [Float]) throws -> Measure {
        let out = try render(parts, input)
        let b = bands(out, from: Int(0.5 * rate), to: out.count, [low, mid, high, upperMid])
        return Measure(lowRatio: b[0] / b[1], highRatio: b[2] / b[1], bands: b)
    }
    /// Reverb tail after a burst stops, relative to the burst.
    static func tail(_ parts: [ListeningRenderPart]) throws -> Double {
        let out = try render(parts, noise(seconds: 0.6, silenceAfter: 1.2))
        return energy(out, from: 0.65, to: 1.4) / energy(out, from: 0.3, to: 0.6)
    }

    static func falling(_ v: [Double], slack: Double = 0.02) -> Bool {
        v.allSatisfy(\.isFinite) && zip(v, v.dropFirst()).allSatisfy { $1 <= $0 * (1 + slack) + 1e-12 }
    }
    static func rising(_ v: [Double], slack: Double = 0.02) -> Bool {
        v.allSatisfy(\.isFinite) && zip(v, v.dropFirst()).allSatisfy { $1 >= $0 * (1 - slack) - 1e-12 }
    }
}

extension QuickMenuSoundsChecks {
    // R. Laws on rendered output (positions 0, 0.5 and 1).
    static func renderGroup(_ c: QMSContext) async throws {
        let r = c.report
        let s = try await QMSSession.fresh(c.scratch.appendingPathComponent("render/library.json"))
        for name in QMS.newNames { try await s.select(name, on: "render." + name.replacingOccurrences(of: " ", with: "-").lowercased()) }
        let steady = QMSRender.noise(seconds: 1.5)
        func parts(_ option: String?, _ p: Double) async throws -> [ListeningRenderPart] {
            let spec = values.first { $0.option == option }!
            return try await sample(s, spec, target(spec, "render"), p).parts
        }
        let points = [0.0, 0.5, 1.0]
        for option in ["Hall", "Church"] {
            var bright: [Double] = [], tails: [Double] = []
            for p in points {
                let chain = try await parts(option, p)
                bright.append(try QMSRender.measure(chain, steady).highRatio)
                tails.append(try QMSRender.tail(chain))
            }
            r.note("rendered Big space \(option): high/mid \(bright), tail/burst \(tails)")
            r.check(QMSRender.falling(bright), "rendered Big space \(option): toward Back is never brighter \(bright)")
            r.check(QMSRender.rising(tails), "rendered Big space \(option): toward Back is never drier \(tails)")
        }
        let shellac = try QMSRender.measure(try await parts("Shellac", 0.5), steady)
        for option in ["Vinyl", "Tape"] {
            var measures: [QMSRender.Measure] = []
            for p in points { measures.append(try QMSRender.measure(try await parts(option, p), steady)) }
            let lows = measures.map(\.lowRatio), highs = measures.map(\.highRatio)
            r.note("rendered Old recording \(option): low/mid \(lows), high/mid \(highs); Shellac \(shellac.lowRatio), \(shellac.highRatio)")
            r.check(QMSRender.falling(lows) && QMSRender.falling(highs), "rendered Old recording \(option): more Wear never widens the band")
            r.check(measures.allSatisfy { shellac.lowRatio <= $0.lowRatio * 1.02 && shellac.highRatio <= $0.highRatio * 1.02 },
                    "rendered Shellac is narrower than \(option) at every Wear")
        }
        var depth: [Double] = []
        for p in points { depth.append(try QMSRender.measure(try await parts(nil, p), steady).highRatio) }
        r.note("rendered Underwater high/mid \(depth)")
        r.check(QMSRender.falling(depth), "rendered Underwater: more Depth is never brighter \(depth)")
        let surface = try QMSRender.measure(try await parts(nil, 0), steady)
        let original = QMSRender.bands(steady, from: Int(0.5 * QMSRender.rate), to: steady.count,
                                       [QMSRender.low, QMSRender.mid, QMSRender.high, QMSRender.upperMid])
        // All four bands, the high band (5-16 kHz) included. This is what Surface does today, and it is
        // not exact passthrough: the place low-pass stays in the chain at its 20 kHz end, a second-order
        // filter whose loss inside 5-16 kHz stays well under 0.5 dB and grows above 16 kHz, which no band
        // here measures. Whether Surface should bypass that filter is a listening question.
        let differences = [0, 1, 3, 2].map { 10 * log10(surface.bands[$0] / original[$0]) }
        r.note("rendered Underwater Surface minus input, dB (low, mid, upper mid, high): \(differences)")
        r.check(differences.allSatisfy { abs($0) <= 0.5 },
                "rendered Underwater Surface is the original sound within 0.5 dB in every band to 16 kHz \(differences)")
        r.check(differences[3] <= 0.05, "rendered Underwater Surface is never brighter than the input in the high band (\(differences[3]) dB)")
    }
}

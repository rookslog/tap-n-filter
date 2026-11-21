// Shard specs and slice runners for the enumerated suites.
//   A spec is "SUITE LENGTH HOLD FROM COUNT": S1, S2 and S3 take HOLD "x"; S4 and S5 take hold point 0, 1 or 2.
//   Each sequence is a fresh fixture; a slice runs sequences FROM ..< FROM+COUNT of the suite's
//   deterministic enumeration, so one sequence re-runs alone as "SUITE LENGTH HOLD INDEX 1".
// RED lines carry the sequence and its index; every slice ends with one ENUM-SUMMARY line.

import Foundation

func describe(_ events: [AEvent]) -> String { events.map(\.description).joined(separator: " ") }

@MainActor func report(_ name: String, _ events: [AEvent], _ v: Verdict, verbose: Bool) {
    if v.green {
        if verbose { print("PASS \(name) [\(describe(events))]" + (v.notes.isEmpty ? "" : " notes: " + v.notes.joined(separator: "; "))) }
        return
    }
    print("RED \(name) [\(describe(events))]")
    if let u = v.unsupported { print("    unsupported: \(u)") }
    if v.watchdogs > 0 { print("    watchdog fired \(v.watchdogs) time(s)") }
    for d in v.divergences.prefix(4) { print("    diverges: \(d)") }
    for x in v.violations.prefix(4) { print("    violates: \(x)") }
    for n in v.notes.prefix(3) { print("    note: \(n)") }
}

/// MODE=send runs admission sequences in send-time mode; the default is await-each.
let sendTimeMode = ProcessInfo.processInfo.environment["MODE"] == "send"

/// What one slice did. `total` is the size of the whole enumeration, `count` the sequences this slice ran.
struct SliceResult {
    var suite: String
    var length: Int
    var hold: Int?
    var from: Int
    var count: Int
    var total: Int
    var green = 0
    var red = 0
    var unsupported = 0
    var seconds = 0.0
    /// Sequences with a delivery first taken after the final release (S5 only; observation, not a failure).
    var late = 0
    var redSequences: [String] = []
    /// Set when the slice could not start (for example its shared fixture could not be built).
    var setupFailure: String?

    var clean: Bool { setupFailure == nil && red == 0 && unsupported == 0 && green == count }
    var summary: String {
        "ENUM-SUMMARY suite=\(suite) level=\(length) hold=\(hold.map { String($0) } ?? "x") from=\(from) count=\(count) total=\(total) "
            + "green=\(green) red=\(red) unsupported=\(unsupported) result=\(clean ? "clean" : "FAIL") late=\(late) seconds=\(String(format: "%.1f", seconds))"
            + (setupFailure.map { " setup=\"\($0)\"" } ?? "")
    }
}

/// One slice of an admission suite (S1, S2, S3). A sequence the build can't drive counts as unsupported.
@MainActor func runSlice(_ suite: String, _ alphabet: [AEvent], length: Int, from: Int, count: Int) async -> SliceResult {
    let all = enumerate(alphabet, length: length)
    let slice = all.dropFirst(from).prefix(count)
    var result = SliceResult(suite: suite, length: length, hold: nil, from: from, count: slice.count, total: all.count)
    let start = Date()
    var keys: [String: (count: Int, example: [AEvent])] = [:]
    for (offset, events) in slice.enumerated() {
        let v = await compareAdmission(events, sendTime: sendTimeMode)
        if v.unsupported != nil {
            result.unsupported += 1
            report("\(suite) L\(length) #\(from + offset)", events, v, verbose: false)
            continue
        }
        if v.green { result.green += 1 } else {
            result.red += 1
            result.redSequences.append(describe(events))
            let k = v.key
            if keys[k] == nil { keys[k] = (0, events) }
            keys[k]!.count += 1
            report("\(suite) L\(length) #\(from + offset)", events, v, verbose: false)
        }
    }
    result.seconds = Date().timeIntervalSince(start)
    for (k, value) in keys.sorted(by: { $0.value.count > $1.value.count }) {
        print("CAUSE \(suite) \"\(k)\" \(value.count) first [\(describe(value.example))]")
    }
    return result
}

/// The size of each suite's enumeration at the length CI runs it. A different total means the enumeration
/// itself changed (model, alphabet or enabling rules), which is a failure of the run, not of the app.
let pinnedTotals: [String: Int] = ["S1 5": 1997, "S2 4": 1685, "S3 4": 10170, "S4 5": 6763, "S5 5": 2218]

struct ShardSpec: CustomStringConvertible {
    let suite: String
    let length: Int
    let hold: Int?
    let from: Int
    let count: Int
    var description: String { "\(suite) \(length) \(hold.map { String($0) } ?? "x") \(from) \(count)" }

    /// Parses "SUITE LENGTH HOLD FROM COUNT".
    init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 5, let length = Int(parts[1]), let from = Int(parts[3]), let count = Int(parts[4]) else { return nil }
        suite = parts[0]; self.length = length; self.from = from; self.count = count
        switch suite {
        case "S1", "S2", "S3":
            guard parts[2] == "x" else { return nil }
            hold = nil
        case "S4", "S5":
            guard let h = Int(parts[2]), (0...2).contains(h) else { return nil }
            hold = h
        default: return nil
        }
    }
}

@MainActor func runShard(_ spec: ShardSpec) async -> SliceResult {
    let alphabets: [String: [AEvent]] = ["S1": suiteS1, "S2": suiteS2, "S3": suiteS3]
    switch spec.suite {
    case "S4": return await runLaneSlice(length: spec.length, hold: spec.hold ?? 0, from: spec.from, count: spec.count)
    case "S5": return await runS5Slice(length: spec.length, hold: spec.hold ?? 0, from: spec.from, count: spec.count)
    default: return await runSlice(spec.suite, alphabets[spec.suite] ?? [], length: spec.length, from: spec.from, count: spec.count)
    }
}

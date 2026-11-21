import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Effects

// EQ stress probe — a diagnostic, not a test.
//
// A hosted CI run once read `lp.frequency` back as 57.79931 instead of 800 in
// the first test case that read values back from a fresh `EQNode` (an earlier
// case may already have constructed one); `hp.frequency` and both Q values
// were correct, and a re-run passed. This executable tries to tell the
// candidate explanations apart on the runner where it happened, outside
// XCTest, with control over process lifetime:
//
//   A  fresh process per sample: create one EQNode, read all four values at
//      once (the test's order). The parent never touches audio itself, so each
//      child is the first audio use in its process.
//   B  one process, many EQNodes in a loop.
//   C  as A, then read again at +1 ms, +10 ms, +100 ms after creation and
//      after spinning the run loop for 100 ms: does a wrong value heal, or
//      does a right one later revert?
//   D  one process: dump every band of fresh, never-written AVAudioUnitEQ
//      units (1, 2 and 16 bands) through both the Obj-C wrapper and
//      AudioUnitGetParameter, to test whether 57.79931 is a factory default.
//   E  fresh process per sample: replay EQNode's init sequence on a raw
//      AVAudioUnitEQ through AudioUnitSetParameter, recording every OSStatus
//      (EQNode's own setter path returns void).
//
// EQNode keeps its unit `private`. The probe reaches it read-only through
// `Mirror` (stored-property label "eq") to compare the wrapper's value with
// the unit's own parameter; if the label changes, the direct fields print as
// `direct=unavailable` and everything else still runs. On a mismatch the
// probe also writes the expected value once through AudioUnitSetParameter on
// the node's unit and reports the status and the re-read. That happens after
// the sample is recorded, so it can never turn a failure into a pass.
//
// Nothing here attaches a node to an engine or starts audio: constructing
// AVAudioUnitEQ and AVAudioMixerNode instances makes no sound. Arm D also
// queries (never opens) the default output device.
//
// Usage:  tnf-eq-stress-probe <A|B|C|D|E> [count] [--seconds S]
// Output: ENV, FIRST (iteration 0, always), FAIL (one per mismatch),
//         CHILDERR, DUMP (arm D) and one SUMMARY line, all key=value.
// Exit:   0 clean, 1 mismatch seen, 2 usage, 4 child errors without mismatch.

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: Constants

let expectedHPFrequency: Float = 80.0
let expectedLPFrequency: Float = 800.0
let expectedQ: Float = 0.707
let qAccuracy: Float = 0.001
/// A creation slower than this counts as "slow" in the summary. The failing
/// CI case took 1.107 s against about 1 ms for its neighbours.
let slowCreateMs: Double = 100.0
/// At most this many FAIL lines per arm; the rest are counted only.
let maxFailLines = 25

let globalScope = AudioUnitScope(kAudioUnitScope_Global)
let pBypass = AudioUnitParameterID(kAUNBandEQParam_BypassBand)
let pType = AudioUnitParameterID(kAUNBandEQParam_FilterType)
let pFreq = AudioUnitParameterID(kAUNBandEQParam_Frequency)
let pBandwidth = AudioUnitParameterID(kAUNBandEQParam_Bandwidth)
let pGlobalGain = AudioUnitParameterID(kAUNBandEQParam_GlobalGain)

// MARK: Helpers

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func msSince(_ start: UInt64) -> Double { Double(nowNs() &- start) / 1_000_000 }
func ms3(_ v: Double) -> String { String(format: "%.3f", v) }
func fv(_ v: Float?) -> String { v.map { "\($0)" } ?? "nil" }
func token(_ s: String) -> String {
    s.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "=", with: ":")
}

func param(_ base: AudioUnitParameterID, _ band: Int) -> AudioUnitParameterID {
    base + AudioUnitParameterID(band)
}

func getParam(_ unit: AudioUnit, _ id: AudioUnitParameterID) -> (Float, OSStatus) {
    var value: AudioUnitParameterValue = 0
    let status = AudioUnitGetParameter(unit, id, globalScope, 0, &value)
    return (value, status)
}

func setParam(_ unit: AudioUnit, _ id: AudioUnitParameterID, _ value: Float) -> OSStatus {
    AudioUnitSetParameter(unit, id, globalScope, 0, value, 0)
}

/// Value, or `e<status>` when the call failed.
func sv(_ r: (Float, OSStatus)) -> String { r.1 == noErr ? "\(r.0)" : "e\(r.1)" }

// Same mapping as EQNode (private there).
func qToBandwidth(_ q: Float) -> Float {
    Float((2.0 / log(2.0)) * asinh(1.0 / (2.0 * Double(max(q, 0.0001)))))
}
func bandwidthToQ(_ bw: Float) -> Float {
    guard bw > 0 else { return expectedQ }
    return Float(1.0 / (2.0 * sinh(Double(bw) * log(2.0) / 2.0)))
}

/// The derived (undocumented) 16-point table the CI value appears to match:
/// 40 Hz to 10 kHz, log-spaced, k = 0...15.
func tableValue(_ k: Int) -> Float { Float(40.0 * pow(250.0, Double(k) / 15.0)) }
func matchesTable(_ v: Float, _ k: Int) -> Bool {
    abs(v - tableValue(k)) <= 1e-5 * tableValue(k)
}

func privateUnit(of node: EQNode) -> AVAudioUnitEQ? {
    Mirror(reflecting: node).children.first { $0.label == "eq" }?.value as? AVAudioUnitEQ
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: buffer)
}

func printEnv(arm: String) {
    // Machine model, not machine name: tells a virtual Mac from a physical one.
    print("ENV arm=\(arm) os=\(token(ProcessInfo.processInfo.operatingSystemVersionString)) "
        + "model=\(token(sysctlString("hw.model"))) cpus=\(ProcessInfo.processInfo.activeProcessorCount)")
}

// MARK: Sampling

/// Which of the four read-backs disagree with the spec.
func badFields(hpf: Float?, lpf: Float?, hpq: Float?, lpq: Float?) -> [String] {
    var bad: [String] = []
    if hpf != expectedHPFrequency { bad.append("hpf") }
    if lpf != expectedLPFrequency { bad.append("lpf") }
    if abs((hpq ?? 0) - expectedQ) > qAccuracy { bad.append("hpq") }
    if abs((lpq ?? 0) - expectedQ) > qAccuracy { bad.append("lpq") }
    return bad
}

/// The unit's own view of bands 0 and 1, read through AudioUnitGetParameter.
func directFields(_ eq: AVAudioUnitEQ?) -> [String] {
    guard let eq = eq else { return ["direct=unavailable"] }
    let unit = eq.audioUnit
    var parts: [String] = []
    for (label, band) in [("hp", 0), ("lp", 1)] {
        parts.append("d_\(label)f=\(sv(getParam(unit, param(pFreq, band))))")
        parts.append("d_\(label)t=\(sv(getParam(unit, param(pType, band))))")
        parts.append("d_\(label)bw=\(sv(getParam(unit, param(pBandwidth, band))))")
        parts.append("d_\(label)byp=\(sv(getParam(unit, param(pBypass, band))))")
    }
    return parts
}

/// On a mismatch only: write each wrong value once through the lower-level
/// API on the node's own unit and record the status and both re-reads.
func rewriteFields(node: EQNode, eq: AVAudioUnitEQ?, bad: [String]) -> [String] {
    guard let eq = eq, !bad.isEmpty else { return [] }
    let unit = eq.audioUnit
    var parts: [String] = []
    for field in bad {
        let target: (AudioUnitParameterID, Float, String)
        switch field {
        case "hpf": target = (param(pFreq, 0), expectedHPFrequency, "hp.frequency")
        case "lpf": target = (param(pFreq, 1), expectedLPFrequency, "lp.frequency")
        case "hpq": target = (param(pBandwidth, 0), qToBandwidth(expectedQ), "hp.Q")
        case "lpq": target = (param(pBandwidth, 1), qToBandwidth(expectedQ), "lp.Q")
        default: continue
        }
        let status = setParam(unit, target.0, target.1)
        parts.append("rw_\(field)_st=\(status)")
        parts.append("rw_\(field)_wrapper=\(fv(node.parameterValue(target.2)))")
        parts.append("rw_\(field)_direct=\(sv(getParam(unit, target.0)))")
    }
    return parts
}

struct NodeSample {
    let node: EQNode
    let eq: AVAudioUnitEQ?
    let createdAt: UInt64
    var fields: [String]
    var bad: [String]
}

/// Create one EQNode and read it back exactly as the failing test did.
func sampleFreshNode() -> NodeSample {
    let t0 = nowNs()
    let node = EQNode()
    let t1 = nowNs()
    // Same order as test_parameter_default_values_match_spec, nothing between.
    let hpf = node.parameterValue("hp.frequency")
    let lpf = node.parameterValue("lp.frequency")
    let hpq = node.parameterValue("hp.Q")
    let lpq = node.parameterValue("lp.Q")
    let warnings = node.configurationWarnings
    let eq = privateUnit(of: node)
    let bad = badFields(hpf: hpf, lpf: lpf, hpq: hpq, lpq: lpq)
    var fields = [
        "ok=\(bad.isEmpty ? 1 : 0)",
        "init_ms=\(ms3(Double(t1 &- t0) / 1_000_000))",
        "hpf=\(fv(hpf))", "lpf=\(fv(lpf))", "hpq=\(fv(hpq))", "lpq=\(fv(lpq))",
        "bad=\(bad.isEmpty ? "none" : bad.joined(separator: ","))",
        "warn=\(warnings.count)",
    ]
    if !warnings.isEmpty { fields.append("warns=\(token(warnings.joined(separator: ";")))") }
    fields += directFields(eq)
    return NodeSample(node: node, eq: eq, createdAt: t1, fields: fields, bad: bad)
}

/// Arm C's extra checkpoints. Returns the fields and whether any read was bad.
func healCheckpoints(_ s: NodeSample) -> ([String], [String]) {
    var trajectory = [s.bad.isEmpty ? "ok" : "bad"]
    var fields: [String] = []
    var everBad = s.bad
    func checkpoint(_ name: String) {
        let hpf = s.node.parameterValue("hp.frequency")
        let lpf = s.node.parameterValue("lp.frequency")
        let hpq = s.node.parameterValue("hp.Q")
        let lpq = s.node.parameterValue("lp.Q")
        let bad = badFields(hpf: hpf, lpf: lpf, hpq: hpq, lpq: lpq)
        trajectory.append(bad.isEmpty ? "ok" : "bad")
        for b in bad where !everBad.contains(b) { everBad.append(b) }
        let direct = s.eq.map { sv(getParam($0.audioUnit, param(pFreq, 1))) } ?? "unavailable"
        fields.append("\(name)=\(fv(hpf))/\(fv(lpf))/\(fv(hpq))/\(fv(lpq))/d_lpf:\(direct)")
    }
    for (name, offsetMs) in [("t1ms", 1.0), ("t10ms", 10.0), ("t100ms", 100.0)] {
        let remaining = offsetMs - msSince(s.createdAt)
        if remaining > 0 { usleep(useconds_t(remaining * 1000)) }
        checkpoint(name)
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    checkpoint("runloop")
    return (["traj=\(trajectory.joined(separator: ">"))"] + fields, everBad)
}

/// Arm E: EQNode's init sequence, replayed on a raw unit through the C API.
func sampleRawReplay() -> ([String], [String]) {
    let t0 = nowNs()
    let eq = AVAudioUnitEQ(numberOfBands: 2)
    let initMs = Double(nowNs() &- t0) / 1_000_000
    let unit = eq.audioUnit
    let bw = qToBandwidth(expectedQ)
    let hpType = Float(AVAudioUnitEQFilterType.resonantHighPass.rawValue)
    let lpType = Float(AVAudioUnitEQFilterType.resonantLowPass.rawValue)
    let writes: [(String, AudioUnitParameterID, Float)] = [
        ("gg", pGlobalGain, 0),
        ("hpt", param(pType, 0), hpType), ("hpf", param(pFreq, 0), expectedHPFrequency),
        ("hpbw", param(pBandwidth, 0), bw), ("hpbyp", param(pBypass, 0), 0),
        ("lpt", param(pType, 1), lpType), ("lpf", param(pFreq, 1), expectedLPFrequency),
        ("lpbw", param(pBandwidth, 1), bw), ("lpbyp", param(pBypass, 1), 0),
    ]
    var statuses: [String] = []
    var nonzero: [String] = []
    for (name, id, value) in writes {
        let status = setParam(unit, id, value)
        statuses.append("\(name):\(status)")
        if status != noErr { nonzero.append(name) }
    }
    // Wrapper reads first (the same getter EQNode uses), then the unit's own.
    let hpf = eq.bands[0].frequency
    let lpf = eq.bands[1].frequency
    let hpq = bandwidthToQ(eq.bands[0].bandwidth)
    let lpq = bandwidthToQ(eq.bands[1].bandwidth)
    var bad = badFields(hpf: hpf, lpf: lpf, hpq: hpq, lpq: lpq)
    if !nonzero.isEmpty { bad.append("status") }
    var fields = [
        "ok=\(bad.isEmpty ? 1 : 0)",
        "init_ms=\(ms3(initMs))",
        "hpf=\(hpf)", "lpf=\(lpf)", "hpq=\(hpq)", "lpq=\(lpq)",
        "bad=\(bad.isEmpty ? "none" : bad.joined(separator: ","))",
        "set_st=\(statuses.joined(separator: ","))",
    ]
    fields += directFields(eq)
    return (fields, bad)
}

// MARK: Child mode (one sample, one line)

func runChildSample(arm: String) -> Never {
    var fields: [String]
    switch arm {
    case "A":
        let s = sampleFreshNode()
        fields = s.fields + rewriteFields(node: s.node, eq: s.eq, bad: s.bad)
    case "C":
        let s = sampleFreshNode()
        let (extra, everBad) = healCheckpoints(s)
        fields = s.fields + extra
        if s.bad.isEmpty && !everBad.isEmpty {
            // Right at first, wrong later: mark the sample as failed.
            fields[0] = "ok=0"
            fields.append("later_bad=\(everBad.joined(separator: ","))")
        }
        fields += rewriteFields(node: s.node, eq: s.eq, bad: everBad)
    case "E":
        fields = sampleRawReplay().0
    default:
        exit(2)
    }
    print("SAMPLE " + fields.joined(separator: " "))
    exit(0)
}

// MARK: Summary

func parseFields(_ line: String) -> [String: String] {
    var map: [String: String] = [:]
    for part in line.split(separator: " ") {
        guard let eqIndex = part.firstIndex(of: "=") else { continue }
        map[String(part[..<eqIndex])] = String(part[part.index(after: eqIndex)...])
    }
    return map
}

final class Tally {
    let arm: String
    var samples = 0
    var failures = 0
    var printedFailures = 0
    var badCounts: [String: Int] = [:]
    var warned = 0
    var childErrors = 0
    var initMs: [Double] = []
    var trajectories: [String: Int] = [:]
    var firstInitMs: String = "none"
    let start = nowNs()

    init(arm: String) { self.arm = arm }

    func record(index: Int, line: String) {
        let map = parseFields(line)
        samples += 1
        if let v = map["init_ms"], let d = Double(v) { initMs.append(d) }
        if index == 0 {
            firstInitMs = map["init_ms"] ?? "none"
            print("FIRST arm=\(arm) i=0 \(line)")
        }
        if let traj = map["traj"] { trajectories[traj, default: 0] += 1 }
        if let w = map["warn"], w != "0" { warned += 1 }
        guard map["ok"] == "0" else { return }
        failures += 1
        for field in (map["bad"] ?? "").split(separator: ",") where field != "none" {
            badCounts[String(field), default: 0] += 1
        }
        if let later = map["later_bad"] {
            for field in later.split(separator: ",") { badCounts["later_\(field)", default: 0] += 1 }
        }
        if printedFailures < maxFailLines && index != 0 {
            printedFailures += 1
            print("FAIL arm=\(arm) i=\(index) \(line)")
        } else if index == 0 {
            printedFailures += 1
            print("FAIL arm=\(arm) i=0 (see FIRST line)")
        }
    }

    func childError(index: Int, detail: String) {
        childErrors += 1
        if childErrors <= maxFailLines { print("CHILDERR arm=\(arm) i=\(index) \(detail)") }
    }

    func finish(stoppedBy: String) -> Never {
        let sorted = initMs.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let maxMs = sorted.last ?? 0
        let slow = initMs.filter { $0 > slowCreateMs }.count
        var parts = [
            "SUMMARY arm=\(arm)",
            "samples=\(samples)",
            "failures=\(failures)",
            "bad_hpf=\(badCounts["hpf", default: 0])",
            "bad_lpf=\(badCounts["lpf", default: 0])",
            "bad_hpq=\(badCounts["hpq", default: 0])",
            "bad_lpq=\(badCounts["lpq", default: 0])",
            "warned=\(warned)",
            "child_errors=\(childErrors)",
            "init_ms_first=\(firstInitMs)",
            "init_ms_median=\(ms3(median))",
            "init_ms_max=\(ms3(maxMs))",
            "slow_creates=\(slow)",
            "elapsed_s=\(ms3(msSince(start) / 1000))",
            "stopped_by=\(stoppedBy)",
        ]
        if let status = badCounts["status"] { parts.append("bad_status=\(status)") }
        for key in badCounts.keys.sorted() where key.hasPrefix("later_") {
            parts.append("\(key)=\(badCounts[key]!)")
        }
        if !trajectories.isEmpty {
            let shown = trajectories.keys.sorted().map { "\($0):\(trajectories[$0]!)" }
            parts.append("trajectories=\(shown.joined(separator: ","))")
        }
        print(parts.joined(separator: " "))
        if failures > 0 { exit(1) }
        exit(childErrors > 0 ? 4 : 0)
    }
}

// MARK: Parent modes

let selfURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])

/// Run one child sample. Returns its SAMPLE payload, or nil and a reason.
func spawnChild(arm: String) -> (String?, String) {
    let process = Process()
    process.executableURL = selfURL
    process.arguments = ["child-\(arm)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (nil, "spawn_failed") }
    // A child that never returns would otherwise hold the whole arm.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    let text = String(decoding: data, as: UTF8.self)
    let line = text.split(separator: "\n").first { $0.hasPrefix("SAMPLE ") }
    let how = process.terminationReason == .uncaughtSignal ? "signal" : "exit"
    let reason = "\(how)=\(process.terminationStatus)"
    guard let found = line, process.terminationStatus == 0 else { return (nil, reason) }
    return (String(found.dropFirst("SAMPLE ".count)), reason)
}

func runFreshProcessArm(arm: String, count: Int, deadline: UInt64) -> Never {
    printEnv(arm: arm)
    let tally = Tally(arm: arm)
    for index in 0..<count {
        if nowNs() >= deadline { tally.finish(stoppedBy: "time") }
        let (payload, reason) = spawnChild(arm: arm)
        if let payload = payload {
            tally.record(index: index, line: payload)
        } else {
            tally.childError(index: index, detail: reason)
        }
    }
    tally.finish(stoppedBy: "count")
}

func runInProcessArm(count: Int, deadline: UInt64) -> Never {
    printEnv(arm: "B")
    let tally = Tally(arm: "B")
    for index in 0..<count {
        if nowNs() >= deadline { tally.finish(stoppedBy: "time") }
        autoreleasepool {
            let s = sampleFreshNode()
            let fields = s.fields + rewriteFields(node: s.node, eq: s.eq, bad: s.bad)
            tally.record(index: index, line: fields.joined(separator: " "))
        }
    }
    tally.finish(stoppedBy: "count")
}

func dumpUnit(label: String, eq: AVAudioUnitEQ) -> Int {
    let unit = eq.audioUnit
    var maxBands: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let maxStatus = AudioUnitGetProperty(
        unit, AudioUnitPropertyID(kAUNBandEQProperty_MaxNumberOfBands), globalScope, 0, &maxBands, &size)
    var numBands: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    let numStatus = AudioUnitGetProperty(
        unit, AudioUnitPropertyID(kAUNBandEQProperty_NumberOfBands), globalScope, 0, &numBands, &size)
    // Probe all 16 indices whatever the band count, to see whether bands past
    // the count exist and hold table values.
    let probeCount = 16
    func row(_ base: AudioUnitParameterID) -> [(Float, OSStatus)] {
        (0..<probeCount).map { getParam(unit, param(base, $0)) }
    }
    let freqs = row(pFreq)
    var matches = 0
    for (k, r) in freqs.enumerated() where r.1 == noErr && matchesTable(r.0, k) { matches += 1 }
    let bands = eq.bands
    print("DUMP unit=\(label) wrapper_bands=\(bands.count) "
        + "num_bands=\(numStatus == noErr ? "\(numBands)" : "e\(numStatus)") "
        + "max_bands=\(maxStatus == noErr ? "\(maxBands)" : "e\(maxStatus)") "
        + "sr=\(eq.outputFormat(forBus: 0).sampleRate)")
    print("DUMP unit=\(label) attr=freq direct=\(freqs.map(sv).joined(separator: ",")) "
        + "wrapper=\(bands.map { "\($0.frequency)" }.joined(separator: ",")) table_match=\(matches)/\(probeCount)")
    print("DUMP unit=\(label) attr=type direct=\(row(pType).map(sv).joined(separator: ",")) "
        + "wrapper=\(bands.map { "\($0.filterType.rawValue)" }.joined(separator: ","))")
    print("DUMP unit=\(label) attr=bw direct=\(row(pBandwidth).map(sv).joined(separator: ",")) "
        + "wrapper=\(bands.map { "\($0.bandwidth)" }.joined(separator: ","))")
    print("DUMP unit=\(label) attr=bypass direct=\(row(pBypass).map(sv).joined(separator: ",")) "
        + "wrapper=\(bands.map { $0.bypass ? "1" : "0" }.joined(separator: ","))")
    return matches
}

func defaultOutputDevice() -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain))
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard status == noErr else { return "error:\(status)" }
    guard device != 0 else { return "none" }
    var rate = Float64(0)
    address.mSelector = AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate)
    size = UInt32(MemoryLayout<Float64>.size)
    let rateStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rateStatus == noErr ? "present:\(rate)" : "present:rate_error_\(rateStatus)"
}

func runDumpArm() -> Never {
    printEnv(arm: "D")
    // Raw units first, so the first one is also this process's first audio use.
    var matches: [String] = []
    var rawTwoBand1 = "none"
    for count in [1, 2, 16] {
        let eq = AVAudioUnitEQ(numberOfBands: count)
        let m = dumpUnit(label: "raw\(count)", eq: eq)
        matches.append("raw\(count):\(m)")
        if count == 2 { rawTwoBand1 = sv(getParam(eq.audioUnit, param(pFreq, 1))) }
    }
    let node = EQNode()
    var nodeDirect = "unavailable"
    if let eq = privateUnit(of: node) {
        _ = dumpUnit(label: "node", eq: eq)
        nodeDirect = "available"
    }
    print("SUMMARY arm=D raw2_band1_freq=\(rawTwoBand1) table_band1=\(tableValue(1)) "
        + "table_match=\(matches.joined(separator: ",")) node_unit=\(nodeDirect) "
        + "node_warn=\(node.configurationWarnings.count) default_output=\(defaultOutputDevice())")
    exit(0)
}

// MARK: Entry

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: tnf-eq-stress-probe <A|B|C|D|E> [count] [--seconds S]\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if let first = arguments.first, first.hasPrefix("child-") {
    runChildSample(arm: String(first.dropFirst("child-".count)))
}
var seconds = 600.0
if let flag = arguments.firstIndex(of: "--seconds") {
    guard flag + 1 < arguments.count, let s = Double(arguments[flag + 1]), s > 0 else { usage() }
    seconds = s
    arguments.removeSubrange(flag...(flag + 1))
}
guard let arm = arguments.first else { usage() }
let defaultCount = arm == "B" ? 200_000 : 200
var count = defaultCount
if arguments.count > 1 {
    guard let n = Int(arguments[1]), n > 0 else { usage() }
    count = n
}
let deadline = nowNs() + UInt64(seconds * 1_000_000_000)

switch arm {
case "A", "C", "E": runFreshProcessArm(arm: arm, count: count, deadline: deadline)
case "B": runInProcessArm(count: count, deadline: deadline)
case "D": runDumpArm()
default: usage()
}

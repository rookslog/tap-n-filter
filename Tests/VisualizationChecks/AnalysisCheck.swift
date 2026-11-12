import Foundation
import Darwin
import OutputGate

@main struct AnalysisCheck {
  static func main() {
    let id = UUID()
    var cases = 0
    for rate in [8_000.0, 44_100, 48_000, 96_000, 192_000] {
      let storage = ogv_create(rate, 2)!
      let n = Int(ogv_window_frames(storage))
      let analyzer = VisualizationAnalyzer(count: n)!
      let w = UnsafeMutablePointer<OGVWindow>.allocate(capacity: 1); w.initialize(to: OGVWindow())
      for kind in 0..<4 {
        var b = [Float](repeating: 0, count: n), a = b
        for i in 0..<n {
          b[i] = kind == 0 ? 0 : kind == 1 ? 0.5 : Float(sin(2 * Double.pi * 16 * Double(i) / Double(n))) * 0.5
          a[i] = b[i] * 0.5
        }
        let right = b.map { kind == 3 ? -$0 : $0 }, aright = a.map { kind == 3 ? -$0 : $0 }
        var m = OGVMeta(); m.channels = 2; m.rate = rate; m.assignment = 1; m.source = 1; m.format = 1
        ogv_request(storage, UInt64(kind+1))
        b.withUnsafeBufferPointer { bp in a.withUnsafeBufferPointer { ap in
          right.withUnsafeBufferPointer { rp in aright.withUnsafeBufferPointer { arp in
            var before: [UnsafePointer<Float>?] = [bp.baseAddress, rp.baseAddress]
            var after: [UnsafePointer<Float>?] = [ap.baseAddress, arp.baseAddress]
            before.withUnsafeMutableBufferPointer { bb in after.withUnsafeMutableBufferPointer { aa in
              ogv_record(storage, bb.baseAddress, aa.baseAddress, UInt32(n), &m, 0, 0)
            }}
          }}
        }}
        precondition(ogv_latest(storage, w) != 0)
        let f = analyzer.analyze(w, assignment: id, mode: .spectrum)
        if kind == 0 { precondition(f.silent && f.beforeRMSDBFS == -80 && f.beforeSpectrum.allSatisfy { $0 == -80 }) }
        else {
          precondition(!f.silent && abs(f.afterRMSDBFS - f.beforeRMSDBFS + 6.0206) < 0.001)
          if kind == 1 { precondition(f.beforeWave.allSatisfy { abs($0.low - 0.5) < 0.0001 && abs($0.high - 0.5) < 0.0001 }) }
          if kind > 1 {
            let power = f.beforeSpectrum.reduce(0.0) { $0 + pow(10, Double($1) / 10) }
            precondition(abs(10 * log10(power) - Double(f.beforeRMSDBFS)) < 0.05, "FFT normalization")
            precondition(f.beforeWave.contains { $0.low < -0.4 && $0.high > 0.4 } || kind == 2)
          }
        }
        cases += 1
      }
      let quiet = [Float](repeating: 0, count: n), tail = [Float](repeating: 0.25, count: n)
      var tailMeta = OGVMeta(); tailMeta.channels = 2; tailMeta.rate = rate; tailMeta.assignment = 1; tailMeta.source = 1; tailMeta.format = 1
      ogv_request(storage, 99)
      quiet.withUnsafeBufferPointer { q in tail.withUnsafeBufferPointer { a in
        var before: [UnsafePointer<Float>?] = [q.baseAddress, q.baseAddress], after: [UnsafePointer<Float>?] = [a.baseAddress, a.baseAddress]
        before.withUnsafeMutableBufferPointer { b in after.withUnsafeMutableBufferPointer { a in ogv_record(storage, b.baseAddress, a.baseAddress, UInt32(n), &tailMeta, 0, 0) } }
      } }
      precondition(ogv_latest(storage, w) != 0)
      let tailFrame = analyzer.analyze(w, assignment: id, mode: .levels)
      precondition(!tailFrame.silent && tailFrame.beforeRMSDBFS == -80 && abs(tailFrame.afterRMSDBFS + 12.0412) < 0.001)
      cases += 1
      ogv_request(storage, 0); precondition(ogv_scrub_disabled(storage) != 0); ogv_destroy(storage)
      w.deinitialize(count: 1); w.deallocate()
    }
    var capture: VisualizationCapture? = VisualizationCapture.create(assignment: id, rate: 48_000, channels: 1)
    let request = VisualizationRequest(epoch: 31, assignment: id, mode: .waveform)
    capture!.setDemand(request)
    let storage = capture!.storage
    let n = Int(ogv_window_frames(storage))
    let values = [Float](repeating: 0, count: n)
    var m = OGVMeta(); m.channels = 1; m.rate = 48_000; m.assignment = 1; m.source = 1; m.format = 1; m.last_host_time = mach_absolute_time()
    values.withUnsafeBufferPointer { buf in
      var p: [UnsafePointer<Float>?] = [buf.baseAddress]
      p.withUnsafeMutableBufferPointer { pointers in ogv_record(storage, pointers.baseAddress, pointers.baseAddress, UInt32(n), &m, 0, 0) }
    }
    Thread.sleep(forTimeInterval: 0.08)
    capture!.setDemand(request)
    if case .live(let f) = capture!.snapshot(epoch: 31) { precondition(f.silent) } else { preconditionFailure("same request must not reset") }
    var remembered: VisualizationFrame?
    if case .live(let frame) = capture!.snapshot(epoch: 31) { remembered = frame }
    for mode in [VisualizationMode.spectrum, .levels] {
      capture!.setDemand(VisualizationRequest(epoch: 31, assignment: id, mode: mode))
      switch capture!.snapshot(epoch: 31) {
      case .unavailable(.warming): break
      case .live(let f): precondition(f.mode == mode)
      default: preconditionFailure("mode switch must not flash unavailable")
      }
      Thread.sleep(forTimeInterval: 0.06)
      if case .live(let f) = capture!.snapshot(epoch: 31) {
        precondition(f.mode == mode && f.sequence == remembered!.sequence && f.hostTime == remembered!.hostTime && f.requestEpoch == remembered!.requestEpoch)
      } else { preconditionFailure("retained-window reanalysis") }
    }
    precondition({ if case .unavailable(.stale) = capture!.snapshot(epoch: 31, now: UInt64.max) { return true }; return false }())
    capture!.setDemand(nil)
    precondition({ if case .unavailable = capture!.snapshot(epoch: 31) { return true }; return false }())
    let reopen = VisualizationRequest(epoch: 32, assignment: id, mode: .levels)
    capture!.setDemand(reopen)
    precondition({ if case .unavailable = capture!.snapshot(epoch: 31) { return true }; return false }())
    capture!.setDemand(VisualizationRequest(epoch: 33, assignment: id, mode: .spectrum))
    capture!.setDemand(nil)
    capture!.setDemand(VisualizationRequest(epoch: 34, assignment: id, mode: .levels))
    m.last_host_time = mach_absolute_time(); m.source = 9
    values.withUnsafeBufferPointer { buf in
      var p: [UnsafePointer<Float>?] = [buf.baseAddress]
      p.withUnsafeMutableBufferPointer { pointers in ogv_record(storage, pointers.baseAddress, pointers.baseAddress, UInt32(n), &m, 0, 0) }
    }
    Thread.sleep(forTimeInterval: 0.06)
    precondition({ if case .unavailable(.invalid) = capture!.snapshot(epoch: 34) { return true }; return false }())
    m.source = 1; m.last_host_time = mach_absolute_time(); m.first_frame += UInt64(n)
    values.withUnsafeBufferPointer { buf in
      var p: [UnsafePointer<Float>?] = [buf.baseAddress]
      p.withUnsafeMutableBufferPointer { pointers in ogv_record(storage, pointers.baseAddress, pointers.baseAddress, UInt32(n), &m, 0, 0) }
    }
    Thread.sleep(forTimeInterval: 0.06)
    if case .live(let frame) = capture!.snapshot(epoch: 34) { precondition(frame.mode == .levels && frame.sourceEpoch == 1) }
    else { preconditionFailure("current source/mode recovery after raced close/reopen") }
    capture!.setDemand(nil); capture = nil
    Thread.sleep(forTimeInterval: 0.03)
    func expect(_ condition: Bool, _ message: String) {
      if !condition { print("FAIL S-01 " + message); exit(1) }
    }
    var gapCapture: VisualizationCapture? = VisualizationCapture.create(assignment: id, rate: 48_000, channels: 1)
    gapCapture!.setDemand(VisualizationRequest(epoch: 71, assignment: id, mode: .waveform))
    let gapStorage = gapCapture!.storage
    var gapMeta = OGVMeta(); gapMeta.channels = 1; gapMeta.rate = 48_000
    gapMeta.assignment = 1; gapMeta.source = 1; gapMeta.format = 1; gapMeta.topology = 1
    let gapValues = [Float](repeating: 0.25, count: n)
    var clock = mach_timebase_info_data_t(); mach_timebase_info(&clock)
    func ticks(_ seconds: Double) -> UInt64 { UInt64(seconds * 1e9 * Double(clock.denom) / Double(clock.numer)) }
    func submitGapWindow(_ frames: Int) {
      gapMeta.last_host_time = mach_absolute_time()
      gapValues.withUnsafeBufferPointer { values in
        var planes: [UnsafePointer<Float>?] = [values.baseAddress]
        planes.withUnsafeMutableBufferPointer { pointers in ogv_record(gapStorage, pointers.baseAddress, pointers.baseAddress, UInt32(frames), &gapMeta, 0, 0) }
      }
      gapMeta.first_frame += UInt64(frames)
    }
    submitGapWindow(n)
    Thread.sleep(forTimeInterval: 0.06)
    guard case .live(let complete) = gapCapture!.snapshot(epoch: 71) else { print("FAIL S-01 initial complete window"); exit(1) }
    for reason in [UInt32(1), 2] {
      ogv_gap(gapStorage, reason)
      if case .live(let held) = gapCapture!.snapshot(epoch: 71, now: complete.hostTime + ticks(0.20)) {
        expect(held.sequence == complete.sequence && held.hostTime == complete.hostTime &&
          held.beforeWave.map(\.low) == complete.beforeWave.map(\.low) && held.afterWave.map(\.high) == complete.afterWave.map(\.high), "fresh complete sequence/data/age must survive event")
      } else { print("FAIL S-01 fresh prior complete frame lost after gap/invalid"); exit(1) }
      expect({ if case .unavailable(.stale) = gapCapture!.snapshot(epoch: 71, now: complete.hostTime + ticks(0.251)) { return true }; return false }(), "original collection+251ms must be stale")
    }
    submitGapWindow(n)
    Thread.sleep(forTimeInterval: 0.06)
    guard case .live(let recovered) = gapCapture!.snapshot(epoch: 71) else { print("FAIL S-01 recovery"); exit(1) }
    expect(recovered.sequence > complete.sequence, "later complete window must advance sequence")
    gapMeta.topology = 2
    submitGapWindow(n/2)
    expect({ if case .unavailable(.warming) = gapCapture!.snapshot(epoch: 71, now: recovered.hostTime + ticks(0.20)) { return true }; return false }(), "reason3 topology must not replay old live")
    expect({ if case .unavailable(.stale) = gapCapture!.snapshot(epoch: 71, now: recovered.hostTime + ticks(0.251)) { return true }; return false }(), "reason3 retains stale boundary")
    ogv_gap(gapStorage, 1)
    expect({ if case .live = gapCapture!.snapshot(epoch: 71, now: recovered.hostTime + ticks(0.20)) { return false }; return true }(), "reason3 topology followed by gap1 must not replay old topology")
    submitGapWindow(n)
    Thread.sleep(forTimeInterval: 0.06)
    expect({ if case .live(let frame) = gapCapture!.snapshot(epoch: 71) { return frame.topology == 2 }; return false }(), "new topology recovers only with completed window")
    for field in 0..<3 {
      for reason in [UInt32(1), 2] {
        guard case .live(let baseline) = gapCapture!.snapshot(epoch: 71) else { print("FAIL identity baseline"); exit(1) }
        let generation = ogv_identity_generation(gapStorage)
        switch field { case 0: gapMeta.topology += 1; case 1: gapMeta.source += 1; default: gapMeta.format += 1 }
        submitGapWindow(n/2)
        ogv_gap(gapStorage, reason)
        let changed = ogv_identity_generation(gapStorage)
        expect(changed > generation, "identity change must persist independently of reason")
        expect({ if case .live = gapCapture!.snapshot(epoch: 71, now: baseline.hostTime + ticks(0.20)) { return false }; return true }(), "topology/source/format then gap/invalid must refuse old generation")
        gapCapture!.setDemand(VisualizationRequest(epoch: 71, assignment: id, mode: .spectrum))
        Thread.sleep(forTimeInterval: 0.06)
        expect({ if case .live = gapCapture!.snapshot(epoch: 71) { return false }; return true }(), "retained scratch mode analysis cannot republish old generation")
        switch field { case 0: gapMeta.topology -= 1; case 1: gapMeta.source -= 1; default: gapMeta.format -= 1 }
        submitGapWindow(n/2)
        ogv_gap(gapStorage, reason)
        expect(ogv_identity_generation(gapStorage) > changed, "A-B-A without a completed read must not reuse generation")
        expect({ if case .live = gapCapture!.snapshot(epoch: 71) { return false }; return true }(), "return to A plus gap cannot resurrect original A")
        submitGapWindow(n)
        Thread.sleep(forTimeInterval: 0.06)
        expect({ if case .live(let frame) = gapCapture!.snapshot(epoch: 71) { return frame.mode == .spectrum && frame.sequence > baseline.sequence && frame.sourceEpoch == 1 && frame.formatEpoch == 1 }; return false }(), "new matching generation recovers after A-B-A")
        gapCapture!.setDemand(VisualizationRequest(epoch: 71, assignment: id, mode: .waveform))
        Thread.sleep(forTimeInterval: 0.06)
      }
    }
    print("PASS persistent identity topology/source/format then gap1/invalid2,retained-mode refusal,A-B-A no intermediate read,new-generation recovery")
    gapCapture!.setDemand(nil)
    expect({ if case .unavailable = gapCapture!.snapshot(epoch: 71) { return true }; return false }(), "closed demand must refuse")
    gapCapture!.setDemand(VisualizationRequest(epoch: 72, assignment: id, mode: .waveform))
    ogv_gap(gapStorage, 1)
    expect({ if case .unavailable(.warming) = gapCapture!.snapshot(epoch: 72) { return true }; return false }(), "startup gap must be Warming")
    expect({ if case .unavailable(.warming) = gapCapture!.snapshot(epoch: 72, now: mach_absolute_time() + ticks(0.251)) { return false }; return true }(), "startup Warming deadline must not renew")
    gapCapture!.setDemand(nil)
    gapCapture = nil
    Thread.sleep(forTimeInterval: 0.03)
    print("PASS S-01 gap1/invalid2 retain complete sequence/data/original age;251ms stale;newer-window recovery;startup Warming;reason3 topology/request/close and existing expected-source refusal retained")
    print("PASS pure demand same-request/no-churn, retained-window all-mode reanalysis, fixed collection age, valid silence, stale, mode/close/reopen race, source-identity refusal/recovery and retirement")
    print("PASS \(cases) calibrated analysis cases: Fs8..192k, zeros/DC/tone/antiphase/real-output-tail, known gain and absolute DFT power")
  }
}

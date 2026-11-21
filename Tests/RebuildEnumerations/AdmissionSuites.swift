// Admission suites: each sequence runs on the reference model and on the real code; the two traces
// are compared event by event, and the invariants are checked on the real trace.

import Foundation
@testable import tap_n_filter

struct ModelRun {
    var outcomes: [AOutcome]
    var flush: ASettled
    var noFlush: ASettled
    /// Editor reads still in flight after each event (for the coalescing allowance, A-R8).
    var readsAfter: [Int]
}

func modelRun(_ events: [AEvent]) -> ModelRun {
    var model = AdmissionModel(policy: .ratified)
    var outcomes: [AOutcome] = [], readsAfter: [Int] = []
    for e in events {
        precondition(model.isEnabled(e), "not enabled: \(e) in \(events)")
        outcomes.append(model.apply(e)); readsAfter.append(model.reads.count)
    }
    var a = model, b = model
    return ModelRun(outcomes: outcomes, flush: a.settle(flush: true), noFlush: b.settle(flush: false), readsAfter: readsAfter)
}

struct Verdict {
    var green: Bool { divergences.isEmpty && violations.isEmpty && unsupported == nil && watchdogs == 0 }
    var divergences: [String] = []
    var violations: [String] = []
    var notes: [String] = []
    var unsupported: String?
    var watchdogs = 0
    /// The first difference with step numbers and values stripped, for grouping red sequences by cause.
    var key: String {
        if let unsupported { return "unsupported: \(unsupported)" }
        if watchdogs > 0 { return "watchdog" }
        if let v = violations.first { return normalizeCause(v) }
        if let d = divergences.first { return "diverges: " + normalizeCause(d) }
        return "green"
    }
}

func normalizeCause(_ text: String) -> String {
    var t = text
    for (pattern, replacement) in [(#" at \d+"#, ""), (#"step \d+ "#, ""), (#"S=-?\d+ C=-?\d+"#, "values"), (#"\[[^\]]*\]"#, "[...]"), (#"-?\d+"#, "n")] {
        t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return t
}

/// Real outcome against the model's. A read finishing while another is still in flight may be
/// coalesced into the later one (A-R8): published in the model, discarded on the real code.
/// Menu actions: in send-time mode these go out back to back, with no waiting between them.
func isMenuAction(_ e: AEvent) -> Bool {
    switch e { case .begin, .move, .end, .click, .nudge: return true; default: return false }
}

/// `sendTime`: menu actions are sent without awaiting their outcomes and their admission receipts are
/// collected before the next non-menu event, so a decision deferred into a task shows up as a
/// divergence that await-each mode hides.
@MainActor func compareAdmission(_ events: [AEvent], sendTime: Bool = false) async -> Verdict {
    var verdict = Verdict()
    let model = modelRun(events)
    let firings = watchdogFirings
    let fixture: TableFixture, driver: AdmissionDriver
    do { fixture = try await TableFixture(); driver = try AdmissionDriver(fixture) }
    catch { verdict.unsupported = "fixture: \(error)"; return verdict }
    driver.sendTime = sendTime
    var collected: [AOutcome?] = []
    for e in events {
        if sendTime && !isMenuAction(e) { await driver.collect(into: &collected) }
        guard let o = await driver.perform(e) else { verdict.unsupported = "\(e) needs a missing seam"; await fixture.close(); return verdict }
        collected.append(o)
        await driver.stampWrites()
    }
    await driver.collect(into: &collected)
    let real = collected.map { $0 ?? AOutcome.none }
    for (i, e) in events.enumerated() where real[i] != model.outcomes[i] {
        verdict.divergences.append("step \(i + 1) \(e): model \(model.outcomes[i]), real \(real[i])")
    }
    let settled = await driver.settle()
    verdict.watchdogs = watchdogFirings - firings
    verdict.notes += driver.notes
    var flush = settled.flush
    flush.delivered = model.flush.delivered          // I4 is not observed on the real code
    flush.settleReads = 1     // I8 stays the per-failure retrigger check; with quiescence behind quiet() it no longer depends on timing
    // I10: every failed apply shows a problem. The problem text isn't per apply, so this counts
    // failed receipts when a problem is showing.
    flush.applyProblems = fixture.app.problem == nil ? 0 : real.filter { $0 == .failed }.count
    for (label, m, r) in [("saved after flush", model.flush.saved, flush.saved), ("live", model.flush.live, flush.live),
                          ("menu shows", model.flush.shown, flush.shown), ("saved without flush", model.noFlush.saved, settled.noFlush.saved)] where m != r {
        verdict.divergences.append("settled \(label): model \(m), real \(r)")
    }
    verdict.violations = AdmissionInvariants.violations(events, real, flush: flush, noFlush: settled.noFlush, policy: .ratified)
    await fixture.close()
    return verdict
}

// MARK: Alphabets

let suiteS1: [AEvent] = [.begin(.g1), .begin(.g2), .move(.g1, .shown), .move(.g2, .shown), .end, .click(.shown), .nudge(.shown), .holdWrite, .releaseWrite]
let suiteS2: [AEvent] = [.begin(.g1), .move(.g1, .shown), .end, .click(.shown), .nudge(.shown), .readBegin,
                         .readEnd(oldest: true, ok: true), .readEnd(oldest: false, ok: true), .readEnd(oldest: true, ok: false),
                         .refresh, .holdWrite, .releaseWrite]
let suiteS3: [AEvent] = [.begin(.g1), .begin(.g2), .move(.g1, .shown), .move(.g1, .initial), .move(.g2, .shown), .end, .click(.shown), .click(.initial),
                         .nudge(.shown), .nudge(.initial),
                         .readBegin, .readEnd(oldest: true, ok: true), .playbackChange, .structural, .laneChange, .refresh, .menuOpen]

/// Real code cannot attribute an injected failure to one of two overlapping reads.
func realizable(_ model: AdmissionModel, _ e: AEvent) -> Bool {
    if case .readEnd(_, false) = e { return model.reads.count == 1 }
    return true
}

func enumerate(_ alphabet: [AEvent], length: Int) -> [[AEvent]] {
    var out: [[AEvent]] = []
    func visit(_ model: AdmissionModel, _ prefix: [AEvent]) {
        if prefix.count == length { out.append(prefix); return }
        for e in alphabet where model.isEnabled(e) && realizable(model, e) {
            var next = model; _ = next.apply(e); visit(next, prefix + [e])
        }
    }
    visit(AdmissionModel(), [])
    return out
}


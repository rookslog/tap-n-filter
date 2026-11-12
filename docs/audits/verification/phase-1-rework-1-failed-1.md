# Phase 1 Rework 1 Verification

Public-copy privacy edit: `LOCAL_SIGNING_IDENTITY` and angle-bracket values below
replace local identity, certificate or path metadata. Redacted command excerpts
are historical records, not literal output from the current scripts.

**Verifier**: Claude (verification subagent, cold context)
**Date**: 2026-05-27
**Phase**: 1 (rework 1) — Audio Capture Architecture Refactor
**Verdict**: FAIL

## Gate criteria assessment

### Criterion 1: ADR-018 exists and is Accepted

**Status**: Met

**Evidence**: `docs/decisions/ADR-018-direct-ioproc-capture-architecture.md`
exists. Line 5 reads: "Accepted (2026-05-27). Supersedes the AVAudioEngine.
inputNode binding pattern introduced in Phase 1 (ADR-001 +
`docs/specs/capture.md`)." Status banner matches the required form.

---

### Criterion 2: `capture-v2.md` exists and is referenced from ADR-018 and from this phase spec

**Status**: Met

**Evidence**: `docs/specs/capture-v2.md` is present (365 lines). ADR-018
line 180 references it ("`docs/specs/capture-v2.md` — the technical
specification of the new architecture"). Phase spec
`01-capture-spike-rework-1.md` references it 17+ times including in the
Gate criteria and Outputs sections.

---

### Criterion 3: `capture.md` is marked superseded

**Status**: Met

**Evidence**: `docs/specs/capture.md` lines 3-16 carry a blockquote
banner: "**Status: superseded for V0.1 by [`capture-v2.md`](capture-v2.md).**"
The banner names ADR-018 and points readers to `capture-v2.md` for new
work. Old V1 prose is retained below as historical context per spec
intent.

---

### Criterion 4: `AudioRingBuffer` exists; all T1.* tests pass

**Status**: Not met

**Evidence**: `Sources/Capture/AudioRingBuffer.swift` exists (130 lines)
and implements the public surface from `capture-v2.md` § AudioRingBuffer
(channelCount, capacity, init, write, read, fillCount). The semantic
shape of the code looks correct: per-channel storage, head/tail/fill
state under `OSAllocatedUnfairLock`, wrap handling via two-chunk copies,
zero-frame no-ops. The T1.1–T1.8 tests are present at
`Tests/CaptureTests/AudioRingBufferTests.swift` (348 lines) and address
all eight TDD anchors literally.

**Gap**: CI run #26543700798 on commit `707ded5` fails to compile
`Tests/CaptureTests/AudioRingBufferTests.swift` under
Xcode 16.2 / Swift 5.10 (the toolchain the repo declares against). Three
sites use `UnsafeMutablePointer<Float>.initialize(repeating: -1)` without
the required `count:` parameter — line 29 (helper), line 226 and 227 (T1.6
fixture). Same fault exists in `TapIOProcReaderTests.swift` lines 172, 173.
Because the CaptureTests target fails to emit-module, none of the T1.* tests
ever execute on CI; the assertion that they pass is unsupported by evidence.
(Locally with Swift 6.2.3 the single-element form parses, masking the bug
in the orchestrator's environment.)

---

### Criterion 5: `TapIOProcReader` exists with the EXP-026 aggregate dictionary; all T2.* tests pass

**Status**: Partially met (code Met, tests Not met)

**Evidence**: `Sources/Capture/TapIOProcReader.swift` exists. The
aggregate-creation dictionary at lines 136-143 includes
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0`, and does NOT contain
`kAudioAggregateDeviceTapListKey` or
`kAudioAggregateDeviceTapAutoStartKey`. The tap list is set after
creation via a separate `coreAudio.setAggregateTapList(aggregate,
tapUIDs: [uid] as CFArray)` call (line 156). `RealCoreAudioInterface.set
AggregateTapList` (CoreAudioInterface.swift lines 257-282) issues an
`AudioObjectSetPropertyData` write with the address selector
`kAudioAggregateDevicePropertyTapList`; the payload is the
`CFArray<CFString>` the caller built. This matches the spec form
byte-for-byte. The IOProc registration uses a file-scope
`@convention(c)` function (`tapIOProcReaderIOProc`, lines 275-284) that
recovers the reader via `Unmanaged.fromOpaque`. The push path
(`pushIOProcSamples`, lines 217-264) is non-allocating in the hot path
(stack-temporary scratch via `withUnsafeTemporaryAllocation`).

**Gap**: T2.* tests at `Tests/CaptureTests/TapIOProcReaderTests.swift`
do not compile on CI (Xcode 16.2 / Swift 5.10) — the
`UnsafeMutablePointer.initialize(repeating:)` fault propagates here too
(lines 172, 173), and the `FakeCoreAudioInterface.createIOProcIDResult`
default closure uses a `[self]` capture (line 92) in a property
initializer where `self` is not yet in scope, raising the additional
compile error "cannot find 'self' in scope". The criterion's "all T2.*
tests pass" subordinate clause is consequently Not met.

The code-inspection portion of the criterion (dictionary shape, post-set
tap list) is fully Met.

---

### Criterion 6: `CaptureController.start` does not call `setProperty` on any AU; `configureEngineInput`, `resetEngineInput`, `pinEngineOutputToDefault` deleted

**Status**: Met

**Evidence**: `Sources/Capture/CaptureController.swift` (308 lines) has
no reference to `setProperty`, `kAudioOutputUnitProperty_CurrentDevice`,
`configureEngineInput`, `resetEngineInput`, or `pinEngineOutputToDefault`.
The start path (lines 112-199) is: resolve audioProcessID → construct
`TapIOProcReader` → build `AVAudioSourceNode(format: reader.format)` →
`engine.attach(sourceNode)` → `reader.start()` → publish state. No AU
property is touched directly. `Sources/Capture/CoreAudioInterface.swift`
(407 lines) similarly contains none of the deleted method names; a
recursive grep across `Sources/` returns no matches. Both
`CoreAudioInterface` (the protocol) and `RealCoreAudioInterface` (the
class) exclude them.

T3.* tests at `Tests/CaptureTests/CaptureControllerTests.swift` lines
65-188 cover the start/stop/restart/idempotent state machine and the
structural assertion that the protocol surface no longer exposes
`configureEngineInput` (test
`test_protocol_no_longer_exposes_engine_audio_unit_setters`). The tests
themselves do not compile on CI per criterion 4/5 — but the structural
deletion is verifiable by grep regardless. The grep evidence supports
Met for the literal text of this criterion.

---

### Criterion 7: `AppViewModel` no longer contains the forbidden symbols

**Status**: Met

**Evidence**: Grep against `Sources/ViewModel/AppViewModel.swift` for the
13 forbidden identifiers returns no matches:
`waitForValidOutputHardwareFormat`, `attemptReattach`,
`logOutputAudioUnitState`, `logInputAndOutputAUIdentity`,
`rebindOutputToSystemDefault`, `fourCCString`, `runMixerTap`,
`performMixerTap`, `MixerTapCollector`, `runHFPSpike`, `stopHFPSpike`,
`runAudioteeTest`, `isAudioteeTestRunning`. The `AVAudioEngine
ConfigurationChange` observer (lines 198-209) is logging-only as the
spec intends. The `powerOn` path (lines 285-378) is a straight-through
resolve → start → attach → prepare → start sequence with no poll loop.
T4.* test fixtures exist at `Tests/ViewModelTests/AppViewModelTests.swift`
lines 235-355 but, as with criteria 4-6, run on a toolchain that may
fail (the ViewModelTests target depends on Capture, which the failing
CaptureTests doesn't break — but the integration via MockCaptureController
is exercised on CI only after CaptureTests compiles).

---

### Criterion 8: Throwaway diagnostic files deleted; DebugPanel rows removed

**Status**: Met

**Evidence**: `git ls-files | grep -E 'HFPSpike|AudioteePatternTest'`
returns nothing. The `Sources/ViewModel/HFPSpike.swift` and
`Sources/ViewModel/AudioteePatternTest.swift` files referenced in
`git status` show as untracked (the `??` status in the session's git
snapshot), but they are not in tracked source. `Sources/UI/DebugPanel.swift`
(165 lines) contains no `hfpSpikeRow`, `audioteeTestRow`, or `mixerTapRow`
identifier. The panel body (lines 19-30) is now just header + entries.

---

### Criterion 9: Integration test artifact exists (or accepted-deviation documented)

**Status**: Met (as accepted-deviation)

**Evidence**: `Tests/CaptureIntegrationTests/RealTapIntegrationTests.swift`
(262 lines) implements TI.1 and TI.2 gated behind `RUN_INTEGRATION_TESTS=1`,
includes the wav-emission code path (`writePassthroughWAV`), and writes
to `test-artifacts/phase-1-rework-1-passthrough.wav`. The test path is
intact and compiles (it isn't in the broken set; verified by
`Tests/CaptureIntegrationTests/` directory contents).

No wav artifact at `test-artifacts/phase-1-rework-1-passthrough.wav` and
no run transcript at `docs/audits/verification/phase-1-rework-1-pass
through.md` exist on disk. This matches the accepted-deviation pattern
documented for Phase 1's original gate criterion 2 (`state.json`
`human_inputs.other_escalations` entry id
`phase-1-passthrough-test-needs-interactive`). The orchestrator's
autonomous run cannot click "Allow" on the TCC dialog. Criterion 9
allows this fallback explicitly ("Same accepted-deviation pattern as
Phase 1's original gate criterion 2 if the live-render step cannot be
run autonomously: documented deviation with the code path in place").

---

### Criterion 10: All unit tests pass (`swift test --skip-integration` returns 0)

**Status**: Not met

**Evidence**: CI run #26543700798 (https://github.com/loganrooks/tap-n-filter/
actions/runs/26543700798) on commit `707ded5` reports the `Build and test`
job as failed. Compilation of the `CaptureTests` target fails with at
least six distinct errors:

- `Tests/CaptureTests/FakeCoreAudioInterface.swift:92:10` — `[self]`
  capture in a property-default closure: "cannot find 'self' in scope".
- `Tests/CaptureTests/AudioRingBufferTests.swift:29`, `:226`, `:227` —
  `UnsafeMutablePointer<Float>.initialize(repeating: -1)`: "missing
  argument for parameter 'count' in call".
- `Tests/CaptureTests/TapIOProcReaderTests.swift:172`, `:173` — same
  signature fault as above.

Because `swift test` cannot run, all the T1.*, T2.*, T3.* assertions
cited in criteria 4-6 as "tests pass" remain unverified. The orchestrator's
local environment is Command Line Tools only (XCTest unavailable) so this
report cannot reproduce the test run locally; the CI failure log is the
authoritative signal and it is unambiguous.

**Gap**: Two distinct compile failures (one in test-fixture code, one in
test-method code) prevent the CaptureTests target from emitting its
module. The verification protocol forbids inferring compliance from
absence of contradicting evidence — and here there *is* contradicting
evidence on CI.

---

### Criterion 11: The app builds clean (`./Build/bundle-dev.sh` returns 0 and produces a signed `Build/tap-n-filter.app`)

**Status**: Met

**Evidence**: Local run of `./Build/bundle-dev.sh` at HEAD returns exit
code 0. `swift build -c debug` completes ("Build complete! (1.45s)").
The script signs with the redacted local identity ("==> Signing with
identity 'LOCAL_SIGNING_IDENTITY'… replacing existing signature") and produces
`Build/tap-n-filter.app/Contents/MacOS/tap-n-filter` plus copied
`Info.plist` and SPM resource bundles.

This criterion is independent of the test failure (criterion 10) because
`swift build` only compiles the library + executable targets, not the
test targets.

---

### Criterion 12: Existing Phase 2 / Phase 3 tests still pass

**Status**: Not met

**Evidence**: For the same reason as criterion 10 (`CaptureTests`
target's `emit-module` fails on CI), the `swift test` run never reaches
the Phase 2 (EffectsTests, GraphTests, PresetsTests) or Phase 3
(UISnapshotTests, AccessibilityTreeTests) targets. The CI log shows
EffectsTests/EffectStateTests reached the compile phase (line "[35/57]
Compiling EffectsTests EffectStateTests.swift") and AccessibilityTree
Tests reached emit-module — but the package-level test build is gated
by every target compiling; CaptureTests failing prevents `swift test`
from running any test, including the Phase 2/3 suites.

If the underlying test-compile errors were fixed, the EffectsTests/
GraphTests/PresetsTests/UISnapshotTests/AccessibilityTreeTests changes
in this PR look minimal-to-none (the diff stat shows no edits to those
test files). I'd expect them to pass once the build is unblocked, but
that's behavior-inferred and the criterion as written ("Existing tests
still pass") requires the actual run.

---

### Criterion 13: CodeRabbit and Codex have reviewed the PR; high-severity findings addressed

**Status**: Not met (still pending; not Unable-to-evaluate)

**Evidence**: `gh pr view 9 --json reviews` returns `"reviews":[]`.
`gh api repos/loganrooks/tap-n-filter/pulls/9/comments` returns `[]`.
The PR has two top-level comments:

1. `@codex review` by the maintainer (createdAt 2026-05-27T22:58:12Z).
2. A CodeRabbit auto-comment dated 2026-05-27T22:58:27Z stating
   "Currently processing new changes in this PR. This may take a few
   minutes, please wait..."

CodeRabbit has not yet posted its review; the `reviews` array is empty.
Codex's review (triggered by the `@codex review` comment) likewise has
not landed yet — no inline comments, no review submission, no top-level
follow-up by `chatgpt-codex-connector`.

The criterion language is "CodeRabbit and Codex have reviewed the PR".
At the time of this report, neither has produced a review. This is
distinguishable from "Unable to evaluate" because the absence of reviews
IS the evidence: the criterion has a definite answer, and that answer is
"no, they haven't reviewed yet". The PR is too young to have collected
the required review signal.

This is the same pattern as the previously-documented deviation
`github-apps-not-installed` in `state.json` `human_inputs.other_
escalations` — but that escalation only applies to the historical Phase
0 environment; the apps are now installed (CodeRabbit's auto-acknowledge
comment proves it). The mitigation here is to wait for the reviews to
arrive before re-running verification. The criterion is genuinely
unmet at the verification timestamp.

---

### Criterion 14: `state.json` has Phase 1 status `passed`; Phase 4 `blocked_on` null

**Status**: Met — pending orchestrator's post-PASS state.json transition

**Evidence**: Current `state.json` reads phase 1 `status: "in_progress"`
with `pending_verification_report: "../audits/verification/phase-1-rework-1.md"`
and `rework_pr_url: "https://github.com/loganrooks/tap-n-filter/pull/9"`.
Phase 4 `blocked_on` is still populated with the rework rationale.
This is the expected pre-PASS state per the verification protocol — the
orchestrator only flips phase 1 to `passed` and clears phase 4
`blocked_on` after this report returns PASS.

If everything else were Met, this criterion would resolve to Met on the
orchestrator's subsequent commit. Per the protocol's intent it does not
block the verdict. But because criteria 10, 12, and 13 are Not met,
that subsequent commit will not happen on this verification run, and
this criterion remains in the "pending" form.

---

## Framing audit-lite

**Question**: Did this phase's implementation introduce reasoning or
assumptions that weren't in the spec? If so, were those additions sound?

**Answer**:

The phase spec is unusually precise — the dictionary shape, the public
surface of `TapIOProcReader` and `AudioRingBuffer`, the deletion list for
`AppViewModel`, the eight T1 anchors, the eight T2 anchors, the six T3
anchors, the five T4 anchors — and the implementation is correspondingly
literal. The aggregate dictionary at `TapIOProcReader.start` lines 136-143
is a transcription of `capture-v2.md` lines 267-275 with the source-app
display name interpolated. The `setAggregateTapList` payload is the
spec's "ONE-element array of CFString" exactly. The render-from-ring
helper at `CaptureController.renderFromRing` lines 271-306 is the
canonical AVAudioSourceNode pattern with explicit underrun handling per
ADR-018's "underrun = SourceNode emits silence, engine keeps running"
consequence. No load-bearing design decisions hide inside the diff that
aren't in the bundle.

Two ancillary additions slipped in alongside the rework that aren't in
the spec: a `quitButton` in `Sources/UI/FooterView.swift` and a
`FileLogSink` in `Sources/ViewModel/DebugLogStore.swift` (with the
related Open-log-file / Copy-log-file buttons in `DebugPanel`'s header).
The quit button's commit message and inline comment cite "user feedback
(2026-05-22): 'having an exit button' was a Day-One ask"; the file log
sink is rationalised in its own header as the orchestrator's diagnostic
read-path. Both are minor polish items that would have been Phase 4's
turf, not Phase 1 rework's. They aren't unsound — they don't add any
audio-stack assumption — and they don't expand the blast radius of the
diff because both live in UI / ViewModel auxiliary surfaces. I flag
them because they bend the spec's stated In/Out scope; a strict reading
would push them out. A lenient reading treats them as harmless
piggybacks. I lean lenient on this one because reverting them on a Phase
4-blocker rework PR has higher cost than letting them ride.

The pre-existing investigation log (`docs/investigations/2026-05-audio-
pipeline.md`, EXP-026 + FC-003) is the empirical ground the rework rests
on. EXP-026's 471 IOProc fires in 5s and 99.5% non-zero samples are the
audit-grade evidence that the chosen aggregate-creation dictionary
works; FC-003's frame-shift to "architectural rewrite required" is the
falsificationist commitment to abandoning the V1 architecture rather
than patching it. Both are referenced in ADR-018 and the phase spec.
This is a model of how the investigation-then-decision pipeline is
supposed to work.

## Verdict reasoning

The architectural work — ADR-018, capture-v2.md, the supersession banner
on capture.md, the `AudioRingBuffer`, the `TapIOProcReader` with the
EXP-026-validated aggregate dictionary, the simplified `CaptureController`
that doesn't touch the engine's input AU, the simplified `AppViewModel`
without the wait loop and recovery branches, the deletion of HFPSpike /
AudioteePatternTest / MixerTapCollector — is in place. Code-inspection
gates (criteria 1, 2, 3, 6, 7, 8, 11, 14) are Met. The integration test
code path exists with the accepted-deviation for the wav artifact
(criterion 9).

But the test-build is broken on CI. Criterion 10 ("all unit tests pass")
fails because two distinct toolchain incompatibilities prevent the
CaptureTests target from compiling under Xcode 16.2 / Swift 5.10:
`UnsafeMutablePointer.initialize(repeating:)` requires `count:` in that
toolchain (3 sites in AudioRingBufferTests, 2 in TapIOProcReaderTests),
and `[self]` in a property-initialiser closure is not valid Swift
(`FakeCoreAudioInterface.swift:92`). Criterion 12 ("existing Phase 2/3
tests still pass") fails by knock-on effect — `swift test` never reaches
those targets because CaptureTests blocks the build.

Criterion 13 ("CodeRabbit and Codex have reviewed") is also unmet at
the verification timestamp. CodeRabbit's review is in progress (per
its auto-acknowledge comment); Codex was just pinged. Neither has
posted a review yet. The PR is 5 minutes old as of CI failure. This
criterion will likely resolve on its own with time.

Three Not-met criteria, one of them (criterion 13) likely to clear with
time, and two (criteria 10 + 12) requiring an orchestrator fix to the
test code. The fixes are small — change `pointer.initialize(repeating:
v)` to `pointer.initialize(repeating: v, count: N)` at the six sites,
and replace the `[self]` capture with a lazy var or a method that
constructs the default. But "small" doesn't mean "not required". The
verification protocol's strict-mode language is that the verifier marks
each criterion Met / Not met based on observable evidence; for the test
runs, the observable evidence is the CI fail. PASS would mean asserting
those tests run green, which I cannot from the available data.

**Verdict**: FAIL

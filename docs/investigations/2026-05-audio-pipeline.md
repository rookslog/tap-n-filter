# 2026-05 Audio Pipeline Investigation

Public-copy privacy edit: `LOCAL_SIGNING_IDENTITY` and angle-bracket values below
replace local identity, certificate or path metadata. Redacted command excerpts
are historical records, not literal output from the current scripts.

## Status

**Last updated**: 2026-05-29 (post-EXP-036; H15/HFP mitigation found —
an app-side default-input-device switch keeps Bluetooth on A2DP. Bug A
and Bug B remain RESOLVED. The HFP item moves from "intrinsic limitation"
to "mitigation decided (ADR-019), automation pending in the settings
branch (EXP-037)".)

**Current frame**: The two bugs were one. **Bug B** (capture
corruption: pitched-down / crackle / left-shift) was caused by an
interleaved-vs-planar channel-layout mismatch at the IOProc boundary,
fixed by de-interleaving (EXP-034), confirmed on speakers. **Bug A**
(BT-only reverb-bypass cutout) turned out to be the same root cause —
EXP-035 showed the cutout is gone on BT after the de-interleave fix, so
Bug A was coupled to Bug B, not a separate reverb/HFP mechanism. The
long search for a reverb-specific cause was chasing a downstream symptom
of the interleaving bug. The earlier rate-mismatch (EXP-033) was real
but not load-bearing (FC-005). The one remaining capture-quality issue
is **H15 / HFP degradation**: on a BT output, active capture forces the
system into HFP 16 kHz mono, so effects are audible but quiet/narrow.
That is the next item. See FC-005 and
`docs/governance/debugging-protocol.md` for the methodology this episode
produced.

- **Bug A (H16): RESOLVED, coupled to Bug B.** EXP-035 — the BT
  reverb-bypass cutout disappeared after the EXP-034 de-interleave fix.
  It was an artifact of the Bug B frame-count error, not a
  reverb-specific or BT/HFP-specific mechanism. The many refuted Bug A
  sub-hypotheses (graph mutation, configChange race, parallel mixer,
  AU bypass, chain position, fan-out topology) were all correct
  refutations; the real cause sat at the IOProc boundary, a layer the
  Bug A hypothesis space never reached. Reinforces the FC-004 lesson:
  test the lowest-layer correctness baseline first.

- **Bug B (H17, now split)**: the persistent "pitched-down /
  voice-changer + crackle + left-shift" degradation on every capture.
  - **H17a (rate mismatch)**: real but **not load-bearing**. EXP-032
    source-grounded that the chain ran at 44.1 kHz while the tap is
    48 kHz; EXP-033 pinned the chain to 48 kHz (fix landed,
    `[EXP-032.format.source] rate=48000.0`) and the artifact did not
    move. Confirming the mismatch obtained was mistaken for confirming
    it as the cause (FC-005). Rate fix kept; it is correct but not the
    cure.
  - **H17b (channel-layout mismatch) — current dominant hypothesis**:
    the tap delivers *interleaved* stereo (`formatFlags=9`,
    `bytesPerFrame=8`) but the ring/render pipeline is *planar*. The
    IOProc wrote the interleaved buffer as one planar channel at 2× the
    real frame count → octave-down + left-shift + crackle, all four
    symptoms from one mechanism. Fixed by de-interleaving at the IOProc
    boundary (EXP-034); **confirmed load-bearing** by the user's
    speaker-route verdict — all four symptoms resolved together. The
    interleaving evidence was in the `[EXP-029.tap.format]` log from the
    first instrumented run and went undecoded until the rate fix failed.

**Previous active hypotheses, current status**:
- **H13 (leaked HAL state)** → moved to **Inactive — REFUTED by
  EXP-030** (force-kill protocol; no orphans visible to new
  instance; cleanup found nothing; AudioDeviceStart still returned
  0). EXP-027 / EXP-028 mechanism remains unexplained but inert
  (no recurrence across EXP-029 + EXP-030 + EXP-031 — 6+
  successful Starts).
- **H15 (HFP forced by capture on BT)** → **refined by EXP-036**,
  source-grounded. The trigger is gated on the BT device being the
  system default *input* while capturing; forcing default input to the
  built-in mic keeps the output on A2DP (`outputOut 44100×2` vs
  `16000×1`). An app-side mitigation exists (default-input switch);
  disposition in ADR-019, automation in EXP-037. Still confirmed by the
  speaker test (no HFP when BT disconnected).
- **H16 (bypass toggle cuts audio)** → renamed Bug A; refined to
  BT-only.

**Operational state**:
- Committed: `47cee0c` (capture fixes + notebook), `9c0ae2c`
  (debugging-protocol formalization), on branch
  `investigation/exp-029-observability`. Builds clean. Bug A + Bug B
  resolved and verified on their respective routes.
- The proposed ReverbNode refactor (native `reverb.wetDryMix` +
  `reverb.bypass`) is **abandoned** — Bug A is resolved without it, and
  B1 already showed the parallel mixer was never the cause.
- **H15 / HFP degradation on BT has a found mitigation (EXP-036).** The
  app-side workaround spike paid off: switching the system default
  *input* away from the BT device during capture keeps the output on
  A2DP. ADR-019 records the disposition (default-on "Preserve Bluetooth
  quality" toggle); EXP-037 will pre-register and implement the
  automation on the settings branch. The HAL-plugin virtual device is
  deferred to V0.2 as robustness, not a V0.1 prerequisite. (`defaults
  write Disable HFP` remains a dead end on macOS 26.3.)
- Smaller follow-ups before closing the investigation: add an
  interleaved-input regression test to `TapIOProcReaderTests`; consider
  an ADR for the capture format contract (chain at tap rate +
  de-interleave at the IOProc boundary).

**Earlier frames (now revised)**:
- Post-EXP-029, pre-EXP-030: H13 was the leading hypothesis for
  the EXP-027 / EXP-028 deterministic failures. **Refuted by
  EXP-030.**
- Post-EXP-031 runs 1-3, pre-B1: "AVAudioUnitReverb in parallel
  fan-out triggers a pruning optimization at wet_dest=0" was the
  leading mechanism for the cutout. **Refuted by EXP-B1**
  (standalone repro showed all parallel-fan-out configurations
  produce audible dry signal in isolation).
- Pre-speaker test: "reverb bypass cuts on all routes" was the
  assumption. **Refuted**: on speakers it does not cut.
- Pre-speaker test: We treated user-reported "audio sounds
  degraded during capture" as HFP-only artifact. The speaker
  test exposed a separate corruption (Bug B / H17) that was
  always present but masked.

**Earlier frames (now revised)**:
- post-EXP-028, the frame was "deterministic regression in the
  refactor; AudioDeviceStart-on-aggregate is broken when called
  through CaptureController." EXP-029 refuted this: the same code
  path passes when the HAL is clean. The bug is state-dependent,
  not deterministic.
- post-EXP-026 / pre-EXP-027, the frame was "architecture
  validated; live test will close the investigation." EXP-027
  refuted that. The architecture is correct but exposes a new
  HAL-state-leakage mode under failure.

**Earlier frame (still valid)**:

**Current frame**: AVAudioEngine + process tap + aggregate device
(current production architecture) is structurally incompatible with
macOS 26.3's unified IO AU (FC-003). **However**, the direct-IOProc-
on-tap-aggregate architecture Codex recommended *works* inside our
app (EXP-026, just confirmed): 471 IOProc fires in 5 s, 99.5%
non-zero samples, peak amplitude 0.73 — real, loud Safari audio
captured byte-for-byte by our app's IOProc. The missing-keys bug
that broke HFPSpike (H3) is **resolved**: the aggregate must include
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0` at creation, with the
tap list set AFTER creation as `CFArray<CFString>`. Path forward:
**production refactor to the validated pattern**. Template lives in
`Sources/ViewModel/AudioteePatternTest.swift` lines 159-211. Pending
ADR-XXX for the architectural decision record.

**Previous frame** (kept for posterity):

**Latest understanding**: H1 and H4 are fixed. Production capture
reaches sustained `running` state with no errors. **But EXP-021 just
exposed a deeper bug than H2 (HFP) that we had not previously
characterized correctly**: the user hears literal silence during
capture, not HFP-degraded audio. Source process is muted (ADR-014
working as intended); engine processes correctly (slider/parameter
push-through logged); but **no engine output reaches the user**.
Promoting this to **H7**: the unified IO AU on macOS 26.3 has its
CurrentDevice pointed at the tap aggregate (a no-output device), so
engine-output frames are silently discarded. EXP-024 (mainMixerNode
tap dumping to WAV) is the disambiguator.

Earlier notes on H2 / HFP-as-cosmetic-bug were partly misled by the
user appearing to hear "HFP-degraded effects" — in retrospect, what
they were hearing in the first round of EXP-013/14 was the **source
process leaking audio during the brief HFP route-switch window**, not
the engine output. Now that source mute reliably engages, the
underlying no-output condition is exposed.

**Earlier reframings (still valid)**:

1. **Audiotee's "all-zero samples" we observed in EXP-007/008/009 is
   likely a documented macOS 26 Apple bug**, not TCC silencing. Apple
   Developer Forums thread 825780 records `AudioHardwareCreateProcess-
   Tap` intermittently delivering all-zero buffers on macOS 26.5 Beta
   (and likely 26.x), unanswered by Apple, no root cause. Our TCC
   interpretation of EXP-007-009 is weakened.

2. **HFP trigger mechanism is the "input + output on same engine"
   pattern**, not voice processing specifically. Any AVAudioEngine
   configuration with active input (inputNode bound to a capture
   device) and active output looks to macOS like `playAndRecord` mode
   and flips BT to HFP. This confirms Codex's architectural diagnosis.

3. **Rogue Amoeba's Audio Hijack ships a CoreAudio HAL plugin (ARK)**
   rather than using `CATapDescription`. The professional commercial
   app in this exact space chose a different architecture because the
   lightweight tap API isn't reliable enough for production BT capture.
   Validates our pain.

**Open headline question**: with HFP disabled at the OS level (via
`sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" -bool
true`), is production audio clean and effect chain audibly responsive?
If yes, we know HFP is the only remaining issue and have empirical
ground to invest in an architectural fix. If no, there's a deeper
bug. See EXP-018 below.

**Out-of-scope sibling investigation**: the HFPSpike's IOProc never
fires. Held inactive until H2 work resumes, because the spike was
intended as a validation harness for one possible H2 fix.

## TL;DR

- **Current state (2026-05-29)** — read this first; the bullets below are
  the earlier chronological findings (H1/H2/H4 era), kept for the record.
  Bug B (capture corruption) and Bug A (BT reverb-bypass cutout) are both
  **RESOLVED**: they were one bug, an interleaved-vs-planar layout mismatch
  at the IOProc boundary (EXP-034). The remaining BT-quality issue,
  H15/HFP, now has an **app-side mitigation** (EXP-036): switching the
  system default *input* off the BT device during capture keeps the output
  on A2DP (44.1 kHz stereo) instead of HFP (16 kHz mono). Disposition in
  ADR-019; automation queued as EXP-037. See the Status block for the
  authoritative current frame.
- **H1 fixed** (EXP-013): production `capture.start` was throwing
  **-10851** on every Start because `pinEngineOutputToDefault` set
  `kAudioOutputUnitProperty_CurrentDevice` on
  `AVAudioEngine.outputNode.audioUnit`, which uses
  `kAudioUnitSubType_DefaultOutput` and refuses that property. Codex
  flagged this in the original investigation report; we left the broken
  code in until EXP-012 traced it in the live log. Removing the call
  (one-line change in `CaptureController.start`) restored
  `capture.start` to success.
- **H2 confirmed live** (EXP-013): with H1 fixed,
  `AVAudioEngineConfigurationChange` fires within ~700 ms of
  `configureEngineInput` and the BT output flips to 16 kHz × 1 ch.
  Codex's HFP diagnosis is now empirically established for our
  environment.
- **H4 surfaced** (EXP-013): the engine's reconfiguration recovery
  logic re-attaches an already-attached graph, throwing
  `Graph.GraphError.alreadyAttached`. This crashes capture back to
  idle, the controller auto-retries, and we loop. This is the next bug
  to fix; it was previously masked by the upstream -10851 crash.
- The architectural fix for H2 (direct IOProc + `AVAudioSourceNode`)
  was scaffolded as `HFPSpike` but has its own unresolved bug — the
  IOProc never fires. Held inactive (H3) until we finish the H4 fix
  and decide whether to tackle H2 via the spike's architecture or a
  different route. [EXP-002…011]
- Bluetooth is **not** the variable. Built-in speakers fail the same way;
  audiotee returns all zeros regardless of BT state. [EXP-008, EXP-009]
- Self-signed `LOCAL_SIGNING_IDENTITY` cert is **sufficient** for TCC persistence on
  macOS 26.3. CDHash is stable across same-source rebuilds; permission
  re-prompts are driven by rebuilds (binary hash drift), not by cert
  type. No paid Apple Developer Program membership needed. [EXP-010,
  EXP-011]
- `audiotee` (CLI) cannot capture real audio on this machine — the IOProc
  fires (we get bytes) but every sample is 0x00. Inheriting Terminal's
  "Screen & System Audio Recording" TCC is not enough; the macOS 14.4+
  tap path needs the granular "System Audio Recording Only" service.
  `tap-n-filter.app` has it; `audiotee` (via Terminal) does not. [EXP-007,
  EXP-008, EXP-009]

## Environment

Captured 2026-05-25 06:35 EDT. Re-verify before any reproduction attempt
and update this section if a value drifts.

### Host

- **macOS**: 26.3 (build 25D125), arm64
- **Swift**: 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)
- **Target triple**: arm64-apple-macosx26.0
- **Xcode CLT only** (no full Xcode.app)

### Project state

- **Branch**: `fix/live-app-bugs`
- **Main branch**: `main`
- **Working directory**: `<checkout>`
- **Build output**: `Build/tap-n-filter.app` (assembled by
  `Build/bundle-dev.sh`)

### Signing

- **Identity**: `LOCAL_SIGNING_IDENTITY` (self-signed; not Developer ID)
- **Cert fingerprint**: `<local certificate fingerprint>`
- **Designated requirement** (what TCC matches on):
  `identifier "com.loganrooks.tap-n-filter" and certificate leaf =
  H"<local certificate fingerprint>"`
- **Current CDHash**: `8300e352289df015fd9b3567d418b95daff102a5`
- **TeamIdentifier**: not set (consequence of self-signed)
- **Format**: app bundle with Mach-O thin (arm64), Sealed Resources v2,
  13 rules, 3 files

### Info.plist privacy keys

- `NSAudioCaptureUsageDescription`: "tap-n-filter needs permission to
  capture audio from other applications so you can route their output
  through your effect chain."
- `CFBundleIdentifier`: `com.loganrooks.tap-n-filter`
- (No `NSMicrophoneUsageDescription` — production deliberately avoids
  microphone access)

### TCC grants (user-reported, verified via System Settings)

- **`tap-n-filter.app`**: "System Audio Recording Only" — granted
- **Terminal.app**: "Screen & System Audio Recording" — granted; does
  **not** include "System Audio Recording Only"
- **Claude Desktop**: "Screen & System Audio Recording" — granted

The macOS 14.4+ split between "Screen & System Audio Recording" (combined
screen capture path) and "System Audio Recording Only" (process-tap path)
is the reason `audiotee` returns all-zero data even though its tap +
IOProc machinery works mechanically.

### Audio hardware observed during this investigation

- **Bose QuietComfort Headphones** (Bluetooth): default output device
  when connected; default input device too (mic enabled)
- **MacBook built-in speakers**: default output when BT disconnected
- **MacBook built-in microphone**: not used
- **an unrelated virtual microphone**: listed
  by `system_profiler SPAudioDataType`; ignored

### Bluetooth profile observed

- A2DP (44.1 kHz × 2 ch) when BT connected without active capture
- HFP (16 kHz × 1 ch) when BT connected and either:
  - tap-n-filter's `configureEngineInput` binds an aggregate to
    `AVAudioEngine.inputNode`, or
  - any process activates the BT mic for voice (e.g. Claude Desktop
    during a voice call)

## Hypothesis ledger

### Active

(H13 moved to Inactive — REFUTED by EXP-030's force-kill protocol.
The post-force-kill instance sees no orphan taps or aggregates in
the HAL; `AudioDeviceStart` returns 0 anyway. See H13 refutation
entry in Inactive section.)

#### H15 — Active process-tap IOProc forces BT into HFP routing (source-grounded)

**Status (2026-05-29, refined by EXP-036)**: the trigger is more specific
than first stated, and it is **manipulable from user space**. EXP-036
showed that forcing the system default *input* device to the Mac built-in
mic keeps the BT output on A2DP (44.1 kHz stereo). The HFP switch is gated
on the BT device being the default *input* while a capture session is
active — not on the tap being active per se. An app-side mitigation
therefore exists (switch default input away from BT during capture), and
the HAL-plugin path drops from "required" to "V0.2 robustness." Disposition
in ADR-019; automation pre-registered as EXP-037. The original claim below
stands as the *unmitigated* behavior; the sentence "below where any
V0.1-scope code can intervene" is the part EXP-036 corrects.

**Claim**: macOS 26.3's audio routing layer forces Bluetooth output
into HFP voice mode (16 kHz × 1 ch) whenever any process tap's
IOProc is active and the default output is a Bluetooth device. The
trigger is the active capture, NOT the AVAudioEngine wiring. The
direct-IOProc architecture (ADR-018) cannot avoid this — it's at the
OS routing layer, below where any V0.1-scope code can intervene.

**Type**: source-grounded (EXP-029 production log shows
`outputNode=44100Hz×2ch` at `engine.preattach`, then
`outputNode=16000Hz×1ch` 65 ms after `AudioDeviceStart=0`, with no
intervening engine reconfiguration on our side).

**Auxiliaries**:
- The `AVAudioEngineConfigurationChange` notification at
  `00:37:20.480` is the first observable side-effect of the
  AudioDeviceStart, and it reports outputNode at HFP rate.
- The HFP transition is BT-stack-level, not AVAudioEngine-level
  (Codex's original report; Apple-Forums posts on the same topic;
  ADR-014 / ADR-018 context).
- Workarounds we already tested in earlier investigation:
  - `sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP"
    -bool true` — DID NOT WORK on macOS 26.3.
  - HAL plugin (Rogue Amoeba ARK pattern) — would work but is V0.2
    scope, requires DriverKit / kext-style installation.

**Would falsify H15**:
- A future macOS release that doesn't force HFP for our tap.
- An app-side configuration (entitlement, plist key, audio session
  category) that we haven't tried that suppresses the route switch.
- Wired output or non-BT output → no HFP (this isn't falsifying so
  much as confirming the trigger).

**Decision (2026-05-29, EXP-036 → ADR-019)**: option 3 paid off. The app
switches the system default *input* device away from the Bluetooth device
for the duration of capture and restores it on stop, behind a default-on
toggle ("Preserve Bluetooth quality during capture"). This is the V0.1
mitigation. The HAL-plugin virtual device (option 2) is deferred to V0.2
as a robustness improvement, not a prerequisite. The README caveat
(option 1) is retained as a fallback for the toggle-off case and for Macs
with no usable non-BT input. See ADR-019 and EXP-037 (the automation,
pre-registered before its code).

Original options as recorded before EXP-036 (kept for the audit trail):
1. Ship V0.1 with a README caveat: "for full quality, use a wired
   output or built-in speakers. BT output is HFP-degraded while
   filtering is active. V0.2 will investigate the HAL-plugin path."
2. Block V0.1 on a HAL-plugin investigation. Adds weeks of scope.
3. Investigate a less-invasive workaround (e.g., AudioServerPlugin,
   route override, etc.) — uncertain payoff.

#### H17 — Format mismatch at the AVAudioSourceNode / IOProc boundary corrupts capture audio (split into H17a + H17b after EXP-033)

H17 originally bundled two candidate sub-mechanisms for one symptom
("pitched-down, voice-changer-anonymize + crackling + left-shift,
present on every capture"). Treating the bundle as a single confirmed
cause was the error FC-005 records. The sub-mechanisms are now tracked
separately because the EXP-033 intervention discriminated them.

**Symptom (shared)**: capture audio is pitched well below normal,
imaging shifted left, with periodic crackle, present regardless of
BT/speaker route. Masked on BT earlier by HFP downsampling and the
Bug A cutout; audible on speakers.

---

**H17a — sample-rate mismatch (chain at 44.1 kHz, tap at 48 kHz).**

- **Claim**: the chain ran at 44.1 kHz while the tap delivers 48 kHz,
  so 48 kHz samples played at 44.1 kHz (0.919× ≈ 1.5 semitones down).
- **Type**: the mismatch *obtaining* is source-grounded (EXP-032:
  `[EXP-032.format.source] rate=44100.0` vs tap 48 kHz). Whether it is
  the *cause* of the audible artifact was a separate, behavior-inferred
  claim.
- **Load-bearing status**: **REFUTED as the (dominant) cause by
  EXP-033.** Pinning the chain to the tap rate (`graph.attach`
  `sourceFormat:`) changed the readback to `rate=48000.0` — the fix
  landed — but the artifact did not move. A confirmed condition that
  obtains was mistaken for the cause. The rate fix is kept (it is
  correct on its own terms and avoids implicit SRC at the source-node
  boundary), but it does not explain the symptom.
- **Resurrection condition**: if, after H17b is fixed, a residual
  pitch error of ~0.919× remains, rate handling is back in play.

---

**H17b — channel-layout mismatch (interleaved tap, planar pipeline). ACTIVE; under test in EXP-034.**

- **Claim**: the tap delivers *interleaved* stereo (`[L, R, L, R, …]`,
  one buffer) but the ring buffer and render path are *planar* (one
  buffer per channel). `pushIOProcSamples` wrote the interleaved buffer
  as a single planar channel at `mDataByteSize / 4` = 2× the real
  frame count. Read back planar, that plays at half speed (one octave
  down → "super low"), strands content in channel 0 (left-shift), and
  alternates L/R within a channel (crackle). One mechanism, all four
  symptoms.
- **Type**: source-grounded. Tap ASBD `formatFlags=9` (Float|Packed,
  no non-interleaved bit) + `bytesPerFrame=8` (2 ch × 4 bytes) →
  interleaved. The planar assumption is in `AudioRingBuffer` and in
  `AVAudioFormat(standardFormatWithSampleRate:channels:)`. The evidence
  (`formatFlags=9`, `bytesPerFrame=8`) was in the `[EXP-029.tap.format]`
  log from the first instrumented run; it went undecoded until the
  rate fix failed.
- **Auxiliaries**: interleaving is the dominant remaining cause (no
  third mismatch at this boundary); the de-interleave index ordering
  matches the tap's L/R layout; the EXP-033 rate fix stays in place.
- **Would shift confidence down**: `[EXP-034.layout] interleaved=true`
  (fix landed) but the artifact persists → interleaving is not the
  dominant cause; revise toward the IOProc `AudioBufferList` byte
  arrangement or a channel-ordering bug. (See EXP-034's risky branch.)
- **Load-bearing status**: **CONFIRMED by EXP-034.** The de-interleave
  intervention moved the symptom — pitch, imaging, crackle, and
  perceived duration all corrected together, the "if load-bearing"
  branch of the locked prediction. This is the word "confirmed" used
  correctly: an intervention moved the symptom, not merely a condition
  shown to obtain.

---

**Relation to Bug A**: H17 and Bug A are independent. H17 explains the
persistent degradation present across all routes; Bug A (H16, below)
explains the dramatic cutout that is BT-specific. The two were
entangled because Bug A's cutout on BT made it impossible to evaluate
audio quality during capture; only on speakers could H17's degradation
become audible. After H17b is resolved, retest Bug A on BT — the
frame-count error may have compounded it.

#### H16 — Reverb bypass cuts audio on BT/HFP route (RESOLVED by EXP-035 — was coupled to Bug B)

**Resolution (EXP-035)**: the cutout was an artifact of the Bug B
frame-count error (interleaved-as-planar at 2× frames). After the
EXP-034 de-interleave fix corrected the source-node buffer cadence,
the BT retest showed **no cutout** on reverb-bypass toggle. Bug A and
Bug B were coupled. The long search for a reverb-specific or
BT/HFP-specific mechanism (below) was chasing a downstream symptom of
the interleaving bug; the "mechanism unknown" framing never resolved
because the real cause was upstream at the IOProc boundary, the same
place as Bug B. The remaining BT difference (reverb feels slighter) is
H15/HFP output degradation, not Bug A.

**Claim (historical)**: Toggling `setBypass(nodeID: ReverbNode.id,
bypass: true)` during active capture cuts audio entirely **when system
output is BT in HFP mode**. The same toggle on speakers (no BT) does
not cut audio. EQ bypass does not cut audio on any route. Chain
position is not the discriminator (chain-swap sub-experiment of
EXP-031: Reverb-as-first and Reverb-as-second both cut on BT). The
parallel-fan-out topology is not the cause (EXP-B1 standalone repro
DOES_NOT_REPRODUCE — every parallel-fan-out config produced
audible signal in isolation).

**Original (now-refined) suspect**: interaction between the
direct-IOProc-+-source-node architecture and graph mutation,
possibly via the engine-restart-on-config-change branch Codex's P1
fix introduced. **Current narrowed suspect**: an interaction
between BT/HFP route + `AVAudioEngineConfigurationChange` event +
our parallel-mixer scaffold for `AVAudioUnitReverb` specifically.

**Type**: Source-grounded for the audible behaviour (multiple
deliberate toggles by user, audibly reproducible, log-confirmed
state at moment of toggle, log-confirmed identical state for the
non-cutting EQ case). Behavior-inferred for the mechanism — we
don't know *why* AVAudioUnitReverb in this chain on BT/HFP causes
the cutout when EQ does not, and when the same topology in
isolation (EXP-B1) does not.

**Auxiliaries** (current narrowed suspects):
- `AVAudioEngineConfigurationChange` fires on Start (BT route → HFP),
  triggering our handler's `engine.start()` recovery branch. The
  recovery may leave Reverb's parallel scaffold in a state that's
  sensitive to subsequent bypass toggles in a way EQ's isn't.
- AVAudioUnitReverb has internal tail-processing state that, when
  combined with HFP's 16 kHz × 1 ch buffer cadence, produces a pull
  pattern AVAudioMixerNode handles pathologically.
- The HFP output causes the engine's render quantum to differ in a
  way that interacts with Reverb's parallel dry mixer chain but not
  EQ's.

**Refuted candidates** (do not resurrect):
- ❌ `graph.mutate` is triggered by setBypass — refuted by EXP-031
  run 2 (no `[EXP-031.mutateGraph.*]` events near setBypass).
- ❌ `AVAudioEngineConfigurationChange` race at the moment of
  bypass — refuted by EXP-031 run 2 (no configChange events near
  setBypass timestamps; the only configChange fires once at engine
  start time, well before any bypass).
- ❌ `applyMixGains` fallback bug silencing `mixer.volume`
  — fixed in v3 build, audio still cuts on BT.
- ❌ Format mismatch between Reverb and EQ chain elements — all
  formats identical at every internal node.
- ❌ AU-internal bypass — both `reverbAUBypass=false` and
  `eqAUBypass=false`.
- ❌ Chain-position-specific — chain-swap sub-experiment confirmed
  Reverb cuts wherever it is, EQ doesn't cut wherever it is.
- ❌ Parallel-fan-out topology alone — EXP-B1 standalone repro:
  every config in isolation produces audible dry signal at the
  same peak amplitude as EQ's equivalent.

**Would falsify H16 (now-narrowed)**:
- A future test that shows reverb bypass cuts audio on speakers
  (with no BT) — would refute the BT-only framing.
- A test where the configChange handler is disabled and bypass
  still cuts on BT — would refute the configChange-handler-leaves-
  scaffold-broken hypothesis.
- A wired-output (USB DAC, USB headphones) test that shows cutout
  — would refute the HFP-specific framing and point at "any
  non-built-in-speaker output."

**Path forward**: Bug A is now **lower priority** than Bug B (H17).
H17 is degrading every capture and is plausibly addressable; Bug A
is BT/HFP-specific and may be intrinsic OS routing pathology
(adjacent to H15). Plan:
1. Resolve H17 (Bug B) first — that's the fundamental capture
   correctness issue.
2. Once H17 is fixed, retest Bug A on BT. If the H17 fix changes
   the format/quantum at the source-node boundary, Bug A may also
   change behavior. If Bug A persists on BT, treat as a separate
   investigation; if it disappears, the two were coupled.
3. If Bug A persists post-H17 and is unfixable in V0.1 scope,
   document in ADR-019 alongside H15 (HFP) as an intrinsic-OS-route
   limitation. V0.1 README caveats apply.

### Inactive

#### H13 — Leaked HAL state from prior runs blocks AudioDeviceStart (REFUTED 2026-05-28 by EXP-030)

**Original claim**: A tap or aggregate device from a prior crashed
or unclean run sits in the HAL's process-tap registry; the new
tap/aggregate creation succeeds (fresh ID) but `AudioDeviceStart`
fails with `kAudioHardwareIllegalOperationError` ('nope',
1852797029) because the HAL refuses to start a new device while
orphans tagged to our process exist. Was the leading hypothesis
for the EXP-027 / EXP-028 deterministic failures.

**Refutation**: EXP-030's 3-launch force-kill protocol. Launch 2
was deliberately force-killed mid-capture (capture state was
`running`, no Stop event logged); 39 s later, Launch 3 ran the
cleanup pass and the production Start. Launch 3 saw
`[EXP-030.preinit.taps] enumerated=0 matched=0` and
`[EXP-030.preinit.aggregates] enumerated=6 matched=0` — no orphans
visible to the new process instance — and `AudioDeviceStart`
returned 0 anyway. The HAL either auto-destroys process taps and
private aggregate devices on process death, or makes them
invisible to a new process instance via the enumeration
properties. The mechanism H13 hypothesized — "orphan tap in HAL
registry blocks new AudioDeviceStart" — cannot operate because the
preconditions never obtain.

**Auxiliaries the refutation relied on**:
- `kAudioHardwarePropertyTapList` reads consistently (verified by
  `[EXP-029.prestart.taps] count=1` on each launch's
  freshly-created tap — the property works; "zero at init" is not
  a query failure).
- `enumerateAllAudioDevices()` works (returned 6 devices each
  launch, matching the system's known audio device count).
- The UID-prefix match logic works (would have matched any
  aggregate whose UID starts with `tap-n-filter.aggregate.` —
  matches at-capture-time but absent at init time as expected).

**Status of EXP-027 / EXP-028 mechanism**: Unexplained but
inert. No recurrence across 6+ Starts in EXP-029 + EXP-030 +
EXP-031. The most parsimonious frame: some daemon-side state
caused those original failures and has since cleared.

**Resurrection condition**: A future scenario reproduces the
EXP-027 / EXP-028 `AudioDeviceStart 1852797029` failure
deterministically, AND `[EXP-030.preinit.matched]` count is
observed > 0 at the failing launch's cleanup pass. Then H13's
simple form can be re-examined.

**Broader "leaked state" framing still plausible but un-actionable**:
coreaudiod-internal per-process state not exposed via
`kAudioHardwarePropertyTapList`; IOProc-ID bindings the daemon
hasn't fully released; rapid-restart race conditions. These cannot
be interrogated via the EXP-030 protocol. Would need
`sample`/`lldb` on coreaudiod, or a different reproduction trigger.

**Code in place**: `CaptureController.cleanupOrphans()` runs at
init, destroys any taps with name prefix `tap-n-filter.tap.` and
any aggregates with UID prefix `tap-n-filter.aggregate.`. Honors
`UserDefaults.standard.bool(forKey:
"tap-n-filter.disableOrphanCleanup")` as a negative-control knob.
Benign defensive infrastructure: ~30 ms cost at launch, no-op in
normal operation. Stays in place for future-proofing.

#### H9 — Tap's `isPrivate=true` causes `AudioDeviceStart` to return 'nope' (REFUTED 2026-05-28 by EXP-029)

**Claim**: Setting `description.isPrivate = true` on the
`CATapDescription` (per the production `coreAudio.createTap`)
prevents `AudioDeviceStart` on the wrapping aggregate from
returning 0 on macOS 26.3.

**Type**: behavior-inferred (from the differences between EXP-026's
inline tap creation, which omitted `isPrivate` (default false) and
passed AudioDeviceStart=0, versus production which sets
`isPrivate=true` and fails). NOT source-grounded yet — we have not
read Apple documentation or any source that says private taps are
forbidden from being started via direct IOProc.

**Auxiliaries** (must be true for H9 to be the cause):
- `description.isPrivate` defaults to `false` when not explicitly
  set (CoreAudio framework default).
- The HAL's permission/policy check distinguishes "private tap +
  AudioDeviceStart" from "non-private tap + AudioDeviceStart".
- audiotee from Terminal (which sets `isPrivate = true` per
  `AudioTapManager.swift`) works because Terminal's TCC grants give
  it a different policy class than our app, NOT because `isPrivate`
  is fine in general.

**Would falsify H9**:
- EXP-029 minimal-reader passes with current `isPrivate=true`. The
  difference is then somewhere else.
- Audiotee from Terminal with `isPrivate=true` succeeds AND our
  EXP-026's inline test with `isPrivate=false` also succeeds, but
  setting `isPrivate=false` in our production path STILL fails.
  That would mean `isPrivate` isn't the discriminating variable.

**Time budget**: EXP-029 (~30 min implementation + 5 min run)
should produce the falsifying or supporting evidence.

#### H10 — `engine.attach(sourceNode)` BEFORE `reader.start()` pre-empts the aggregate (REFUTED 2026-05-28 by EXP-029)

**Refutation**: EXP-029's production path includes `engine.attach(sourceNode)`
18 ms before `reader.start()` (per the
`[EXP-029.engine.postattach]` log line at 00:37:20.377), AND
`AudioDeviceStart` still returned 0. The minimal-reader path with
NO `engine.attach` ALSO returned 0. The variable I expected to
discriminate doesn't. **Auxiliaries the refutation relied on**: the
log timestamps and engine.isRunning readback are accurate (both
report false before reader.start). **Resurrection condition**: the
production path begins failing again WITHOUT a state-leak
explanation AND a follow-up confirms engine.attach is the only
remaining variable.

**Claim**: On macOS 26.3, calling `AVAudioEngine.attach(sourceNode)`
forces the engine to lazily initialize its unified IO AU, which
takes ownership of system audio state in a way that makes the
subsequent `AudioDeviceStart` on a separately-created tap aggregate
return 'nope' (kAudioHardwareIllegalOperationError). EXP-026 worked
because no AVAudioEngine instance was touched before
`AudioDeviceStart`.

**Type**: behavior-inferred (from the structural difference between
EXP-026 (no engine in scope) and EXP-027/028 (engine attached
between tap creation and AudioDeviceStart)).

**Auxiliaries**:
- `AVAudioEngine.attach()` actually triggers HAL-side state
  initialization on macOS 26.3 (not just an in-engine bookkeeping
  step).
- The "unified IO AU" model (source-grounded in EXP-023) means the
  engine's audio unit, once initialized, holds onto a default
  output device claim that conflicts with a tap aggregate.
- The CaptureController's `engine.attach(sourceNode)` is the FIRST
  contact with the engine's IO AU during a Start flow (not, e.g.,
  graph.attach at app launch).

**Would falsify H10**:
- EXP-029 minimal-reader (NO engine.attach) STILL fails with
  AudioDeviceStart 'nope'. Then engine.attach isn't the issue.
- A variant where we reorder `engine.attach` to AFTER
  `reader.start()` ALSO fails. (Would need a follow-up experiment.)

**Time budget**: EXP-029 directly tests this. Same 35-min budget.

#### H11 — One of {`name` set, `isExclusive=false` explicit} is the cause (REFUTED 2026-05-28 by EXP-029)

**Refutation**: Both EXP-029 paths use `coreAudio.createTap` which
sets `name` and `isExclusive=false` identically; both passed.
**Auxiliaries**: `coreAudio.createTap` was actually called in both
paths (logged via `[EXP-029.tap.create]`). **Resurrection
condition**: a future experiment that varies these fields shows a
discriminating effect.

**Claim**: A field difference in the CATapDescription other than
`isPrivate` and `muteBehavior` discriminates pass from fail. Candidate
fields: `description.name`, `description.isExclusive` (explicit
false vs unset).

**Type**: behavior-inferred. Not source-grounded.

**Auxiliaries**:
- Setting `description.name` to a non-empty string has
  HAL-observable effects on whether AudioDeviceStart succeeds.
- Or: `description.isExclusive = false` explicitly differs from
  leaving it unset (both should resolve to `false`, but if Swift
  bridges nil/unset differently, the HAL might see different bits).

**Would falsify H11**:
- EXP-029 minimal-reader succeeds with the same tap description
  (production's createTap), refuting H11 (because the same fields
  would be set).
- A follow-up experiment that ELIMINATES name and isExclusive
  explicit-set still fails.

#### H12 — Existing AVAudioEngine instance holds HAL state that blocks the new aggregate (REFUTED 2026-05-28 by EXP-029)

**Refutation**: Both EXP-029 paths run inside the same AppViewModel
with the same live AVAudioEngine instance (instantiated at app
launch, with graph attached). Production path uses the engine
directly; Reader test ignores the engine but the instance exists.
Both pass. The engine instance's existence isn't the blocker.
**Auxiliaries**: AppViewModel.init had run and the engine
property was populated before either button was pressed.
**Resurrection condition**: a future experiment in a fresh
process (no app-level engine) shows different behaviour from this
process's behaviour.

**Claim**: `AVAudioEngine()` (or its lazy IO AU initialization
triggered by any earlier access like `engine.mainMixerNode`)
acquires HAL state at AppViewModel init time (or graph.attach
time). That state then prevents `AudioDeviceStart` on a separately-
created aggregate.

**Type**: behavior-inferred. Differs from H10 in that H10 blames the
specific `engine.attach(sourceNode)` call in `CaptureController.start`;
H12 blames any earlier engine state acquisition (e.g., the
`engine.mainMixerNode` access at app init when restoring the graph).

**Auxiliaries**:
- `AVAudioEngine()` instantiation alone (no method calls) does not
  acquire HAL state.
- BUT `engine.mainMixerNode` accessor DOES trigger lazy IO AU
  creation (verifiable by reading the AVAudioEngine implementation
  or by direct experiment).
- The graph attach at AppViewModel init time wires the effect chain
  THROUGH mainMixerNode, which means mainMixerNode has been touched
  before any user Start.

**Would falsify H12**:
- EXP-029 minimal-reader (which runs inside AppViewModel, with the
  engine instance already initialized + graph attached) passes.
  Then the engine instance / graph state isn't blocking.
- Or: a variant test in a fresh process with NO graph attachment
  succeeds, but production STILL fails — that would point at the
  graph attach, not the engine instantiation.

#### H14 — Combination of multiple D-differences, not any single one (REFUTED 2026-05-28 by EXP-029)

**Refutation**: Both EXP-029 paths use IDENTICAL CATapDescription
field combinations (production uses `coreAudio.createTap`; Reader
test does too — see code path in `AppViewModel.performReaderTest`)
and IDENTICAL aggregate description dictionaries, AND both pass.
There is no D-combination that distinguishes pass from fail in
this dataset. **Auxiliaries**: the two `coreAudio.createTap` calls
have identical field assignments by construction. **Resurrection
condition**: a future experiment shows a specific D-combination
discriminating pass from fail.

**(see superseded entry below for original claim)**

#### H14-original — Combination of multiple D-differences, not any single one

**Claim**: None of D1–D7 is sufficient on its own. The cause is a
specific combination (e.g., `isPrivate=true` + `name` set + engine
attached).

**Type**: behavior-inferred. The "this is the conjunction" theory.

**Auxiliaries**:
- Each individual difference IS observable in some path that passes.
- The HAL applies stricter checks when multiple flags align in a
  particular way.

**Would falsify H14**:
- Each of D1–D7 alone discriminates pass/fail in a clean
  single-variable test. (Lots of experiments to prove this.)

**Time budget**: H14 is the residual hypothesis if H9–H13 are all
individually falsified. Don't budget specifically; iterate on H9–H13
first.

#### H1 — `pinEngineOutputToDefault` is the upstream blocker

**Claim**: removing the `pinEngineOutputToDefault` call from
`CaptureController.start` will let `capture.start` succeed for the
first time on this branch.

**Type**: source-grounded (read the failing call site at
[CoreAudioInterface.swift:355-379](../../Sources/Capture/CoreAudioInterface.swift#L355-L379)
and the throw site at
[CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210);
matched against -10851 log entries spanning 04:44 → 10:28 EDT).

**Auxiliaries**:
- The log file accurately records `captureState` transitions and
  `lastError` writes in real ordering.
- The -10851 status reported in logs is the same `OSStatus` that
  `AudioUnitSetProperty` returned (no intermediate wrapping).
- `AVAudioEngine.outputNode.audioUnit` is in fact a
  `kAudioUnitSubType_DefaultOutput` AU on macOS 26.3 (per Codex's
  citation; not directly verified by us).

**Would shift confidence down**: EXP-013 removes the call, rebuilds,
and production Start still throws -10851 from elsewhere. Or:
production Start succeeds but produces silence anyway, with no further
errors — that would shift weight toward a second, deeper bug.

#### H2 — BT HFP routing is a real but secondary problem

**Claim**: even with H1 fixed, binding an aggregate to
`AVAudioEngine.inputNode` will trigger HFP on BT default-output
devices. Production will work on built-in speakers but degrade on BT.

**Type**: behavior-inferred (Codex investigation report + log entries
showing `outputNode=16000.0 Hz × 1 ch` immediately after
`configureEngineInput` on BT).

**Auxiliaries**:
- Codex's diagnosis of "binding aggregate to inputNode AUHAL triggers
  HFP" is correct on macOS 26.3 — drawn from forum reports and Codex's
  reasoning, not directly verified by us against documented Apple
  behavior.
- The `outputNode` format-change observations were caused by HFP and
  not by an unrelated engine reconfiguration event.

**Would shift confidence down**: with H1 fixed, BT capture works at
44.1 kHz × 2 ch with no HFP switch. That would partially refute the
Codex thesis.

#### H3 — HFPSpike's IOProc-never-fires is a code bug, not a platform limit

**Claim**: `tap-n-filter.app` has the right TCC; if the same process
can capture via AUHAL (production, when not crashing) it should also
capture via direct IOProc. Therefore the spike has a code bug.
Candidate causes: (a) embedded vs post-creation tap list when creating
the aggregate, (b) a leaked aggregate from a prior failed production
Start interfering, (c) some interaction between the spike's engine and
the same process's earlier engine state.

**Type**: behavior-inferred (we inferred "should fire" from "audiotee
fires from less-privileged binary"; we haven't traced the code path
end-to-end to verify the spike's IOProc *should* fire).

**Auxiliaries**:
- Audiotee's "IOProc fires (with zero data) from Terminal" is a valid
  signal that the IOProc mechanism works for binaries with comparable
  signing on macOS 26.3.
- TCC is the *only* difference between audiotee's "fires silent" and a
  spike-that-would-fire-with-audio. Other potential differences
  (aggregate creation order, tap config, engine interactions) aren't
  the cause.
- No leaked Core Audio state from prior failed production runs is
  blocking the spike's IOProc.

**Would shift confidence down**: any of the auxiliaries failing — e.g.,
we find audiotee's IOProc *also* doesn't fire on a fresh boot, or we
discover a leftover aggregate from a prior crash that we never
destroyed. Status: **moved to inactive** after FC-001 (see Programme
health). Resurrection condition: a fix to H1 unblocks production, we
re-enter the HFP architectural question, and H3 becomes relevant
again.

**Auxiliary refuted 2026-05-25 12:10 EDT**: ran the spike again
post-H1+H4 fix (production now succeeds; engine reaches sustained
`running`). Spike still logs `ioProc fires=0` across 5+ seconds. So
the spike's failure is not because of entanglement with broken
production state. The remaining candidates (post-creation tap list
ordering, or some Swift-specific interaction with the IOProc
machinery) are still in play.

#### H6 — `engine.outputNode` (`DefaultOutput` AU) fails to bind to built-in speakers after `configureEngineInput`

**Claim**: when `configureEngineInput` re-points `engine.inputNode`'s
AUHAL at the tap aggregate device, `engine.outputNode` (backed by
`kAudioUnitSubType_DefaultOutput`) enters an unbound state on built-in
speakers and `outputFormat(forBus: 0)` reports `0 Hz × 0 ch`
indefinitely. On Bluetooth the system's routing infrastructure
triggers a rebind (we see outputNode reach A2DP at 44.1 kHz × 2 ch in
~300 ms, then later HFP at 16 kHz × 1 ch). On built-in speakers no
rebind happens. Bug exists on macOS 26.3; not yet tested on other
versions.

**Type**: source-grounded (diagnostic logging in EXP-018 follow-up
showed outputFormat stuck at exactly 0 Hz × 0 ch for 100 polls × 50 ms
= 5 seconds, never any other value).

**Auxiliaries**:
- `engine.outputNode.outputFormat(forBus: 0)` is the correct API to
  read the hardware-facing format of outputNode (not some indirect
  cached value).
- Built-in MacBook Air Speakers work as the system default output in
  normal use (we hear Safari audio when capture isn't active).
- `coreaudiod` was successfully restarted before EXP-018's retry, so
  the symptom is not stale daemon state.
- The new `engine.prepare()` call before the wait loop is correctly
  compiled into the running binary (`Build/bundle-dev.sh` succeeded,
  CDHash changed accordingly).
- macOS 26.3's audio routing infrastructure normally rebinds output
  devices for engines configured for capture (verified on BT
  empirically in EXP-013/14).

**Would shift confidence down**:
- A test variant where the same code path succeeds on speakers in
  some context (e.g., a different sequence of operations, a fresh
  reboot, or with the engine recreated post-capture).
- Discovery that `outputFormat(forBus: 0)` reports stale data while
  the underlying audio unit DOES have a valid CurrentDevice/StreamFor-
  mat — i.e., the symptom is in the AVAudioEngine API layer, not in
  the audio unit binding.

**Time budget**: 45-60 min for EXP-019 (combined diagnostic +
intervention experiment). If unresolved within budget, defer with
notebook entry documenting deepest state reached; proceed to BT reverb
extreme-sweep test regardless of H6's status.

#### H7 — Unified IO AU's CurrentDevice routes engine output into the no-output tap aggregate

**Claim**: on macOS 26.3, `AVAudioEngine.inputNode.audioUnit` and
`AVAudioEngine.outputNode.audioUnit` are the same `HALOutput` AU
instance (confirmed in EXP-023: `inputAU=0x00000000926600bf,
outputAU=0x00000000926600bf, same=true`). The HAL Output AU has a
single `kAudioOutputUnitProperty_CurrentDevice` property; when
`configureEngineInput` sets it to the tap-wrapping aggregate device,
the same AU is now writing its output to that aggregate too. The
aggregate (constructed in
[CoreAudioInterface.swift:223-249](../../Sources/Capture/CoreAudioInterface.swift#L223-L249))
contains only a `kAudioAggregateDeviceTapListKey` entry, no
`kAudioAggregateDeviceSubDeviceListKey`, no
`kAudioAggregateDeviceMainSubDeviceKey`. A process tap is input-only;
the aggregate therefore has no output streams. Engine-output frames
written to this device go nowhere — the user hears silence even
though the engine reports `isRunning=true` and the effect chain runs.

**Type**: source-grounded (read the aggregate construction in
`createAggregateDevice`; read EXP-023 log lines confirming AU
identity; matched against user-reported Outcome D in EXP-021).

**Auxiliaries**:
- `AVAudioEngine` on macOS 26.3 wires `inputNode` and `outputNode`
  through one `HALOutput` AU rather than separate `HALOutput` (input
  side) + `DefaultOutput` (output side) AUs as on earlier macOS. The
  fact that EXP-023's pointer comparison returned `same=true` is the
  strongest source-grounded evidence we have.
- The tap aggregate genuinely has zero output streams. We have not
  directly verified this with
  `AudioObjectGetPropertyDataSize(...kAudioDevicePropertyStreams, scope=Output)`,
  but the construction dictionary contains no
  output-providing keys and the macOS docs say a tap is input-only.
- The HAL Output AU's behavior when its CurrentDevice has no output
  streams is to silently discard frames rather than throw an error.
  This is also not directly verified — it's the simplest explanation
  for "no errors logged, no audio audible."
- `engine.outputNode.outputFormat(forBus: 0)` reporting
  `16000.0 Hz × 1 ch` (HFP rate) post-start despite CurrentDevice =
  tap aggregate is consistent with the format being a phantom /
  cached value not reflecting the actual hardware route, OR with the
  HAL Output AU's output bus reading from a different scope than its
  CurrentDevice. We don't know which.

**Would shift confidence down**: EXP-024 finds the WAV file is all
zeros → engine produces silence before reaching the device write
step → H7 is wrong about *where* the silence originates. Or:
EXP-024 finds the WAV has audible content + a follow-up "play the
mixer tap through a separate engine bound to default output"
experiment also plays silence → silence is not at the
mixer-to-device step but somewhere else not yet hypothesized.

**Time budget**: EXP-024 implementation + run + analysis ≈ 90 min.

#### H4 — `attemptReattach` re-attaches an already-attached graph on AVAudioEngineConfigurationChange

**Claim**: when an `AVAudioEngineConfigurationChange` notification fires
(e.g., when BT switches profile and the engine reconfigures), the
recovery logic calls graph attach on a graph that's already attached,
throwing `Graph.GraphError.alreadyAttached`. This collapses capture
state to idle, which auto-retries, which loops indefinitely. With H1
now fixed, this is the next observable bug.

**Type**: source-grounded (log shows the error verbatim at
11:43:07.750 EDT and the captureState cycling that follows).

**Auxiliaries**:
- The `attemptReattach` code path is reachable as logged.
- `Graph.GraphError.alreadyAttached` means literally "this graph is
  already attached to the engine"; the recovery should detach first
  or skip the attach.
- The retry loop is auto-driven by the AppViewModel, not by the user
  repeatedly pressing Start.

**Would shift confidence down**: reading the `attemptReattach` code
reveals the error means something different than I think, or the
retry loop is user-driven (e.g., a button-state bug auto-fires Start).

### Inactive

(none currently)

### Ruled out

#### R1 — Bluetooth A2DP/HFP routing is the *only* issue

**Type**: behavior-inferred.
**Refuted by**: EXP-012 — production fails identically on built-in
speakers (no BT involved). HFP is real but secondary.
**Auxiliaries the refutation relied on**: the speaker-test logs
recorded the same -10851 (verified). The user actually pressed Start
on speakers (user-reported).
**Resurrection condition**: discovering that the speaker-mode logs
were stale and we actually only tested BT.

#### R2 — Self-signed `LOCAL_SIGNING_IDENTITY` cert is insufficient for TCC persistence on macOS 26

**Type**: behavior-inferred.
**Refuted by**: EXP-011 — unchanged binary did not re-prompt across
launches.
**Auxiliaries**: the user re-launched the same binary (CDHash unchanged,
confirmed by EXP-010 source-grounded check).
**Resurrection condition**: a future macOS update tightens self-signed
TCC handling; observable as a re-prompt for an unchanged binary.

#### R3 — Ad-hoc signing is the difference between audiotee working and our spike failing

**Type**: behavior-inferred.
**Refuted by**: EXP-007 / EXP-008 — audiotee is also ad-hoc signed and
its IOProc fires (it just gets silenced by TCC).
**Auxiliaries**: audiotee's stderr "Audio device started successfully"
and the 883k byte output are accurate signals that the IOProc fired.
**Resurrection condition**: discovering audiotee's "stream_start" /
byte output is an artifact of buffering, not real IOProc firing.

#### R4 — Switching the spike's IOProc from Swift block to C function pointer would unblock it

**Type**: behavior-inferred.
**Refuted by**: EXP-005 — no behavior change.
**Auxiliaries**: the C-function-pointer build was actually the binary
that ran (the user did open the rebuilt .app, not a cached older
version).
**Resurrection condition**: discovering the rebuild didn't actually
take effect (e.g., user launched a stale bundle).

#### R5 — BT is the variable killing the spike

**Type**: behavior-inferred.
**Refuted by**: EXP-004, EXP-008, EXP-009 — same failure with BT
disconnected.
**Auxiliaries**: BT really was disconnected during those tests (BT
menu confirmed by user, plus `system_profiler` showed built-in as
default output).
**Resurrection condition**: discovering BT was still affecting routing
in some way despite the menu reporting disconnected.

#### R6 — AudioCap pattern (.mutedWhenTapped, isPrivate=false) would unblock the spike

**Type**: behavior-inferred.
**Refuted by**: EXP-006 — no behavior change.
**Auxiliaries**: the spike was actually running with the changed tap
config (verified by the log line `mute: .mutedWhenTapped, private:
false`).
**Resurrection condition**: discovering the tap config didn't change at
runtime despite our edits (e.g., a typo or a property setter ordering
bug).

#### R8 — H3: HFPSpike's IOProc-no-fire is a code bug, not a platform limit (RESOLVED 2026-05-27)

**Type**: source-grounded (EXP-026 directly observed the IOProc
firing 471 times in 5 s with 99.5% non-zero samples, peak 0.73,
from inside tap-n-filter.app with its existing TCC grant).

**Resolution**: H3 was correct that the IOProc-no-fire was a code-
level bug, but the specific candidate causes I listed in the
hypothesis (Swift block vs C pointer, tap config, engine
entanglement, ad-hoc signing) were all wrong. The actual cause was
two missing keys in the aggregate creation dictionary:
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0`. Audiotee's working
implementation includes them; HFPSpike and our prior
AudioteePatternTest attempts did not. The keys initialize the
aggregate's clock infrastructure; without them, the IOProc has no
clock and never fires.

**Auxiliaries the refutation relied on**: EXP-026's exact pattern
matched audiotee's `createAggregateDevice` byte-for-byte (lines
103-125 of `AudioTapManager.swift`), plus the post-set tap list
attached via `AudioObjectSetPropertyData` with a `CFArray<CFString>`
payload. The 99.5%-non-zero verdict source-grounds the success.

**Resurrection condition**: none anticipated. If a future macOS
breaks even this pattern, we'd see audiotee itself fail too, which
would be observable.

#### R7 — The HFPSpike's "A2DP RETAINED" verdict means the architecture works on BT

**Type**: source-grounded (re-read the verdict computation in
`HFPSpike.swift`).
**Refuted by**: source inspection — the verdict says only "outputNode
format ≥44.1 kHz × 2 ch." This can be satisfied whenever the IOProc
never fires, because the engine never tried to drive captured audio
through BT output. The verdict is a tautology of the IOProc-failed
state, not a positive signal about the architecture.
**Auxiliaries**: none — this is a direct misreading of the diagnostic,
not a behavioral inference.
**Resurrection condition**: none. Recorded so future readers don't
re-believe the spike's optimistic logging.

## Intervention ledger

Every fix that targeted a hypothesized cause, newest first. A fix is an
intervention and an intervention is an experiment (see
`docs/governance/debugging-protocol.md`); each row links to its full
pre-registered entry in the experiment log. **Landed?** = did the change
take effect (proven by a diagnostic). **Resolved?** = did the symptom go
away (the load-bearing test). A "yes / no" row — landed but did not
resolve — is the most informative kind: it refutes the target mechanism as
load-bearing without ambiguity.

| EXP | Date | Target mechanism | Type | Landed? | Resolved? | Revision on failure |
|---|---|---|---|---|---|---|
| EXP-037 | 06-08 | H15 automation: app switches default input away from BT during capture and restores on stop/crash (lever already confirmed load-bearing by EXP-036) | intervention — **pre-registered; code not yet written** | pending | pending | landed-but-unresolved routes to auxiliary A1 (switch timing vs HFP negotiation), not the mechanism; restore failure (D3/D4) is a ship-blocker routed to save/restore + crash-marker code |
| EXP-037-R | 06-16 | EXP-037's race-check auxiliary A4: does the chosen signal discriminate A2DP playback from active HFP mic use? | measurement (signal selection) — pre-registered | Y yes (07-31); Z pending | **Y: SIG_A clean** — the headset is two device objects, so output playback cannot mark the *input* object running; Codex #3 refuted for split-object hardware | risky branch taken (SIG_A false in Y) ⇒ no revision; shipped race check stands. A combined-object headset would reinstate the finding |
| EXP-036 | 05-29 | H15 refined: HFP trigger gated on BT being the system default *input*; manually set default input to built-in mic | behavior-inferred (causal); source-grounded (format readback) | yes (default input changed; input path 44.1 kHz) | **yes** — output stayed A2DP (`outputOut 44100×2` vs `16000×1`); reverb depth/width returned | — (lever confirmed load-bearing; app-side automation = EXP-037, settings branch) |
| EXP-034 | 05-28 | Bug B: tap is interleaved, pipeline is planar; IOProc writes interleaved data as one planar channel at 2× frames | source-grounded (flags=9, bytesPerFrame=8) | yes (build; `[EXP-034.layout] interleaved=true`) | **yes** — pitch, imaging, crackle, duration all resolved together | — (mechanism confirmed load-bearing) |
| EXP-033 | 05-28 | Bug B (H17a): chain runs at 44.1 kHz while tap is 48 kHz; pin chain to tap rate via `graph.attach(sourceFormat:)` | source-grounded (EXP-032 readback) | yes (`[EXP-032.format.source] rate=48000`) | **no** (still pitched low) | rate mismatch obtains but is **not load-bearing** for the audible artifact → look for a second mismatch at the same boundary → EXP-034 |
| (H17 v1) | 05-28 | Bug B: `AVAudioConverter` from tap rate to engine rate in the render callback | behavior-inferred | no (converter was 48k→48k, a no-op; read pre-start outputNode format) | no | fix mis-implemented (read the wrong format, before `engine.start()`); superseded by EXP-033 |
| EXP-031 | 05-28 | Bug A (H16): `applyMixGains` fallback wrote `mixer.volume`, possibly silencing master | source-grounded | yes (master volumes read 1.0) | **no** (audio still cuts on reverb bypass on BT) | fallback bug was real but not the cause of the BT cutout → Bug A narrowed to BT/HFP route, parked |

## Experiment log

### EXP-001 — Codex investigation request

**Date**: 2026-05-24 (approximate, prior session)
**Author**: prior session
**Question**: Why does starting capture on Bluetooth headphones force
macOS into HFP voice mode, and what's the canonical architecture for
process-tap capture + playback through a user's chosen output device?

**Method**: invoked `/codex:rescue` with the full architecture context.
The original local session transcript is not part of the public source tree.

**Artifacts**: Codex's reply summary (lives in conversation history).

**Observations**: Codex confirmed the root cause: binding the aggregate
device to `AVAudioEngine.inputNode`'s underlying AUHAL via
`kAudioOutputUnitProperty_CurrentDevice` triggers BT HFP because macOS
sees an active capture session paired with a BT default output and
forces voice mode. Codex's canonical fix: read the tap directly via
`AudioDeviceCreateIOProcID` and feed an output-only `AVAudioEngine`
through an `AVAudioSourceNode`. Codex explicitly noted: "Only
`kAudioUnitSubType_HALOutput` accepts that [`CurrentDevice`] property"
— i.e., the `pinEngineOutputToDefault` band-aid would *not* work
against `AVAudioEngine.outputNode` (which uses `DefaultOutput`).

**Conclusion**: Codex's diagnosis is consistent with the observed logs.
Their architectural recommendation is the right long-term path. Their
warning about `pinEngineOutputToDefault` being a non-fix was ignored at
the time and is the source of EXP-012's smoking gun.

**Follow-ups**: build the spike to validate the IOProc + SourceNode
architecture empirically before committing to a 400-600 LOC production
refactor. → EXP-002.

### EXP-002 — Build HFPSpike scaffolding

**Date**: 2026-05-25 (early in current session)
**Author**: current session

**Question**: Can a Swift implementation of "create tap, wrap in
aggregate, drive an IOProc, feed `AVAudioSourceNode`" actually run end
to end without HFP triggering on BT?

**Variables held constant**:
- tap-n-filter.app's TCC grants
- Source process: Safari (PID 72409) playing YouTube
- BT: Bose QC headphones connected, A2DP

**Variables changed**:
- Compared to production: capture happens via direct IOProc instead of
  AUHAL `kAudioOutputUnitProperty_CurrentDevice`
- Engine has only output side wired (no `inputNode` access)

**Method**: implemented `Sources/ViewModel/HFPSpike.swift` with a Start
button in the debug panel. Tap created with `CATapDescription`
+ `AudioHardwareCreateProcessTap`, aggregate created with
`AudioHardwareCreateAggregateDevice` and `kAudioAggregateDeviceTap-
ListKey` embedded in the description, IOProc created with
`AudioDeviceCreateIOProcIDWithBlock`, ring buffer feeds an
`AVAudioSourceNode` into an output-only engine. Periodic counter
snapshots at +1s, +2s, +3s, +5s log whether the IOProc has fired.

**Artifacts**:
- `Sources/ViewModel/HFPSpike.swift`

**Observations**: scaffolding compiles and Start runs without
exceptions. Counters never tick.

**Conclusion**: scaffolding is in place; IOProc not firing is the next
mystery. → EXP-003.

**Follow-ups**: Q3 — why does the IOProc never fire?

### EXP-003 — HFPSpike Start with BT, Safari playing

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: With everything wired up per EXP-002, does the IOProc
fire at all on BT?

**Variables held constant**:
- All from EXP-002 environment.

**Variables changed**: none (first run).

**Method**: open tap-n-filter.app, open debug panel, select Safari as
source, press "HFP spike Start". Wait 5+ seconds. Press Stop.

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` entries tagged
`HFPSpike` for the first spike run of the session (timestamp varies;
look for the earliest `HFPSpike.start` of the day).

**Observations**: tap creation reports `status=0`. Aggregate creation
reports `status=0`. Aggregate stream count: `input=1, output=0`. IOProc
registration reports `status=0`. `AudioDeviceStart` returns 0. Every
verdict snapshot reports `ioProc fires=0, frames=0; render fires=N
(growing)`. `outputNode` format stays at 44.1 kHz × 2 ch ("A2DP
RETAINED" verdict — see R7 in the hypothesis ledger).

**Conclusion**: the IOProc is registered and the device is "started"
per Core Audio's return codes, but no callback ever fires. The render
side runs (the source node is asked to fill buffers); it always reads
silence from the empty ring buffer.

**Follow-ups**: rule out variables one at a time. → EXP-004 (speakers),
EXP-005 (C function pointer), EXP-006 (AudioCap config), EXP-007 (cert).

### EXP-004 — HFPSpike Start with built-in speakers (BT disconnected)

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Is BT a necessary condition for the IOProc failure?

**Variables held constant**: same as EXP-003 except:
**Variables changed**: BT disconnected, default output = built-in MacBook
speakers.

**Method**: identical to EXP-003 with the BT headphones unpaired
(Bluetooth menu → disconnect QC headphones).

**Observations**: identical pattern — `ioProc fires=0, frames=0`, render
fires growing, no audio output.

**Conclusion**: BT is not the variable. Removed H_BT from the hypothesis
set (now R5).

### EXP-005 — HFPSpike with C function-pointer IOProc

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does macOS 26 restrict the Swift-block
(`AudioDeviceCreateIOProcIDWithBlock`) variant for tap aggregates while
leaving the C function-pointer variant (`AudioDeviceCreateIOProcID`)
working?

**Variables held constant**: same as EXP-003.
**Variables changed**: `AudioDeviceCreateIOProcIDWithBlock` →
`AudioDeviceCreateIOProcID` with a file-scope
`@convention(c)` function pointer (`hfpSpikeCIOProc`). Spike instance
passed via opaque `inClientData`.

**Method**: edited
`Sources/ViewModel/HFPSpike.swift`, rebuilt, re-ran.

**Observations**: identical pattern — `ioProc fires=0`.

**Conclusion**: the IOProc API variant is not the variable. Now R-? in
the hypothesis ledger (R4).

### EXP-006 — HFPSpike with AudioCap-matching tap configuration

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does AudioCap's specific `CATapDescription` configuration
(isPrivate=false, muteBehavior=.mutedWhenTapped, isExclusive=false)
unblock the IOProc?

**Variables held constant**: same as EXP-003.
**Variables changed**: tap config to match AudioCap exactly. (Production
uses `muteBehavior=.muted` and `isPrivate=true`.)

**Observations**: identical pattern — `ioProc fires=0`.

**Conclusion**: tap configuration is not the variable. R6 in the
hypothesis ledger.

### EXP-007 — Audiotee CLI against Safari

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does the audiotee reference implementation
(makeusabrew/audiotee, fetched to `/tmp/audiotee`) capture real audio
on this machine? If yes, our spike has a code bug; if no, the platform
is broken.

**Variables held constant**: BT disconnected, built-in speakers as
default; Safari playing YouTube (PID 72409).

**Variables changed**: vs our spike — entirely different codebase, runs
as a CLI from Terminal (inherits Terminal's TCC).

**Method**:
```
cd /tmp/audiotee && swift build -c debug
/tmp/audiotee/.build/debug/audiotee --include-processes 72409 \
    --sample-rate 48000 --stereo > /tmp/audiotee-capture.bin \
    2>/tmp/audiotee-stderr.log &
PID=$!
sleep 5
kill -INT $PID
wait $PID
```

**Artifacts**:
- `/tmp/audiotee-capture.bin` — 883,200 bytes (4.6 s of pcm_s16le @ 48
  kHz × 2 ch)
- `/tmp/audiotee-stderr.log` — JSON-line debug stream from audiotee

**Observations**: tap created (status=0), aggregate created (status=0,
device_id=150), IOProc created and started successfully ("Audio device
started successfully"). Output file has 883,200 bytes — proving the
IOProc fired and delivered buffers — but `max-abs` across all 441,600
samples is 0. Every byte is 0x00.

**Conclusion**: audiotee's IOProc mechanically fires on macOS 26.3.
The data is silenced because audiotee (via Terminal) lacks the macOS
14.4+ "System Audio Recording Only" TCC service — Terminal has the
older combined "Screen & System Audio Recording" which doesn't cover
the tap-specific path. This is consistent with the platform's privacy
posture and not a bug in audiotee.

**Follow-ups**: this means audiotee is **not** a good direct reference
for whether our spike's IOProc *would* fire if it captured anything,
because audiotee's IOProc fires-with-silence, whereas our spike's
fires-not-at-all. Different failure modes. → Q3, Q4.

### EXP-008 — Audiotee with no process filter

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does removing the `--include-processes` filter (capture
all processes) change the result?

**Variables held constant**: same as EXP-007.
**Variables changed**: `--include-processes 72409` removed.

**Observations**: identical — 883,200 bytes, all zeros.

**Conclusion**: TCC silencing is service-wide, not per-process. The
silencing is not target-selective.

### EXP-009 — Audiotee against Spotify, BT disconnected

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does switching the audio source from Safari to Spotify,
and disconnecting BT entirely (built-in speakers), change the result?

**Variables held constant**: audiotee binary, sample rate, channels.
**Variables changed**: source process = Spotify (PID 11148); BT
disconnected; Spotify confirmed playing.

**Observations**: identical — 883,200 bytes, all zeros.

**Conclusion**: BT state is not the variable; source process is not the
variable; system default output device is not the variable. The TCC
silencing is global to the audiotee binary on this machine. R5
confirmed at the system level.

### EXP-010 — CDHash stability across same-source rebuild

**Date**: 2026-05-25 (current session)
**Author**: current session
**Question**: Does `swift build` + `codesign --force --sign 'LOCAL_SIGNING_IDENTITY'`
produce a stable CDHash when source is unchanged, or does the hash
drift between builds (which would explain TCC re-prompting)?

**Variables held constant**: all source unchanged between builds.
**Variables changed**: invoked `./Build/bundle-dev.sh` twice.

**Method**:
```
codesign -dv --verbose=4 Build/tap-n-filter.app | grep CDHash
./Build/bundle-dev.sh
codesign -dv --verbose=4 Build/tap-n-filter.app | grep CDHash
```

**Observations**: CDHash before and after are identical:
`8300e352289df015fd9b3567d418b95daff102a5`.

**Conclusion**: same source → same Swift output → same codesign hash.
TCC will not see a "different app" between rebuilds *unless* source
actually changed. Re-prompts during this session were rebuild-driven.

### EXP-011 — Launch unchanged binary, observe TCC re-prompt

**Date**: 2026-05-25 (current session, reported by user)
**Author**: user
**Question**: With the existing TCC grant in place and the binary
unchanged since the last grant, does macOS re-prompt on launch?

**Variables held constant**: same binary, no rebuild, no signing change.
**Variables changed**: app process restarted.

**Method**: user closed tap-n-filter.app and re-opened it via Finder
(`open Build/tap-n-filter.app`).

**Observations**: user reports: "it didn't this time" (no permission
prompt).

**Conclusion**: LOCAL_SIGNING_IDENTITY's self-signed cert is sufficient to persist
TCC grants on macOS 26.3 for unchanged binaries. We do **not** need a
paid Apple Developer Program membership. The frequent re-prompts in
this session are rebuild-driven; minimizing rebuilds (or batching them)
will minimize prompts. R2 confirmed.

### EXP-012 — Production capture log analysis: -10851 every Start

**Date**: 2026-05-25 06:25 EDT (analysis), referencing logs from
04:44 EDT onward
**Author**: current session
**Question**: When the user pressed the regular Start button (not the
spike) on built-in speakers and reported "nothing happens", what
actually happened internally?

**Variables held constant**: tap-n-filter.app (current build), TCC
granted, source = Safari.
**Variables changed**: pressing the regular Start button instead of the
HFP spike Start.

**Method**: scanned `~/Library/Logs/tap-n-filter/app.log` for every
`captureState` transition since the user first started reporting issues
this session (04:44 EDT).

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` — every entry
matching `lastError|fail|capture\.start|captureState|powerOn`.

**Observations**: every single production-Start since 04:44 EDT logs:
```
[WARNING] AppViewModel: lastError set: Engine configuration failed:
  Failed to set output device: -10851
[INFO] AppViewModel: captureState: idle -> starting
[INFO] AppViewModel: captureState: starting ->
  failed(Capture.CaptureError.engineConfigurationFailed(
    "Failed to set output device: -10851"))
[WARNING] AppViewModel: AVAudioEngineConfigurationChange fired:
  engine.isRunning=false, inputNode=48000.0 Hz x 2 ch,
  outputNode=0.0 Hz x 0 ch
```
Occurrences observed (incomplete list): 04:44:38, 04:50:44, 04:50:47,
05:14:45, 05:14:50, 09:50:27, 10:28:40 EDT — every regular Start the
user pressed in this session has failed.

The error originates in `RealCoreAudioInterface.setOutputUnitDevice` at
[Sources/Capture/CoreAudioInterface.swift:368](../../Sources/Capture/CoreAudioInterface.swift#L368):
```
let status = AudioUnitSetProperty(
    outputUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &mutableDeviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
guard status == noErr else {
    throw CaptureError.engineConfigurationFailed(
        "Failed to set output device: \(status)")
}
```
Called from
[Sources/Capture/CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210)
as `try coreAudio.pinEngineOutputToDefault(engine)`.

Per the AudioUnit documentation and the Codex investigation (EXP-001),
`AVAudioEngine.outputNode.audioUnit` is a `kAudioUnitSubType_DefaultOutput`
audio unit, which does **not** accept the `kAudioOutputUnitProperty_-
CurrentDevice` property. Only `kAudioUnitSubType_HALOutput` does. The
status code -10851 is `kAudioUnitErr_InvalidPropertyValue` — exactly
the documented response for setting an unsupported property.

**Conclusion**: this is the upstream bug. Production capture has been
failing immediately on every Start since `pinEngineOutputToDefault` was
added. The user's perception that "production produces low-pass audio
on BT" was a confound: capture failed in step 5, but step 3 had already
flipped BT into HFP via `configureEngineInput` before the crash. What
the user heard was Safari's *own* audio output being routed through
BT-HFP — not our captured/processed audio. On built-in speakers (no
HFP path), the same crash makes no audible signal at all, which is
what the user reported.

The HFP investigation (EXP-002…EXP-009) was chasing a downstream
symptom of an upstream code bug. R1 (BT-only-issue) is now refuted by
this experiment too: production fails everywhere; the BT case just
happened to make HFP audible.

**Follow-ups**:
- **EXP-013** (pre-registered below): remove the
  `pinEngineOutputToDefault` call. Test production Start on built-in
  speakers.
- **Q4** (open): if EXP-013 confirms H1, do we also need to address H2
  (BT HFP routing)? Probably yes for v0.1 but could be deferred.

### EXP-013 — Remove `pinEngineOutputToDefault`, test production Start on speakers

**Date**: 2026-05-25 06:50 EDT (pre-registration; run pending)
**Author**: current session
**Question**: does removing the `pinEngineOutputToDefault(_:)` call
from `CaptureController.start` let production `capture.start` succeed?
And if it does, do effects actually process audible audio?
**Hypothesis under test**: H1.

**Prediction** (locked at 2026-05-25 06:50 EDT, before the run):

- **Outcome A (predicted)**: production Start no longer logs -10851;
  `captureState` reaches `running` and stays there for 5+ seconds with
  no transitions to `failed`; user reports hearing audio through the
  effect chain on built-in speakers; moving a parameter slider (e.g.
  EQ gain) produces an audible change. → **H1 strongly supported.**
  Move H1 to "verified" status. Promote H2 to the active investigation.

- **Outcome B**: production Start logs a different error from
  somewhere else in `CaptureController.start` or downstream (e.g.
  engine.start throws, a different OSStatus from `configureEngineInput`,
  etc.). `captureState` transitions to `failed`. → **H1 supported in
  the narrow sense** (the specific -10851 call was failing) but a second
  bug exists. The new error becomes the next hypothesis to chase.

- **Outcome C (inconclusive)**: production Start succeeds (no errors,
  `captureState=running`) but user hears no audio at all on speakers,
  even with Spotify playing audibly. → **H1 supported in the narrow
  sense** but the audio path has a deeper bug downstream of
  `capture.start`. Reframe: stop assuming "capture.start succeeds" =
  "audio flows." Likely next step: add a WAV dump tap on
  `engine.inputNode` to verify whether the AUHAL is actually delivering
  audio buffers.

- **Outcome D**: production Start succeeds, user hears audio on
  speakers, but effect parameter changes don't audibly affect it. →
  **H1 supported, but a separate "effects don't respond" bug exists**
  (this was hinted at earlier in the session with BT-HFP confounds and
  needs its own investigation).

**Variables held constant**:
- Source process: Safari with one YouTube tab, audio playing audibly
  OR Spotify playing audibly (user's choice).
- Default output: built-in MacBook speakers (BT disconnected to isolate
  H2 from H1).
- Signing identity: LOCAL_SIGNING_IDENTITY, cert hash unchanged.
- TCC grant for `tap-n-filter.app` ("System Audio Recording Only"):
  already granted, no rebuild between grant and test if possible.

**Variables changed**:
- `CaptureController.start`: remove the line at
  [CaptureController.swift:210](../../Sources/Capture/CaptureController.swift#L210):
  `try coreAudio.pinEngineOutputToDefault(engine)` and the associated
  comment block on lines ~202-209.
- (No changes to the `pinEngineOutputToDefault` *implementation* — it
  becomes orphaned but harmless. Leave it in for now; remove in a
  follow-up cleanup commit so the diff stays minimal for this experi-
  ment.)

**Auxiliaries held** (what we're trusting *not* to be the cause):
- `createTap`, `createAggregateDevice`, and `configureEngineInput`
  succeed on built-in speakers (no prior evidence they fail there).
- The current engine + graph wiring (`Graph.attach(...)` etc.) is
  correct and would propagate captured audio through the effect chain
  to `mainMixerNode`.
- AVAudioEngine's `mainMixerNode → outputNode` implicit connection
  handles format conversion correctly between the effect-chain working
  format and built-in speakers' hardware format (48 kHz × 2 ch).
- No state leaked from prior failed `capture.start` calls (we've
  observed `AVAudioEngineConfigurationChange` firing after each failure;
  the engine resets, but we're trusting no other state lingers).
- The user is actually playing audio audibly during the test (volume
  on, audio reaching the system mixer).

**Method**:
1. Edit `Sources/Capture/CaptureController.swift` to remove the line
   `try coreAudio.pinEngineOutputToDefault(engine)` (currently line 210).
2. `./Build/bundle-dev.sh` to rebuild (will produce a new CDHash and
   likely re-prompt for TCC).
3. User: open `Build/tap-n-filter.app`, grant the re-prompt if any,
   select Safari (or whichever source is playing) in the source picker,
   confirm BT is disconnected and built-in speakers are the default
   output.
4. With Safari/Spotify playing audibly, press production Start.
5. Observe `~/Library/Logs/tap-n-filter/app.log` for `captureState`
   transitions and any errors.
6. If `captureState=running`, listen for whether the audio is audibly
   processed through the effect chain. Move an EQ band gain ±12 dB and
   listen for change.
7. After 30 seconds, press Stop.

**Method deviation**: user ran on BT (Bose QC connected) instead of
built-in speakers, because BT is their daily-driver setup. This blends
the H1 and H2 signals — but H1 is observable from the log regardless of
audio quality, and H2 was expected to manifest. The deviation is
acceptable; we get H2 evidence as a bonus.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries from 2026-05-25
  11:43:07.029 onward (log line 416+).
- User-reported audible result: "low-pass filter effects, same as
  before" — interpreted in light of the log as brief windows of
  HFP-degraded effect-chain output chopped up by an
  `alreadyAttached` retry loop.

**Observations** (tagged):

- [source-grounded] At 11:43:07.029 the log records `captureState:
  idle -> starting` followed immediately by `captureState: starting ->
  running(source: Safari)`. No -10851 anywhere in the post-watermark
  entries. **The specific -10851 failure mode is gone.**
- [source-grounded] At 11:43:07.398 the log records `Output hardware
  format became valid after 6 poll(s): 44100.0 Hz × 2 ch` — the engine
  successfully reached a steady output format at A2DP rates.
- [source-grounded] At 11:43:07.597 the log records `powerOn complete:
  engine started, capture running on Safari, chain: tnf.eq ->
  tnf.reverb`. **First successful `powerOn` on this branch ever.**
- [source-grounded] ~700 ms later at 11:43:07.735, the log records an
  `AVAudioEngineConfigurationChange` with `outputNode=16000.0 Hz × 1
  ch` — BT switched to HFP, exactly as H2 predicted. The trigger is
  presumably `configureEngineInput` binding the aggregate to
  `inputNode` shortly before.
- [source-grounded] At 11:43:07.736 the recovery code logs `engine
  stopped itself on configuration change; calling attemptReattach`;
  at 11:43:07.750 this throws `Graph.GraphError error 1
  (alreadyAttached)`.
- [source-grounded] After the alreadyAttached failure, captureState
  cycles `running → stopping → idle → starting → running → stopping
  → idle` rapidly. The log shows 5+ such cycles in the next 8 seconds,
  each producing the same `alreadyAttached` error.
- [behavior-inferred] The user heard "low-pass filter effects, same
  as before." Inferred: each brief `running` window (~50-700 ms) the
  effect chain actually processed Safari's audio. The "low-pass"
  character is HFP downsampling. The chopped quality (which user
  didn't explicitly mention but is implied by the rapid state cycling)
  comes from the `alreadyAttached` retry loop.

**Conclusion**: outcome A (predicted) on the H1 axis — **`pinEngineOutputToDefault`
was the upstream blocker, and removing it restored `capture.start`
success.** H1 moves from "active, behavior-confirmed inferentially" to
"verified, source-grounded."

H2 is also now empirically confirmed for our environment (was previously
only inferred from Codex's report). The BT → HFP switch happens within
~700 ms of `configureEngineInput`.

A new finding (H4) emerges: the engine's reconfiguration recovery logic
(`attemptReattach` after `AVAudioEngineConfigurationChange`) is broken.
It re-attaches an already-attached graph, throwing `alreadyAttached`,
collapsing capture to idle and entering a retry loop. This bug existed
all along but was masked by the upstream -10851 — the engine never lived
long enough to receive a configuration-change event.

The pre-registration anticipated outcomes A, B, C, D but missed E (the
real one): "H1 fixed, H2 confirmed live, AND a new downstream bug
surfaces in the engine reconfiguration handler." Worth noting for
future pre-registration: include an explicit "unanticipated outcome →
reframe" branch.

**Inferential gap**: the conclusion "H1 verified, source-grounded"
rests on the log line ordering being accurate. Defensible — the
timestamps are coherent and the captureState transition trace is
plausible — but if a future test surprises us, "the log was misordered"
is a candidate auxiliary to suspect.

**Follow-ups**:
- New active hypothesis **H4** added to ledger (alreadyAttached
  re-attach loop on `AVAudioEngineConfigurationChange`). This is the
  next thing to fix — it's preventing sustained capture even on
  unfixed HFP.
- After H4 is fixed, we'll have sustained capture (degraded by HFP on
  BT, clean on speakers) and can return to H2 as the next investigation.
- **Q6** (new, open): does fixing H4 alone produce sustained, audibly
  processed audio on BT (HFP-degraded but stable), or does some further
  bug surface?
- **Q7** (new, open): what's the right `attemptReattach` logic?
  Detach-first-then-reattach? Skip when already attached? Need to read
  the existing code to decide.

### EXP-015 — Re-run HFPSpike post-H1+H4 fix

**Date**: 2026-05-25 12:09 EDT
**Author**: current session
**Question**: Was the HFPSpike's `ioProc fires=0` failure mode caused
by entanglement with broken-production-state (the H1 -10851 crash
leaving Core Audio in a bad state), or is it independent?
**Hypothesis under test**: H3 (specifically the auxiliary "spike
failure is entangled with broken production state").

**Prediction** (locked at 2026-05-25 12:09 EDT):
- **Outcome A**: spike's IOProc now fires (`ioProc fires>0`). →
  Auxiliary refuted; spike failure was entanglement-driven; we can fix
  the spike to validate H2 architecture.
- **Outcome B** (predicted given consistent prior nulls): spike's
  IOProc still doesn't fire. → Auxiliary refuted *in the other
  direction*; spike has its own real bug independent of production
  state. Move to isolated audiotee-pattern test (EXP-016).

**Method**: with the EXP-014 build running, press the HFP spike Start
button in the debug panel. Wait 5+ seconds. Press Stop. Check log
for `HFPSpike +5s: A2DP RETAINED ... ioProc fires=N`.

**Auxiliaries held**: TCC grant for tap-n-filter.app is still
active; signing didn't drift; the spike code path is unchanged from
its prior state.

**Artifacts**: `~/Library/Logs/tap-n-filter/app.log` entries between
12:09:34 and 12:09:52 EDT.

**Observations**:
- [source-grounded] At 12:09:34.731 the log records `HFPSpike: IOProc
  started. Capture flowing.`
- [source-grounded] At 12:09:35.781, 36.831, 37.881, 39.981 the log
  records the same `ioProc fires=0, frames=0` verdict the spike has
  produced in every prior run.

**Conclusion**: Outcome B — spike still fails identically. The "spike
failure was entanglement-driven" auxiliary is **refuted**. The spike
has its own real bug independent of production state. By the
post-falsificationist protocol (3+ same-null tweaks on the same
hypothesis), further spike-tweak experiments are degenerative. The
next experiment isolates the test from spike-specific code via
EXP-016.

**Follow-ups**: EXP-016 (isolated audiotee-pattern test).

### EXP-014 — Add `graph.detach()` before `attemptReattach()` in config-change observer

**Date**: 2026-05-25 12:05 EDT (pre-registration; run pending)
**Author**: current session
**Question**: Does inserting `graph.detach()` before
`self.attemptReattach()` in the `AVAudioEngineConfigurationChange`
observer stop the alreadyAttached retry loop and produce sustained
capture?

**Hypothesis under test**: H4.

**Prediction** (locked at 2026-05-25 12:05 EDT):

- **Outcome A (predicted)**: log no longer shows `alreadyAttached`
  after `configChangeObserver` fires. captureState reaches `running`
  and stays there for sustained durations (30+ s) even as BT
  reconfigures. User reports continuous audible audio (HFP-degraded on
  BT, but continuous, not chopped). EQ slider changes are audibly
  smooth (no glitching from retry cycles). → **H4 verified.**

- **Outcome B**: log no longer shows `alreadyAttached` but shows a
  different error from `attemptReattach()` (e.g., engine.start failure,
  format mismatch). captureState collapses to idle. → **H4 supported
  in narrow sense** (the specific bug is fixed) but
  `attemptReattach()` has further bugs. New hypothesis from the error.

- **Outcome C**: log shows no errors, captureState=running and stable,
  but user reports no audible audio. → H4 fix didn't introduce audio
  but didn't kill anything either; some other audio-path bug. Reframe.

- **Outcome D**: same `alreadyAttached` error appears. → The
  source-grounded reasoning ("detach-then-attach is the missing step")
  is wrong; auxiliary "calling `graph.detach()` actually makes
  `attachedEngine` go nil" failed. Re-read `Graph.detach()` code.

**Variables held constant**:
- Source process: Safari with YouTube playing
- Default output: BT (Bose QC) — same as EXP-013
- All other code unchanged from post-EXP-013 state
- Signing identity: LOCAL_SIGNING_IDENTITY

**Variables changed**:
- `AppViewModel.swift:325-329`: insert `self.graph.detach()` between
  the `engineIsRunning = false` assignment and the
  `attemptReattach()` call.

**Auxiliaries held**:
- `Graph.detach()` is idempotent and safe to call when the engine is
  stopped (per the existing `mutateGraph` and `installPreset` usage —
  source-grounded).
- The `AVAudioEngineConfigurationChange` event fires reliably when BT
  switches profile (source-grounded; logs show it firing at
  11:43:07.114 and 11:43:07.735 in EXP-013).
- After the detach + re-attach, `engine.start()` will succeed
  (behavior-inferred; we haven't tested this code path until now).

**Method**:
1. Edit `Sources/ViewModel/AppViewModel.swift`: add
   `self.graph.detach()` and an updated comment in the configuration-
   change observer block.
2. Update the comment at lines 322-324 to reflect actual behavior
   (the chain attachment is *not* preserved across reconfigurations;
   we must detach and re-attach).
3. `./Build/bundle-dev.sh` to rebuild.
4. User: launch app, grant TCC re-prompt, BT connected (Bose QC),
   Safari playing YouTube.
5. Press production Start. Listen for 30+ seconds.
6. Move EQ band gain slider; listen for smooth, continuous changes
   (no chopped audio from retry loop).
7. Press Stop. Capture watermark for log extraction.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-016 — Isolated audiotee-pattern test inside tap-n-filter.app

**Date**: 2026-05-25 12:30 EDT (pre-registration; run pending)
**Author**: current session
**Question**: Does direct IOProc on a tap-only aggregate fire and
deliver non-zero audio inside `tap-n-filter.app` (which has the
"System Audio Recording Only" TCC grant) when set up with audiotee's
exact pattern (empty tap list at aggregate creation, then post-set
via `AudioObjectSetPropertyData`)?

**Hypothesis under test**: H3, but with all spike-specific code
(engine, ring buffer, source node, render thread) removed. The test
isolates the question to: setup → IOProc → audio data, nothing more.

**Prediction** (locked at 2026-05-25 12:30 EDT):

- **Outcome A**: ioProc fires>0 with non-zero samples. → The
  direct-IOProc-on-tap architecture works in our app. HFPSpike's
  `ioProc fires=0` failure is a Swift-specific bug we can find later;
  meanwhile we have empirical proof to start the production refactor
  toward the IOProc + AVAudioSourceNode pattern that should avoid
  HFP. (H2 path validated.)

- **Outcome B**: ioProc fires>0 with ALL-ZERO samples. → Same failure
  mode audiotee CLI exhibited from Terminal (EXP-007/008/009). Our
  app's TCC grant for "System Audio Recording Only" isn't actually
  enough; the granular TCC story is more complex. Need to dig into
  per-binary entitlements or what audiocap does differently. H2 path
  blocked on a TCC question we don't have answers for.

- **Outcome C**: ioProc fires=0. → Same failure mode as HFPSpike but
  with all extraneous code stripped out. macOS 26.3 + tap aggregate
  + direct IOProc may simply not work on this host regardless of code.
  H2 path effectively dead via this approach; would need a completely
  different architecture (e.g., custom HALOutput AU, or accept HFP
  for v0.1).

- **Outcome D (unanticipated)**: setup throws (tap creation, aggregate
  creation, post-set, IOProc creation, or AudioDeviceStart). → New
  hypothesis from the specific OSStatus. The pre-registration's
  Outcomes A/B/C all assume setup succeeds.

**Variables held constant**:
- Same TCC grant, same LOCAL_SIGNING_IDENTITY cert, same source process (Safari
  72409), same BT (Bose QC connected).
- All production code unchanged from post-EXP-014 state.

**Variables changed**:
- New file `Sources/ViewModel/AudioteePatternTest.swift` (~280 LOC)
  that creates a tap + aggregate + IOProc using audiotee's exact
  setup pattern (empty tap list at aggregate creation, post-set via
  `AudioObjectSetPropertyData`), with no engine, no ring buffer, no
  source node. Counters tally callbacks, total bytes, non-zero
  samples, and max absolute sample value. Runs for 5s then logs the
  result and tears down.
- New `runAudioteeTest()` method on `AppViewModel`.
- New "Audiotee test" row in `DebugPanel` with a "Run 5s" button.

**Auxiliaries held**:
- The new test's setup correctly mirrors audiotee's (no transcription
  bugs). Spot-checked against
  `/tmp/audiotee/Sources/AudioTeeCore/Core/AudioTapManager.swift`.
- The CTapDescription `stereoMixdownOfProcesses:` initializer behaves
  equivalently to audiotee's `description.processes = [...]` pattern
  for our purposes (audiotee's pattern doesn't compile against the
  current SDK; this is the closest equivalent).
- The C function pointer IOProc and its `Unmanaged.fromOpaque` access
  pattern are correctly synchronized via `OSAllocatedUnfairLock`. No
  data race between IOProc thread and main.

**Method**:
1. With the EXP-016 build installed and TCC re-granted, select Safari
   in the source picker. Have Safari playing audible audio (YouTube).
2. Open debug panel, press the new "Audiotee test → Run 5s" button.
3. Wait 5-6 seconds for the test to complete; "running…" indicator
   will switch back to "Run 5s".
4. Read `~/Library/Logs/tap-n-filter/app.log` for the
   `AudioteePatternTest RESULT:` line.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-017 — Switch isolated test's aggregate setup to HFPSpike's pattern

**Date**: 2026-05-25 (pre-registration; run pending)
**Author**: current session
**Question**: With everything else stripped (no engine, no ring
buffer, no source node), does HFPSpike's *aggregate setup pattern*
(embedded tap list at creation + `kAudioAggregateDeviceTapAutoStartKey:
true`) avoid both failure modes seen so far? — i.e., does
`AudioDeviceStart` succeed AND the IOProc fire with non-zero audio?

**Hypothesis under test**: H3 (the spike's IOProc-no-fire bug), refined.
Specifically: is the bug in the spike's *setup* (tap + aggregate
description) or in its *engine integration* (AVAudioEngine,
AVAudioSourceNode, ring buffer)?

**Why this is the decision point**:
- EXP-013, EXP-014, EXP-016 produced two distinct failure modes:
  HFPSpike (`AudioDeviceStart`=0, then `ioProc fires=0`) and
  AudioteePatternTest (`AudioDeviceStart` returns 'nope').
- EXP-017 takes HFPSpike's aggregate setup and runs it in the minimal
  harness (no engine code). The outcome cleanly disambiguates.
- Per the protocol, this is also the natural stopping point. Three
  outcomes have already failed; a fourth same-null is degenerative.
  Treat EXP-017 as the last try before deciding to accept HFP for
  v0.1.

**Prediction** (locked before the run):

- **Outcome A**: `AudioDeviceStart`=0 AND ioProc fires>0 with non-zero
  samples. → HFPSpike's setup pattern is fine; its no-fire bug is in
  the engine integration. We can either (a) fix HFPSpike's engine
  integration, or (b) refactor production directly using this proven
  setup pattern + a direct ring-buffer-to-output path.
- **Outcome B**: `AudioDeviceStart`=0 AND ioProc fires>0 with all-zero
  samples. → Same TCC silencing we saw from Terminal-launched
  audiotee. Our app's TCC grant isn't enough. H2 architecture path
  blocked.
- **Outcome C**: `AudioDeviceStart`=0 AND ioProc never fires. → Setup
  is fine in isolation; engine code in HFPSpike isn't the cause
  either. Bug is somewhere deeper, possibly platform-level. H2
  architecture path effectively dead.
- **Outcome D**: `AudioDeviceStart` returns non-zero (e.g. 'nope'
  again). → HFPSpike's setup ALSO doesn't work in this harness, which
  contradicts its current behavior (`AudioDeviceStart`=0 in EXP-015).
  Implies some state difference between harnesses; new investigation
  needed.

**Variables held constant**:
- Same test harness (no engine, ring buffer, source node).
- Same source (Safari 72409).
- Same TCC grant, signing identity, build environment.

**Variables changed**:
- Aggregate creation dict in `AudioteePatternTest.setup`:
  - Add: `kAudioAggregateDeviceTapAutoStartKey: true`
  - Add: `kAudioAggregateDeviceTapListKey: [...]` embedded (with
    `kAudioSubTapDriftCompensationKey: true` and the tap UID)
  - Remove: `kAudioAggregateDeviceSubDeviceListKey: []`
  - Remove: `kAudioAggregateDeviceMasterSubDeviceKey: 0`
  - Remove: the post-creation `AudioObjectSetPropertyData` call for
    `kAudioAggregateDevicePropertyTapList`.
- (Everything else — tap creation, IOProc registration, counter
  logic, runtime — unchanged from EXP-016.)

**Auxiliaries held**:
- HFPSpike's aggregate setup truly does `AudioDeviceStart=0` reliably
  on our environment (source-grounded from EXP-003 et al. logs).
- The harness change is purely additive (no other variables sneak in).

**Method**:
1. Edit `AudioteePatternTest.setup` to apply the variable changes
   above.
2. `./Build/bundle-dev.sh`.
3. User relaunches the app, grants TCC re-prompt, picks Safari with
   audible audio.
4. User opens debug panel, presses "Audiotee test → Run 5s".
5. After 6s, read the log for the
   `AudioteePatternTest RESULT:` line.

**Decision rule based on outcome**:
- A → proceed with HFP architectural fix in production.
- B → escalate to TCC investigation (separate effort) or accept HFP.
- C → accept HFP for v0.1; document; close H2 / H3 as ruled-out for
  this version.
- D → one more diagnostic round to find what's different between
  harnesses, then re-decide.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-018 — System-level HFP disable via `defaults write`

**Date**: 2026-05-25 14:30 EDT (pre-registration; run pending)
**Author**: current session
**Question**: With HFP system-disabled at the OS level, does
production capture deliver clean, full-bandwidth, effects-responsive
audio through BT headphones?

**Hypothesis under test**: H2 (BT HFP is the *only* remaining issue
after H1/H4 fixes). Equivalently: re-verifies that capture itself is
working end-to-end and that effects propagate audibly when HFP is out
of the picture.

**Prediction** (locked at 2026-05-25 14:30 EDT):

- **Outcome A (predicted)**: With HFP disabled, production audio plays
  cleanly through BT at full A2DP rates. Effect slider changes are
  audibly responsive. → H2 is the only remaining issue. The
  architectural fix has high value: implementing it cleanly would
  unlock full-fidelity BT capture. The macOS 26 zero-buffer bug is
  either not affecting our short capture sessions or is masked.

- **Outcome B**: With HFP disabled, audio is still degraded (low-pass
  or distorted character). → A separate quality issue, possibly the
  macOS 26 zero-buffer bug affecting our app too, or some other
  audio-path bug downstream of capture.

- **Outcome C**: With HFP disabled, capture works but BT operates in
  some weird third state (mono A2DP, or codec downgrade, or
  intermittent silence). → BT's profile model is more complex than
  binary A2DP/HFP; we have more to learn.

- **Outcome D**: The `defaults write` doesn't actually disable HFP on
  macOS 26.3 (BT still flips to 16 kHz mono when capture starts). →
  The workaround is folklore from older macOS versions; no actionable
  signal. Revert and consider EXP-017 again or accept HFP.

**Variables held constant**:
- Production build (post-EXP-014, with H1 and H4 fixed).
- BT (Bose QC) connected and used as default output.
- Source process: Safari with audible YouTube audio.

**Variables changed**:
- `sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP"
  -bool true`
- BT headphones disconnected and reconnected (force profile
  renegotiation under the new setting).

**Auxiliaries held**:
- The `defaults write` workaround as documented (in search results) is
  actually effective on macOS 26.3. (NOT verified; this is itself
  partially what EXP-018 tests via Outcome D.)
- BT reconnect after the `defaults write` is sufficient to re-
  negotiate without restarting `coreaudiod` or rebooting.
- Other audio-path code (the effect chain itself) is correct and would
  produce audible parameter responses on a non-HFP signal.

**Method**:
1. With BT connected (Bose QC) and Safari playing YouTube, take a
   pre-test snapshot:
   ```bash
   defaults read com.apple.BluetoothAudioAgent 2>/dev/null \
       | tee /tmp/exp-018-pre.txt
   ```
2. Apply the workaround:
   ```bash
   sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" \
       -bool true
   ```
3. Disconnect BT (Control Center or BT menu → disconnect).
4. Reconnect BT (Control Center or BT menu → reconnect).
5. Confirm BT is in A2DP via:
   ```bash
   system_profiler SPBluetoothDataType 2>/dev/null \
       | grep -A20 "Bose QuietComfort"
   ```
   The output should show A2DP-capable (high-quality) parameters; the
   absence of an HFP "Service" line would be ideal but isn't strictly
   required.
6. Open tap-n-filter, press production Start with Safari selected.
7. Listen for ~30 s. Move EQ band gain ±12 dB; reverb wet/dry from 0
   to 1. Note whether parameter changes are audibly distinguishable.
8. Press Stop. Confirm captureState transitions cleanly in the log.
9. Revert the workaround:
   ```bash
   sudo defaults delete com.apple.BluetoothAudioAgent "Disable HFP"
   ```
   Then reconnect BT again so it's back to normal HFP-capable state
   for normal use.

**Artifacts** (to be filled in after the run):
- `/tmp/exp-018-pre.txt` — pre-workaround `defaults` snapshot.
- `~/Library/Logs/tap-n-filter/app.log` — captureState transitions
  and configuration-change events during the test window.
- User-reported audio quality and effect responsiveness.

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-019 — Diagnose H6 (outputNode-stuck-at-zero on speakers)

**Date**: 2026-05-26 (pre-registration; run pending)
**Author**: current session
**Question**: Why does `engine.outputNode.outputFormat(forBus: 0)`
report `0 Hz × 0 ch` indefinitely on built-in speakers after
`configureEngineInput` binds the tap aggregate to inputNode? And:
does `engine.reset()` between failure and a retry-poll force the
output AUHAL to rebind?

**Hypothesis under test**: H6.

**Time budget**: 45-60 min. If unresolved, document deepest state
reached and move on. Do NOT extend without a new pre-registration.

**Prediction** (locked before run):

- **Outcome A**: outputNode.audioUnit's `CurrentDevice` is in fact
  the system default (built-in speakers), but `outputFormat` reports
  0 anyway → the issue is in the AVAudioEngine API layer, not the
  audio unit binding. `outputFormat(forBus: 0)` is unreliable for our
  poll. Workaround candidate: read `outputNode.audioUnit`'s stream
  format directly.

- **Outcome B**: outputNode.audioUnit's `CurrentDevice` is the
  aggregate device (the same one inputNode was just pointed at) → the
  binding got "stolen" by configureEngineInput. The DefaultOutput AU
  is supposed to track system default but isn't. Fix candidate:
  switch outputNode to a HALOutput AU we can pin explicitly, or
  explicitly trigger the rebind.

- **Outcome C**: outputNode.audioUnit's `CurrentDevice` is some
  zero/unknown value, and `engine.reset()` makes it valid → fix
  candidate: call engine.reset() after configureEngineInput in
  production. One-line fix.

- **Outcome D**: outputNode.audioUnit refuses to read its
  `CurrentDevice` (DefaultOutput refuses reads as well as writes) →
  we can't introspect; pivot to other angles or accept H6 unresolved.

- **Outcome E**: engine.reset() makes outputFormat valid → fix path
  found.

- **Outcome F**: Both the diagnostic and the reset fail; outputNode
  refuses to bind. → H6 is deeper than the diagnostic tools reach;
  defer to a separate session with more invasive instrumentation.

**Variables held constant**:
- Built-in speakers as default (BT off).
- Source: Safari Graphics and Media with audible YouTube.
- Post-EXP-014 / post-prepare-before-wait codebase.

**Variables changed**:
- Add diagnostic logging in `AppViewModel.powerOn`:
  - After `configureEngineInput`: log
    `outputNode.audioUnit.CurrentDevice` (as both ID and resolved
    device name)
  - After `engine.prepare()`: log the same plus `outputNode.audioUnit`'s
    stream format at output scope element 0
  - Inside the wait loop on each diagnostic log line: also log
    `outputNode.audioUnit.CurrentDevice`
- Add `engine.reset()` recovery in the wait-failure path: when the
  poll times out, log "trying engine.reset() recovery", call
  `engine.reset()`, re-read `outputFormat(forBus: 0)` and the audio
  unit's `CurrentDevice`, log results. Then fail as before (we don't
  retry the start sequence; we just observe whether reset fixed the
  binding).

**Auxiliaries held**:
- `outputNode.audioUnit` is accessible and non-nil (verified by prior
  `setOutputUnitDevice` usage that succeeded in getting the AU before
  failing on the property set).
- `AudioUnitGetProperty` for `kAudioOutputUnitProperty_CurrentDevice`
  and `kAudioUnitProperty_StreamFormat` returns useful data on
  DefaultOutput. NOT VERIFIED — DefaultOutput refused the SET; reads
  may also be refused. Outcome D explicitly covers this.

**Method**:
1. Apply diagnostic + reset-recovery code changes.
2. `./Build/bundle-dev.sh`.
3. User: quit/relaunch app, grant TCC re-prompt, pick "Safari
   Graphics and Media", with audible YouTube playing through speakers.
4. Press production Start. Wait the full 5s (will fail again per H6
   prediction; the point is the diagnostic data).
5. Read `~/Library/Logs/tap-n-filter/app.log` for the new diagnostic
   lines. Decide next step per Outcome A-F.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` 2026-05-26 23:41:15 → 23:41:20.

**Observations** (tagged):
- [source-grounded] At 23:41:15.339 `EXP-019 AU diag [post-capture.-
  start, pre-prepare]: CurrentDevice=143 "tap-n-filter for Safari
  Graphics and Media" (getStatus=0); HWFormat=0.0 Hz × 0 ch
  (getStatus=0); EngineFormat=44100.0 Hz × 2 ch (getStatus=0)`. The
  aggregate device id is 143; its name was set by
  `CoreAudioInterface.createAggregateDevice` per source name pattern.
- [source-grounded] Same AU state at `post-prepare` and at
  `post-wait-timeout, pre-reset` — `engine.prepare()` did not change
  CurrentDevice, and the wait timeout's diagnostic shows the AU has
  been in this state the whole time.
- [source-grounded] After `engine.reset()`: CurrentDevice=143 still,
  outputFormat=0 Hz × 0 ch still. Reset did not rebind the AU.
- [source-grounded] `AudioUnitGetProperty` returned 0 (noErr) for all
  three reads (CurrentDevice, output-scope StreamFormat, input-scope
  StreamFormat). The AU accepts introspection — it is not a pure
  DefaultOutput unit refusing all property access.

**Conclusion**: Outcome B confirmed. `configureEngineInput`'s set of
`kAudioOutputUnitProperty_CurrentDevice` on inputNode's AUHAL has the
side effect of also setting outputNode's AU to the same device.
AVAudioEngine on macOS 26.3 appears to share device state between
input and output AUHALs in a way that wasn't true (or didn't cause
visible problems) in earlier versions. On Bluetooth, system audio
routing apparently re-routed output to the BT device somehow despite
this shared binding (still don't understand the mechanism — possibly
the BT subsystem provides a "fallback" path that built-in speakers
don't get).

Reset doesn't help (Outcome C/E refuted). Introspection works (Outcome
D refuted). The remaining workable fix candidate is the same one
EXP-012 attempted via `pinEngineOutputToDefault`: explicitly set
outputNode's `CurrentDevice` to the actual system default output
*after* `configureEngineInput` has done its damage. The earlier -10851
failure may have been transient or environment-dependent. Test in
EXP-020.

**Follow-ups**: EXP-020 (explicit re-bind after prepare). Time budget
remaining: ~25 min as of this entry.

### EXP-020 — Explicit re-bind of outputNode.audioUnit to system default after prepare (DEFERS H6)

**Outcome**: B (with a twist) — H6 deferred at time budget.

**Date**: 2026-05-26 (pre-registration; run pending)
**Author**: current session
**Question**: Does setting
`kAudioOutputUnitProperty_CurrentDevice` on `engine.outputNode.audioUnit`
to the system default output device (after `configureEngineInput` has
stolen the binding) re-bind outputNode and let the wait loop succeed?

**Hypothesis under test**: H6 fix candidate.

**Prediction** (locked before run):

- **Outcome A**: `AudioUnitSetProperty` returns noErr,
  outputFormat(forBus: 0) reports valid format after the SET,
  engine.start succeeds, audio reaches the chain and the user hears
  processed audio. → **H6 resolved, one-line production fix found.**
- **Outcome B**: `AudioUnitSetProperty` returns -10851 (same as
  EXP-012's original failure). → The previous theory ("DefaultOutput
  refuses SET") is correct after all; we'd need a different approach
  (switching outputNode to an explicitly-created HALOutput AU, which
  is invasive). H6 deferred.
- **Outcome C**: SET returns noErr but the wait still times out
  (CurrentDevice doesn't actually change in observable behavior).
  → AVAudioEngine is overriding our SET. H6 deferred.
- **Outcome D**: SET succeeds, outputFormat becomes valid, engine.start
  succeeds, but audio is silent. → Different downstream bug; new
  hypothesis.

**Variables held constant**:
- Same source (Safari Graphics and Media), same BT-off + built-in
  speakers default, same post-EXP-019 codebase.

**Variables changed**:
- After `engine.prepare()` in `AppViewModel.powerOn`, before the wait
  loop, insert:
  - Read system default output device via
    `kAudioHardwarePropertyDefaultOutputDevice`.
  - Set it as outputNode.audioUnit's CurrentDevice.
  - Log the SET status and the post-SET AU state.

**Auxiliaries held**:
- The system default output device is built-in MacBook Air Speakers
  (verified by `system_profiler` earlier in the session).
- The SET operation if successful actually rebinds the AU (vs being
  silently ignored or queued).

**Method**:
1. Apply the code change.
2. `./Build/bundle-dev.sh`.
3. User quits/relaunches, grants TCC re-prompt, picks Safari Graphics
   and Media (with audible YouTube), presses production Start.
4. Read the log: look for "EXP-020 SET CurrentDevice" line and the
   resulting wait outcome.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` 2026-05-27 05:57:31 →
  05:57:36.

**Observations** (tagged):
- [source-grounded] At 05:57:31.274 `EXP-020 rebind: SET
  outputNode.CurrentDevice to defaultOutput=98: status=-10851`.
  Default output device id 98 (presumably MacBook Air Speakers,
  confirmed by earlier `system_profiler` output). SET returned
  `kAudioUnitErr_InvalidPropertyValue` (-10851) — same refusal
  EXP-012 saw originally.
- [source-grounded] Immediately after the failed SET:
  `CurrentDevice=0 "(unresolved)"`. The failed SET invalidated the
  prior binding (was 147 / aggregate). Outcome: AU now in a worse
  state than before our attempt — bound to nothing.
- [source-grounded] `CurrentDevice=0` persists through wait loop,
  through `engine.reset()`, into the cleanup. Nothing recovers the
  binding within this code path.

**Conclusion**: Outcome B with an additional finding (failed SET is
not idempotent — it nukes the existing binding). H6 cannot be fixed
via `AudioUnitSetProperty(CurrentDevice)`. Remaining fix candidates
require deeper architectural change:
- Replace `engine.outputNode` with a custom `kAudioUnitSubType_-
  HALOutput` AU that we own and can pin explicitly.
- Or restructure capture entirely (Codex's direct-IOProc-+-
  AVAudioSourceNode architecture, which is also what HFPSpike was
  meant to validate).
- Or accept built-in speakers as broken for capture in v0.1.

Both serious-fix candidates are out-of-scope for this session's
remaining time. **H6 marked deferred.** Time budget hit (cumulative
~75 min on H6 across EXP-019 and EXP-020).

**Auxiliaries challenged**:
- "DefaultOutput refuses CurrentDevice SET" theory (originally
  R-something from EXP-012) is now back to active — but with a new
  observation that the SET also invalidates existing state.

**Follow-ups**:
- Revert the EXP-020 SET call from production code so BT path
  doesn't regress (the SET would also invalidate BT's binding if
  called there).
- Move to **BT reverb extreme-sweep test** (Path 1 disambiguator) —
  pre-registered as EXP-021 below.
- Track H6 as deferred-active. Future session: read AudioCap and
  WWDC 2023 session 10208 transcript for whether Apple documents
  this output-binding-stolen behavior, and prototype HALOutput
  replacement for outputNode.

### EXP-023 — Confirm input/output AU identity

**Date**: 2026-05-27 06:11 EDT
**Author**: current session
**Question**: Are `engine.inputNode.audioUnit` and
`engine.outputNode.audioUnit` the same `AudioUnit` instance?

**Outcome**: **YES, confirmed** — both report pointer
`0x00000000926600bf`, same=true, both subtype `'ahal'` (HALOutput).

**Observations** (tagged):
- [source-grounded] `EXP-023 AU identity [pre-capture.start]:
  inputAU=0x00000000926600bf, outputAU=0x00000000926600bf, same=true`
- [source-grounded] `EXP-023 input AU subtype [pre-capture.start]:
  type='auou' subtype='ahal' manufacturer='appl' (getStatus=0)`
- [source-grounded] **Second finding**: capture.start failed with -10851
  even without the EXP-022 pre-capture SET. The mere READ in
  `logInputAndOutputAUIdentity` is sufficient to put the unified IO
  AU into a state where `configureEngineInput`'s SET is rejected.
- [source-grounded] (Same finding inferred from EXP-022: pre-capture
  logOutputAudioUnitState + SET attempt broke capture.start. The SET
  wasn't the load-bearing trigger; the access was.)

**Conclusion**: **H6 root cause is now mechanically characterized.**
On macOS 26.3 (and possibly earlier 26.x), `AVAudioEngine.inputNode.-
audioUnit` and `AVAudioEngine.outputNode.audioUnit` are the same
`kAudioUnitSubType_HALOutput` instance. There is exactly one
`kAudioOutputUnitProperty_CurrentDevice` value. When
`configureEngineInput` sets it to the tap aggregate, `outputNode.-
outputFormat(forBus: 0)` reports `0 Hz × 0 ch` because the aggregate
has no output streams. **The shared AU is fundamentally incompatible
with the "input = aggregate, output = some other device" topology
the v0.1 architecture assumes.** It is not a config-tweak fix.

**Bonus finding**: reading the AU before capture.start invalidates
subsequent SET attempts inside configureEngineInput. Diagnostics must
go AFTER capture.start or they break the hot path.

**Auxiliaries refuted**:
- "DefaultOutput refuses SET" theory (EXP-012 era) — outputNode is
  not DefaultOutput; it's HALOutput.
- "Input and output AUHALs are separate units" — they aren't.

**Auxiliaries surfaced**:
- The unified IO AU model in AVAudioEngine on macOS 26.3 may be a
  change from earlier macOS versions. Worth verifying against macOS
  14.x and 15.x in a future session if we can.

**Fix paths (none in-scope this session)**:
1. Direct IOProc + `AVAudioSourceNode` → output-only engine (Codex's
   original architecture; HFPSpike was meant to validate this).
2. Custom HALOutput AU we manage outside AVAudioEngine for the
   output side.
3. Two engines (one for capture's input-side wiring, one for output)
   with samples shuttled between them via ring buffer.

All require significant refactoring; deferred. H6 marked as
"deferred-active" — root cause known, fix scheduled but not done.

**Follow-ups**:
- Revert the pre-capture diagnostics (already done in code; they
  break capture.start).
- Move to EXP-021 (BT reverb extreme-sweep test) to determine
  whether the existing effect chain audibly responds at all.

### EXP-022 — Identify outputNode AU subtype + pre-capture SET attempt

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: Two questions in one experiment.
(1) What audio unit subtype is `engine.outputNode.audioUnit` actually
backed by? (`DefaultOutput`, `HALOutput`, or something else?)
(2) Does setting `CurrentDevice` BEFORE `configureEngineInput` runs
succeed? (Before the configureEngineInput-steals-binding side effect.)

**Hypothesis under test**: H6 fix candidate. Specifically:
- If outputNode.audioUnit is `DefaultOutput`, SET will fail in all
  positions; H6 requires HALOutput replacement (Option 2 from session
  notes, ~30-60 min refactor).
- If it's `HALOutput`, SET *should* work; we'd be looking at a
  different bug in why our SET fails. Pre-capture SET would isolate
  whether the failure is specifically related to configureEngineInput's
  state mutation.

**Prediction** (locked before run):

- **Outcome A (predicted most likely)**: AU subtype is
  `kAudioUnitSubType_DefaultOutput` (`'def '` / 0x64656620). Pre-
  capture SET returns -10851 same as post-capture. → DefaultOutput
  rejects SET universally. H6 fix path is HALOutput replacement
  (out-of-scope this session).
- **Outcome B**: AU subtype is `kAudioUnitSubType_HALOutput` (`'ahal'`
  / 0x6168616c). Pre-capture SET succeeds (status=0). → outputNode
  has been a HALOutput all along, but configureEngineInput steals the
  binding via some path that bypasses our explicit SET (maybe an
  internal AVAudioEngine method). Fix would be: pre-capture SET + re-
  SET after capture.start somehow. New hypothesis.
- **Outcome C**: AU subtype is HALOutput, pre-capture SET fails with
  -10851. → HALOutput but with some other restriction. Apple
  documentation incomplete. New hypothesis.
- **Outcome D**: AU subtype is something else entirely (rare,
  unexpected). → New direction.

**Variables held constant**:
- BT off, built-in speakers as default.
- Source: Safari Graphics and Media.
- Post-EXP-020-revert codebase.

**Variables changed**:
- Add `kAudioUnitProperty_ComponentDescription` read to the diagnostic
  helper (`logOutputAudioUnitState`), so each diagnostic snapshot also
  includes the AU's component type/subtype/manufacturer.
- Add a new `rebindOutputToSystemDefault()` call BEFORE `capture.start`
  (after source resolution, before engine.inputNode gets touched).
  Logs SET status. The call is identical to EXP-020's helper (which is
  still in source but no longer invoked).

**Method**:
1. Code change + build.
2. User quits/relaunches; grants TCC re-prompt; picks Safari Graphics
   and Media (with audible YouTube). Speakers as default output.
3. Press production Start.
4. Read log for:
   - `EXP-022 AU subtype: type=... subtype=... manufacturer=...`
   - `EXP-022 pre-capture SET: status=...`
   - Whether subsequent wait succeeds or fails.

**Artifacts** (to be filled in after the run):

**Observations** (to be filled in after the run):

**Conclusion** (to be filled in after the run):

**Follow-ups** (to be filled in after the run):

### EXP-021 — BT reverb extreme-sweep test (effects-respond disambiguator)

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: With production capture working on BT (HFP-degraded
audio), and the reverb wet/dry slider swept all the way from 0.0
(fully dry, no reverb) to 1.0 (fully wet, no direct signal), is the
audible difference at the extremes large enough to be unmistakable?

**Hypothesis under test**:
- Path Y ("effects actually work, HFP just masks subtle changes"):
  predicts an obvious audible difference between dry and fully-wet
  even through HFP downsampling.
- Path Z ("effects don't actually respond regardless of HFP"):
  predicts no audible difference at the extremes — slider value isn't
  reaching the AU effectively.

**Prediction**:
- **Outcome A**: Clear, dramatic difference between dry and wet at
  extremes (cathedral-vs-anechoic kind of difference) → Path Y;
  effects work. H2 (HFP) is the only barrier to good v0.1 audio.
- **Outcome B**: No discernible difference between dry and wet at
  extremes → Path Z; there's an effect-chain bug independent of HFP.
  Need to instrument the AU side of the reverb node.
- **Outcome C**: Subtle but real difference (less than expected for
  full sweep but still perceptible) → Ambiguous; HFP may be masking
  more than expected. Need a WAV dump test for definitive answer.

**Variables held constant**:
- Post-EXP-020-revert build.
- Source: Safari Graphics and Media playing YouTube.

**Variables changed**:
- BT reconnected (Bose QC); built-in speakers no longer default.
- User performs the slider sweep extremes (0.0 → 1.0), pause briefly
  at each end so they can hear sustained dry-only vs sustained
  wet-only.

**Auxiliaries held**:
- BT routes audio through capture pipeline (verified via prior EXP-013
  / EXP-014 logs showing outputNode=44.1 kHz × 2 ch transiently then
  16 kHz × 1 ch).
- The reverb `wetDryMix` setter actually pushes through to the
  AudioUnit (the slider produced 36 logged updates from a partial
  sweep in EXP-014; the setter code path executes).

**Method**:
1. Reconnect BT (Bose QC). Confirm BT is default output.
2. Quit / relaunch tap-n-filter (cleaner state).
3. Pick Safari Graphics and Media. Press production Start. Confirm
   audio is flowing (HFP-degraded but audible).
4. **Drag reverb wet/dry slider all the way to 0.0**. Hold 5 seconds.
   Listen carefully.
5. **Drag wet/dry slider all the way to 1.0**. Hold 5 seconds. Listen.
6. Sweep back and forth a few times.
7. Optionally repeat with the EQ band gain at full boost vs full cut.
8. Report what you hear.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 06:39:55 → 06:42:25
  EDT (2026-05-27). The first run is the multi-second sweep; the
  subsequent entries are repeated Start/Stop toggles by the user.

**Observations** (user-reported, with log corroboration):

- 06:39:55 powerOn complete fires; `engine.isRunning=true`,
  `inputNode=48000.0 Hz × 2 ch`, `outputNode=16000.0 Hz × 1 ch`. Engine
  is genuinely running on macOS's view of the world.
- 06:40:03-04 reverb wet/dry slider sweeps 0.5 → 0.0 → 1.0 with 21
  `updateWetDryMix:` log entries spanning ~700 ms. The setter
  hot-path is executing.
- 06:40:13 EQ `hp.frequency=58.94` push-through logged.
- 06:40:27 `removeEffect: at index 0`, `mutateGraph: wasRunning=true`,
  `detached for live mutation`, `reattaching after live mutation` —
  but **no log line for "reattach complete"**. The next mutateGraph
  (06:40:33 addEffect) reports `wasRunning=false`, so the engine
  silently dropped sometime in the 6-second window between detach and
  next user action.
- **User-reported audio outcome (verbatim)**:
  > "all it did was cut out the audio, and stay cut out it seems, and
  > no changing of the sliders, no toggling of the effects changed
  > anything. I even tried removing the effect but I think that froze
  > the menu because I couldn't toggle again. And then I restarted,
  > and try to just toggle and see what would happen. when I press
  > start it cuts out, when I toggle it again so it 'stops' the sound
  > comes back but attenuated with the HFP or whatever like it was
  > doing before."

**Conclusion**: **None of the pre-registered outcomes A/B/C match.**
What we got is a new outcome:

- **Outcome D**: audio is **fully cut out** during capture, not
  HFP-degraded. Pressing Stop releases the cut-out and HFP aftermath
  persists briefly on the source. Sliders + toggles produce no
  audible change because there is no engine-output audio reaching the
  user.

This is a structural reframing: the prediction tree (Y vs Z) was
itself wrong — both predictions assumed engine output was audible at
some level (HFP-degraded or full quality) and asked whether moves
within it were perceptible. The actual state is that **no engine
output reaches the user at all**, while the source process is muted
by the tap (per ADR-014). User hears literal silence.

The 06:40 run accidentally surfaced *two* further bugs:
1. Live `removeEffect` while engine is running causes the engine to
   die silently (no error log, no state transition to `failed`).
2. The menubar UI freezes after that silent engine death (no toggle
   responsiveness), forcing a restart.

These are real and worth tracking but secondary to the no-audio-out
finding. → see H7 below and EXP-024 for the disambiguator.

**Follow-ups**: → H7 (NEW), → EXP-024 (mainMixerNode tap to
disambiguate "engine output is silent" vs "engine output is
discarded by the OS"). H6's "deferred-active" status escalates to
**active blocker** because Outcome D is its user-level
manifestation.

### EXP-032 — Source-node + chain format readback for H17 (rate mismatch confirmed to OBTAIN; load-bearing-ness NOT tested here — see EXP-033)

**Status**: completed (single run, speaker route).
**Date**: 2026-05-28 (15:44 EDT).
**Author**: current session.

**Question**: Does `AVAudioEngine` honor the format we pass to
`AVAudioSourceNode(format: reader.format)`, or does it silently
renegotiate the source-node's effective sample rate to match the
engine's running rate (set by the output device)?

**Hypothesis under test**: H17 — rate-mismatch portion. We declared
the source node at the tap's 48 kHz × 2 ch Float32 non-interleaved
format. If the engine reports a different `outputFormat(forBus: 0)`
on the source node at runtime, the IOProc's 48 kHz writes into the
ring buffer are being played back as if they were 44.1 kHz samples
(or whatever the engine has decided to run at). That's the
mechanism for the "voice-changer / pitched-down" symptom.

**Pre-registered outcomes**:
- H17-α (CONFIRMING for pitch portion): source-node reports a rate
  that differs from `reader.format`'s 48 kHz → engine has
  renegotiated. Mechanism source-grounded.
- H17-β (CONFIRMING for layout portion): source-node reports the
  declared rate but `commonFormat` or `isInterleaved` flips somewhere
  in the chain → channel-layout mismatch is the mechanism.
- H17-γ (REFUTING): all five readback points match the tap's declared
  format → H17 is wrong about the source-node boundary and the
  artifact must live elsewhere (e.g., in the IOProc's `AudioBufferList`
  arrangement, or downstream of the source node entirely).

**Variables held constant**: build CDHash v4 (post-EXP-031, no
behavioural changes — only added `logChainFormats` static helper in
`AppViewModel`), Safari source, speaker route (BT disconnected),
single instance launched fresh.

**Variables changed**: added `[EXP-032.format.*]` readback at end of
`powerOn` (after `engine.start()` succeeds) and end of
`reattachAfterMutation`. Five log lines per stage:
`source` (source node's `outputFormat`), `mainMixerIn`,
`mainMixerOut`, `outputIn`, `outputOut`.

**Artifacts**: production log `~/Library/Logs/tap-n-filter/app.log`,
specifically the 15:44:57 EDT block (two consecutive `powerOn`
firings, identical readback in both).

**Result** (verbatim from app.log):

```
Capture:      [EXP-029.tap.format]          sampleRate=48000.0 channels=2
AppViewModel: [EXP-032.format.source]       rate=44100.0 ch=2 common=Float32 interleaved=false
AppViewModel: [EXP-032.format.mainMixerIn]  rate=44100.0 ch=2 common=Float32 interleaved=false
AppViewModel: [EXP-032.format.mainMixerOut] rate=48000.0 ch=2 common=Float32 interleaved=false
AppViewModel: [EXP-032.format.outputIn]     rate=48000.0 ch=2 common=Float32 interleaved=false
AppViewModel: [EXP-032.format.outputOut]    rate=48000.0 ch=2 common=Float32 interleaved=false
```

Two consecutive `powerOn`s 12 s apart produced identical readback —
not a transient.

**Conclusion**: **Outcome H17-α — rate-mismatch mechanism
CONFIRMED.** The tap delivers 48 kHz Float32 non-interleaved. The
engine silently overrode the source node's declared format to
44.1 kHz to match its running rate. The mainMixer runs the entire
chain at 44.1 kHz, then SRCs to 48 kHz before the output device.
Two consequences:
1. The render callback writes 48 kHz samples per `frameCount`-worth
   of buffer time, but the engine pulls at 44.1 kHz cadence and
   interprets those samples as 44.1 kHz audio. Effective playback
   speed = 44100/48000 = 0.919x → pitched down ~1.4 semitones. This
   is the "voice-changer / anonymize" character.
2. The 44.1 → 48 SRC pass at `mainMixerNode` operates on
   already-misinterpreted samples and adds reconstruction artifacts
   ("static crackling").

**Outcome NOT covered**: the user-reported left-shift / imaging
shift. Channel layout is byte-clean (`ch=2 interleaved=false` at
every chain boundary). The left-shift either:
- is a perceptual artifact of the broken SRC that will disappear
  with the fix (most likely);
- lives in the IOProc's `AudioBufferList` arrangement, downstream
  of the format-declaration boundary;
- is a separate channel-ordering bug in the tap stream.

Parked as a residual — re-evaluate after the fix lands. If it
persists, that's its own sub-investigation (candidate: read the
IOProc's `AudioBufferList` arrangement byte-by-byte at one fire,
log channel pointers).

**Why the engine overrode our format**: `AVAudioEngine` constrains
its internal running rate to the output device's native rate (in
this run, the speaker is set to 44.1 kHz in Audio MIDI Setup). The
source-node format we pass to `AVAudioSourceNode(format:)` is
informational from the engine's perspective — the engine will
treat the node as if it produces audio at the engine rate
regardless. This is documented behaviour but not obvious. The
canonical fix is to do explicit sample-rate conversion ourselves
via `AVAudioConverter`, declaring the source node at the engine
rate and feeding it converted samples from our ring buffer.

**Follow-ups**:
- → H17 fix (in flight): `AVAudioConverter` between ring buffer
  and source node, declared source-node format = engine's running
  rate. Pre-allocate everything at start; render callback runs on
  the realtime audio thread.
- → Retest Bug A on BT after the H17 fix. The current hypothesis
  is that Bug A may have been partially explained by the rate
  mismatch (reverb's internal state diverging at the wrong rate,
  worsened by HFP downsampling). If Bug A persists post-H17,
  it's a separate animal.
- → Update notebook Status block and changelog (done in same
  edit).

---

### EXP-033 — Pin chain to tap rate (rate-mismatch intervention)

**Date**: 2026-05-28 (~15:45 EDT, rate fix; superseded a no-op
converter attempt earlier the same evening).
**Type**: intervention (fix attempt).
**Target mechanism**: H17a — the chain runs at 44.1 kHz while the tap
delivers 48 kHz, so 48 kHz samples are played at 44.1 kHz, and this
rate mismatch is the cause of the "pitched-down / voice-changer"
artifact.
**Mechanism type**: the mismatch *obtaining* is source-grounded
(EXP-032 readback). The claim that it is the *cause of the audible
artifact* is behavior-inferred — and the conflation of those two is the
error this entry records.

**Prediction** — RECONSTRUCTED post-hoc; **not pre-registered at run
time**. The absence of a locked prediction here is the process failure
documented in FC-005. Had it been written before the code, it would
have read:
- **If load-bearing**: the chain rate changes to 48 kHz
  (`[EXP-032.format.source]` shows 48000) AND the artifact resolves.
- **Risky branch**: if the rate changes to 48 kHz but the artifact
  persists, the rate mismatch is not load-bearing, and the revision
  goes to a second mismatch at the source-node boundary (channel
  layout / interleaving).

**Change**: added optional `sourceFormat:` to `Graph.attach`; the
capture path passes `reader.format` so every chain link is pinned to
the tap rate instead of the source node's 44.1 kHz default. Reverted
the no-op `AVAudioConverter` (the v1 attempt read the pre-start
`outputNode` format = 48 kHz and so converted 48→48). Added
`captureFormat` to `CaptureControllerProtocol`.

**Landed?**: yes. `[EXP-032.format.source stage=powerOn] rate=48000.0`
(was 44100.0), confirmed on two consecutive powerOns. The chain now
runs at the tap rate; `mainMixerNode` does a 48→48 (no-op) pass to the
output device.

**Resolved?**: no. User: "still pitched super low." The rate change
took effect; the artifact was unchanged.

**Conclusion**: the rate mismatch was real and is now eliminated, but
it is **not load-bearing** for the audible artifact. This refutes the
causal leap made after EXP-032 (that confirming the mismatch obtains
had confirmed it as the cause). The "did it land" diagnostic
(`[EXP-032.format.source]`) discriminated cleanly: the fix took effect,
so the failure could not be blamed on a mis-implementation or a lying
apparatus, and the revision had to land on the mechanism's salience.
The rate fix is **kept** — running the chain at the tap rate is correct
and avoids any implicit SRC at the source-node boundary — but it is not
the fix for Bug B.

**Follow-ups**: re-examine the tap format. `formatFlags=9` and
`bytesPerFrame=8` had been in the `[EXP-029.tap.format]` log since the
first instrumented run; they decode to *interleaved* stereo, while the
ring/render pipeline is planar → EXP-034.

---

### EXP-034 — De-interleave interleaved tap input (channel-layout intervention)

**Date**: 2026-05-28 (evening EDT).
**Type**: intervention (fix attempt).
**Status**: implemented + built clean; **pre-registered**; awaiting
audio verification from the user.
**Target mechanism**: H17b — the tap delivers interleaved stereo
(`[L, R, L, R, …]`, one buffer) but the ring buffer and render path are
planar (one buffer per channel). `pushIOProcSamples` wrote the
interleaved buffer as a single planar channel at `mDataByteSize / 4` =
2× the real frame count. Read back planar, that plays the content at
half speed (one octave down → "super low"), strands it in channel 0
(left-shift), and alternates L/R within a channel (crackle).
**Mechanism type**: source-grounded. Tap ASBD `formatFlags=9`
(Float|Packed, no non-interleaved bit) and `bytesPerFrame=8` (2 ch ×
4 bytes) → interleaved. The pipeline's planar assumption lives in
`AudioRingBuffer` (one buffer per channel) and
`AVAudioFormat(standardFormatWithSampleRate:channels:)`
(non-interleaved). Both read directly.

**Auxiliaries** (must hold for this fix to resolve the symptom):
- Interleaving is the dominant remaining cause of the artifact (no
  third mismatch at this boundary).
- The de-interleave indexing (`interleaved[f * channelCount + ch]`)
  matches the tap's actual L/R ordering.
- The EXP-033 rate fix stays in place, so the de-interleaved planar
  frames are played at the tap rate.

**Prediction** (locked before the audio verdict):
- **If load-bearing**: the fix lands (`[EXP-034.layout]
  interleaved=true`, de-interleave path runs) AND all four symptoms
  resolve together — pitch correct, imaging centered, no crackle, and
  perceived duration matches real time. Four consequences of one
  mechanism: the progressive, risky prediction.
- **Risky branch**: if the layout log shows `interleaved=true` (fix
  landed) but the artifact persists, interleaving is not the dominant
  cause either, and the revision goes to a third candidate at the
  boundary (the IOProc `AudioBufferList` byte arrangement, or a
  channel-ordering bug in the tap stream). Next diagnostic: read the
  raw ABL channel pointers at one IOProc fire.
- **Partial branch**: if pitch and crackle resolve but the left-shift
  remains, the frame-count error was load-bearing for pitch and the
  residual left-shift is a separate, narrower channel-routing issue —
  split it into its own hypothesis.

**Change**: `TapIOProcReader` detects interleaving from the ASBD flag at
init and allocates a realtime-safe de-interleave scratch buffer;
`pushIOProcSamples` branches. `pushInterleaved` de-interleaves
`[L, R, …]` into planar channels at the correct frame count
(`totalFloats / channelCount`) before the ring write; `pushPlanar`
keeps the prior per-channel-buffer path for non-interleaved taps.

**Landed?**: yes. `[EXP-034.layout] interleaved=true` on run; the
de-interleave path executed.

**Resolved?**: **yes.** User verdict on the speaker route: no pitch-down,
no left-spatial-shift, no crackle, and the wet/dry slider behaves
correctly (wet=0 is identical to bypass). All four pre-registered
consequences resolved together.

**Conclusion**: the "if load-bearing" branch of the locked prediction
matched in full. One mechanism (interleaved-as-planar at 2× frame
count) predicted four independent consequences — pitch, imaging,
crackle, duration — and fixing it corrected all four at once. That
joint resolution is the progressive, risky corroboration the prediction
was designed to demand; a coincidental fix would not have moved all
four. H17b is confirmed load-bearing; Bug B (capture corruption) is
resolved on the speaker route. The bonus observation (wet=0 ≡ bypass)
independently corroborates that the parallel wet/dry mixer is sound,
consistent with EXP-B1.

**Follow-ups**: (1) retest Bug A on BT — the BT-only reverb-bypass
cutout was parked pending this fix; the frame-count error may have
compounded it. (2) Add an interleaved-input unit test to
`TapIOProcReaderTests` — the bug survived because only a
non-interleaved fake was tested
(`test_ioproc_callback_pushes_samples_into_ring` uses `mNumberBuffers=2`).
(3) Consider an ADR for the capture format contract (chain runs at the
tap rate; de-interleave at the IOProc boundary).

---

### EXP-035 — Retest Bug A (reverb-bypass cutout) on BT after the Bug B fix

**Date**: 2026-05-28 (**pre-registered; awaiting run**).
**Type**: experiment (observation; no code change).
**Question**: Does toggling reverb bypass during capture still cut audio
entirely on a Bluetooth output route, now that Bug B (H17b interleaving)
is fixed?
**Hypothesis under test**: H16 / Bug A, and whether it was coupled to
Bug B.

**Prediction** (locked before the run):
- **Outcome 1 — coupled / resolved**: the cutout is gone on BT → Bug A
  was an artifact of the Bug B frame-count error (the de-interleave
  changed the source-node buffer cadence). Bug A closes; the two were
  coupled.
- **Outcome 2 — independent / persists**: the cutout still happens on BT
  (and still not on speakers) → Bug A is independent of Bug B and is the
  BT/HFP routing pathology (H15-adjacent). Goes to ADR-019 (intrinsic OS
  limitation + V0.1 ship policy).
- **Outcome 3 — changed**: the cutout is shorter or recovers differently
  → partial coupling; investigate the `AVAudioEngineConfigurationChange`
  handler's interaction with the new format path.

**Method**: connect a BT output; relaunch the app; start capture on
Safari/YouTube; first confirm audio is cleanly pitched (the Bug B fix
should hold on BT, modulo HFP 16 kHz quality); toggle reverb bypass off
then on; toggle EQ bypass as the control (EQ never cut). Grep
`[EXP-031.setBypass]`, `[EXP-031.configChange]`, `[EXP-032.format.*]`,
`[EXP-034.layout]`.

**Result / Conclusion**: **Outcome 1 — coupled / resolved.** User
verdict on BT: the cutout is gone. Toggling reverb bypass no longer
cuts audio. Bug A was an artifact of the Bug B frame-count error; the
EXP-034 de-interleave (which corrected the source-node buffer cadence)
resolved it. Bug A / H16 is **resolved, coupled to Bug B**.

Secondary observation [behavior-inferred]: the reverb is now *audible*
on BT (toggle and slider both produce a change — a state earlier
experiments could not reach because the cutout and HFP masked it), but
the effect feels "much slighter" than on the speaker route. This is
consistent with H15 (HFP): the chain processes reverb at full quality
(48 kHz), but the output is downsampled to HFP 16 kHz mono, which
strips the high-frequency reverb tail (Nyquist 8 kHz) and collapses the
stereo width the reverb depends on. Not a new bug and not attributable
to the EXP-034 fix; it is the HFP output degradation (H15), which is
the remaining capture-quality issue to address. Not independently
confirmed here — confirming would require an A/B of reverb depth on a
wired 48 kHz output versus BT HFP — but H15 is already source-grounded
and the slightness is its expected corollary.

---

### EXP-031 — Bypass toggle audio-cutout instrumentation (RAN, MULTIPLE SUB-EXPERIMENTS)

**Status**: completed (multi-build, multi-sub-experiment).
**Date**: 2026-05-28 (~03:05 EDT through ~05:28 EDT).
**Author**: current session.

**Question**: When the user toggles `setBypass` on a graph effect
node during active capture, audio cuts out (H16). What sequence
of events does the toggle trigger, and where in the chain is the
cutout introduced?

**Hypothesis under test at start**: H16 (bypass toggle breaks the
audio chain). Specifically the original framing: "interaction
between direct-IOProc-+-source-node architecture and graph mutation
or the engine-restart-on-config-change branch."

**Pre-registered outcomes**:
- **H16-A (mixer gain misapplied)**: setBypass logs show clean
  gain changes; no concurrent configChange/mutateGraph; audio
  still cuts. → AVAudioMixerNode destination-volume bug.
- **H16-B (config-change race)**: setBypass followed within ~100 ms
  by `[EXP-031.configChange]` AND/OR `[EXP-031.engineRestart]`.
- **H16-C (graph mutation triggered)**: `[EXP-031.mutateGraph.*]`
  fires during/after setBypass.
- **H16-D (no smoking gun, Heisenbug)**: clean log + no cutout.
- **H16-E (gain set but destination missing)**:
  `dryDestExists=false` after setBypass.

**Variables held constant**: BT (Bose QC) connected; Safari as
source; chain `tnf.reverb → tnf.eq` (initially).

**Variables changed across builds**:
- v1 (`a12e6f...`): added `[EXP-031.setBypass.*]`,
  `[EXP-031.wetDryMix.*]`, `[EXP-031.configChange]`,
  `[EXP-031.engineRestart]`, `[EXP-031.mutateGraph.*]`,
  `[EXP-031.reattach.*]` tags. Added
  `EffectNode.debugStateDescription()` as a protocol *extension*
  method (Swift static-dispatch bug — overrides not called).
- v2 (`fbf5d113e8...`): promoted `debugStateDescription` to a
  protocol *requirement* so concrete overrides on ReverbNode and
  EQNode dispatch dynamically. Override surfaces
  `dryDestExists`/`dryDestVol`/`dryMixerVol`/`wetDestExists`/
  `wetDestVol`/`wetMixerVol`/`attached`.
- v3 (`78daded470...`): two changes:
  (a) Removed `applyMixGains`'s fallback path that set
  `mixer.volume = dryGain` when the destination lookup returned
  nil — that fallback could leave the mixer's master volume stuck
  at 0 after a transient nil at attach time. Always keep
  `dryMixer.volume = dryMixer = 1.0` now; only modulate the
  destination volumes.
  (b) Extended `debugStateDescription` with per-mixer
  input/output formats and the wet processor's
  bypass/wetDryMix readback.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` lines 1535-1547 (v1),
  2109-2120 (v2), 2324-2341 + 2370-2382 (v3 first phase, BT route),
  2408-2419 + 2441-2479 (v3 speaker test).

#### EXP-031.A — Main bypass toggle test (v1/v2/v3, BT route)

**Method**: User on BT, capture Safari, set both nodes to
wetDryMix=1.0, toggle Reverb's bypass; then toggle EQ's bypass.

**Observations** (consolidated across builds):

| Event | Action | Audible outcome |
|---|---|---|
| Reverb bypass false→true | requested=true | **AUDIO CUTS** |
| Reverb bypass true→false | requested=false | Audio restored |
| EQ bypass false→true | requested=true | No cut |
| EQ bypass true→false | requested=false | No cut |

v3 log readback at the moment of bypass=true, BT route:
- BOTH Reverb and EQ: `dryDestExists=true dryDestVol=1.0
  dryMixerVol=1.0 wetDestExists=true wetDestVol=0.0
  wetMixerVol=1.0 attached=true`
- BOTH: every internal format reads `44100.0Hz×2ch`
- BOTH: `*AUBypass=false`
- Reverb only: `reverbUnitWetDryMix=100.0`
- NO `[EXP-031.configChange]` events near the toggle.
- NO `[EXP-031.mutateGraph.*]` events near the toggle.
- NO `[EXP-031.engineRestart]` events near the toggle.

**Outcome H16-A matches** (gain set as intended, audio still
cuts; no configChange/mutateGraph). NOT H16-B/C/D/E. With one
crucial refinement: the outcome H16-A predicted "AVAudioMixerNode
destination-volume bug" as the mechanism, but every observable
field is identical between Reverb (cuts) and EQ (works) — so the
mechanism must be something not visible to our instrumentation.

#### EXP-031.B — Chain-order swap (verifies chain position is not the discriminator)

**Date**: 2026-05-28 04:48 EDT.
**Question**: Is the cutout chain-position-specific
(first-node-only) or AU-specific?

**Method**: With capture stopped, drag EQ above Reverb in the UI
(chain becomes `tnf.eq → tnf.reverb`). Verify wiring really
changed:
- Line 2348: `moveEffect: from 1 to 0` (logged).
- Line 2370: `powerOn complete: ... chain: tnf.eq -> tnf.reverb`.
- Source-grounded: `Graph.attach()` wires `nodes[i].outputBus →
  nodes[i+1].inputBus` in array order, so the engine wiring
  matches the displayed order, not just the UI.

Restart capture. Toggle EQ (now first). Toggle Reverb (now
second).

**Observations**:
- Line 2376: EQ bypass false→true (first-node) → **no cut**.
- Line 2379: EQ bypass true→false → no cut.
- Line 2382: Reverb bypass false→true (second-node) → **CUTS**.

**Conclusion**: Chain position is NOT the discriminator. Reverb
cuts wherever it is in the chain; EQ doesn't cut wherever it is.
The bug is **AVAudioUnitReverb-specific** (or, more precisely,
ReverbNode-as-implemented-specific), not chain-head-specific.

#### EXP-031.C — Sub-experiment EXP-B1: standalone isolation repro

Spawned as a chip session (worktree
`investigation/exp-b1-parallel-fanout-repro`). See dedicated
EXP-B1 entry below and `docs/investigations/exp-b1-results.md`.

**Summary verdict**: DOES_NOT_REPRODUCE. The
parallel-fan-out-with-Reverb topology — replicated faithfully in
a standalone `AVAudioEngine` harness driven by `AVAudioPlayerNode`
(not `AVAudioSourceNode`), outputting via `mainMixer.installTap`
(not hardware) — produces audible dry signal at unity peak
(0.5012, matching the source amplitude) when wet=0. The
`reverb_wet_0.001` manipulation produced peak 0.5018 (essentially
identical to 0.0), refuting the exact-zero-pruning sub-hypothesis
as well.

**Implication**: The mechanism is not in the parallel-fan-out
topology alone. The bug requires something from tap-n-filter's
production environment that B1 deliberately omitted:
`AVAudioSourceNode` semantics, ring-buffer pull cadence, real
hardware output (especially BT/HFP), the
`AVAudioEngineConfigurationChange` observer + recovery branch, or
some combination.

#### EXP-031.D — Speaker route test (BT disconnected)

**Date**: 2026-05-28 ~05:26 EDT.
**Question**: Does Bug A (cutout on reverb bypass) require the BT
context, or does it reproduce on speakers too?

**Method**: Disconnect BT; system output is built-in speakers.
Quit + relaunch tap-n-filter. Start capture (Safari source).
Toggle Reverb bypass with both effects at wetDryMix=1.0.

**Observations**:
- Chain: `tnf.eq → tnf.reverb` (carryover from EXP-031.B).
- Multiple toggles of reverb bypass at 05:27 and 05:28 EDT.
- Every log field at bypass.before / bypass.after: identical to
  the BT-route runs, including all formats reading
  `44100.0Hz×2ch`.
- No `[EXP-031.configChange]` events in this run (no HFP route
  switch because BT is disconnected).
- **Audible outcome: REVERB BYPASS NO LONGER CUTS AUDIO ENTIRELY.**
- **But a new persistent artifact is audible during the entire
  capture session, regardless of which effect is bypassed**:
  user-characterized as "very low pitched, voice-changer-anonymize
  + static crackling + left-channel shift." Present even with both
  effects bypassed (so it's upstream of every effect — at or
  before the source-node boundary).

**Conclusions**:

1. **Bug A (H16) refined: BT-route-specific.** The cutout
   requires the BT/HFP output context. On speakers it does not
   reproduce. Combined with B1's negative result, the bug is
   neither in the topology alone nor in the AU alone — it
   requires the BT/HFP route. H-S3 (BT/HFP context) / H-S4
   (configChange handler interaction) hypothesis family
   significantly strengthened.

2. **New Bug B (H17) discovered**: the persistent "voice-changer
   + crackling + left-shift" artifact is a separate, more
   fundamental capture-path bug that has been silently degrading
   every capture. Was masked on BT by HFP downsampling and the
   Bug A cutout. Hypothesis: sample-rate / channel-layout
   mismatch at the `AVAudioSourceNode` boundary. See H17 entry in
   the hypothesis ledger.

**Follow-ups**:
- Resolve H17 (Bug B) first — fundamental capture correctness.
  Next test: log `captureSourceNode.outputFormat(forBus: 0)`,
  `engine.mainMixerNode.outputFormat(forBus: 0)`,
  `engine.outputNode.outputFormat(forBus: 0)` at powerOn time.
- After H17 fix, re-evaluate Bug A on BT (the two may be coupled).
- The proposed ReverbNode refactor (`reverb.wetDryMix` +
  `reverb.bypass`) is **paused indefinitely** — B1 showed it
  would have been fixing the wrong thing.

---

### EXP-B1 — Standalone parallel-fan-out repro (DELEGATED, returned DOES_NOT_REPRODUCE)

**Status**: completed in a separate chip session.
**Date**: 2026-05-28.
**Author**: spawned task on branch
`investigation/exp-b1-parallel-fanout-repro` (commit `44bcc60`).
Results document: `docs/investigations/exp-b1-results.md`.

**Why this exists**: EXP-031.A/B narrowed Bug A to
"AVAudioUnitReverb-specific in our chain." Codex's external
research recommended refactoring ReverbNode to use the AU's
native `wetDryMix` + `bypass` rather than the parallel-mixer
scaffold, but explicitly flagged that the underlying mechanism
hypothesis ("wet=0 silences sibling dry path due to AVAudioEngine
pruning") should be validated in a minimal standalone repro
*before* shipping the refactor — otherwise we would be fixing the
wrong thing if the bug actually lives elsewhere.

**Question**: Does placing `AVAudioUnitReverb` in a parallel
fan-out connection (sibling to an `AVAudioMixerNode`, both feeding
separate input buses of a downstream summing mixer), with the
reverb branch's destination volume set to 0.0, cause the sibling
dry path's signal to silently fail to propagate downstream — *in
isolation*, without tap-n-filter's capture path, source node,
ring buffer, or hardware output?

**Pre-registered outcomes**:
- REPRODUCES_IN_ISOLATION → mechanism confirmed at the topology
  level; refactor is the right fix.
- DOES_NOT_REPRODUCE → bug requires something
  tap-n-filter-specific that B1 omitted; refactor was about to
  fix the wrong thing; refocus on the omitted pieces.

**Variables held constant**: macOS 26.3, AVAudioUnitReverb +
`largeHall` preset + `reverb.wetDryMix = 100.0`, exact
ReverbNode.attach()-style wiring, 44.1 kHz × 2 ch Float32.

**Variables changed (vs production)**: Source is
`AVAudioPlayerNode` scheduling a synthesized 440 Hz sine at -6
dBFS (not `AVAudioSourceNode` + ring buffer). Output via
`mainMixer.installTap` to WAV (not hardware). No process tap, no
aggregate device, no IOProc, no
`AVAudioEngineConfigurationChange`.

**Method**: Five configurations, each 3 s, output captured to
WAV, peak amplitude + non-zero-frame count measured:
1. `reverb_wet_0`: parallel fan-out, AVAudioUnitReverb, wet=0
   dry=1.
2. `reverb_wet_1`: same, wet=1 dry=0 (baseline reverb-only).
3. `reverb_wet_0.001`: same, wet=0.001 dry=1 (manipulation:
   tests exact-zero pruning).
4. `eq_wet_0`: same topology with AVAudioUnitEQ instead (positive
   control).
5. `single_chain`: no parallel mixer, `player → reverb →
   mainMixer` (serial sanity).

**Observations** (from `exp-b1-results.md`):

| Config | wetDest | dryDest | wet AU | Peak | Verdict |
|---|---|---|---|---|---|
| reverb_wet_0 | 0.0 | 1.0 | Reverb | 0.5012 | AUDIBLE |
| reverb_wet_1 | 1.0 | 0.0 | Reverb | 0.6812 | AUDIBLE |
| reverb_wet_0.001 | 0.001 | 1.0 | Reverb | 0.5018 | AUDIBLE |
| eq_wet_0 | 0.0 | 1.0 | EQ | 0.5012 | AUDIBLE |
| single_chain | n/a | n/a | Reverb | 0.6810 | AUDIBLE |

`reverb_wet_0` peak is exactly the -6 dBFS source amplitude
(0.5012) and matches `eq_wet_0` to four decimal places. The
`reverb_wet_0.001` differs from `reverb_wet_0` by 0.0006 — also
refuting the exact-zero-pruning sub-hypothesis.

**Conclusion**: **DOES_NOT_REPRODUCE.** The parallel fan-out
topology with AVAudioUnitReverb works correctly in isolation. The
bug is NOT in the parallel mixer pattern as such; it requires
something tap-n-filter-specific.

**Implications for the parent investigation**:
- Refutes T1 ("AVAudioUnitReverb in parallel fan-out triggers
  pruning"), T3 ("preset-specific to `largeHall`"), T5
  ("`reverb.wetDryMix = 100` is the trigger"), and the
  exact-zero-pruning sub-hypothesis.
- Does NOT refute (because B1 omitted them) hypotheses involving:
  `AVAudioSourceNode` semantics, ring-buffer pull cadence,
  hardware output / BT HFP pull pattern, the
  `AVAudioEngineConfigurationChange` observer + recovery branch.
- The recommended ReverbNode refactor (to native `reverb.wetDryMix`
  + `reverb.bypass`) is paused — it would have masked the bug
  rather than addressing it.

**Methodological note**: This was a Hacking-style intervention
test. The negative result is informationally rich precisely
because B1's design deliberately removed every tap-n-filter-side
variable. The remaining hypothesis space is narrowed to the
removed variables, which is what we need.

---

### EXP-030 — H13 reproducibility + defensive orphan cleanup (REFUTED H13)

**Status**: completed (3-run protocol).
**Date**: 2026-05-28 (01:45 / 01:46 / 01:47 EDT).
**Author**: current session.

**Question**: Does force-killing the app while capture is running
leave orphan process taps or aggregate devices visible to a fresh
instance via `kAudioHardwarePropertyTapList` /
`kAudioHardwarePropertyDevices`, and does their presence correlate
with `AudioDeviceStart` returning `kAudioHardwareIllegalOperation-
Error` ('nope', 1852797029) on the first Start after the unclean
exit?

**Hypothesis under test**: H13 (leaked HAL state from prior runs).

**Pre-registered outcomes**:
- H13-α (CONFIRMING): force-kill leaves visible orphans AND
  without cleanup the start fails ('nope'). Cleanup eliminates
  the failure.
- H13-β (NON-REPRODUCING): force-kill leaves no visible orphans.
  HAL auto-cleans on process death; the bug we observed in
  EXP-027/EXP-028 was via some other path.
- H13-γ (PARTIAL REFUTATION): orphans visible but
  AudioDeviceStart returns 0 anyway.
- H13-δ (CLEANUP INSUFFICIENT): orphans visible AND cleanup
  destroys them but start still fails.

**Variables held constant**: Hardware, source process (Safari),
BT state (Bose QC connected), EXP-029 observability still
running.

**Variables changed**: Added new `CoreAudioInterface` methods
(`enumerateAllAudioDevices`, `audioDeviceUID`, `tapName`); added
`CaptureController.cleanupOrphans()` at init time gated by a
`UserDefaults` knob (`tap-n-filter.disableOrphanCleanup`); added
`[EXP-030.preinit.*]` tagged log lines.

**Artifacts**: Build CDHash
`b783086404388259697a76ac6264322c9a0a04d8`. Log file
`~/Library/Logs/tap-n-filter/app.log` lines 1424-1505.

**Method** (3-run protocol):
1. Launch 1 — clean baseline: cleanup pass, Start, Stop normally.
2. Launch 2 — to-be-killed: Start, capture running. **Force-kill
   mid-capture via Activity Monitor.**
3. Launch 3 — post-kill: relaunch within ~40 s; cleanup pass
   runs; Start.

**Observations**:

| Phase | Launch 1 | Launch 2 (to-be-killed) | Launch 3 (post-kill) |
|---|---|---|---|
| Cleanup `taps enumerated` | 0 | 0 | **0** |
| Cleanup `taps matched` | 0 | 0 | **0** |
| Cleanup `aggregates enumerated` | 6 | 6 | **6** |
| Cleanup `aggregates matched` | 0 | 0 | **0** |
| `[EXP-029.prestart.taps]` count | 1 | 1 | 1 |
| `AudioDeviceStart` return | **0** | **0** | **0** |

Critical: Launch 3 ran 39 s after Launch 2's Start with NO Stop
transition in between — direct evidence of force-kill mid-capture.
Post-force-kill Launch 3 saw zero orphan taps in
`kAudioHardwarePropertyTapList` and zero orphan aggregates
matching our UID prefix.

**Conclusion**: **Outcome H13-β — H13 refuted via this protocol.**
The HAL either auto-destroys taps and private aggregate devices
on process death, or makes them invisible to a new process
instance via the enumeration properties. The "orphan tap blocks
new start" mechanism cannot operate because the preconditions
never obtain.

EXP-027 / EXP-028 mechanism remains **unexplained but inert** —
no recurrence in 6+ subsequent Starts.

**Follow-ups**:
- H13 moved to Inactive (refutation entry above).
- Cleanup code stays in place — benign defensive infrastructure.
- Pivoted to EXP-031 (Bug A / H16 instrumentation).

---

### EXP-029 — Instrumented A/B with minimal-reader control (PRE-REGISTERED)

**Status**: pre-registered; run pending
**Date**: 2026-05-28 (this session)
**Author**: current session

**Why this exists**: EXP-027 and EXP-028 (below) both produced
`AudioDeviceStart returned 1852797029` ('nope', =
`kAudioHardwareIllegalOperationError`). EXP-028 was framed as "the
muteBehavior fix" with a confident A/B/C prediction; the actual
outcome (still 'nope') is none of A/B/C — outside the predicted
space. The deeper problem is that the failing code path has almost
zero observability: the log records "AudioDeviceStart returned <n>"
and nothing else about the tap, the aggregate, the engine, or the
HAL state at the moment of failure. This experiment adds the
observability + a minimal control so we can adjudicate between
candidate hypotheses instead of guessing.

**Question 1**: Does a `TapIOProcReader` started WITHOUT any
`AVAudioEngine.attach(sourceNode)` reach `AudioDeviceStart=0`? I.e.,
isolate the production failure from any engine entanglement.

**Question 2**: What observable signal differs between EXP-026's
working AudioDeviceStart=0 path and the failing production path?

**Hypotheses under test** (see hypothesis ledger H9–H14 below):
- H10 (engine.attach pre-empts) — predicts minimal-reader control
  succeeds, production fails. Falsified if both succeed or both fail.
- H9 (isPrivate=true is the cause) — predicts both fail, because both
  use `coreAudio.createTap` which sets `isPrivate=true`. Falsified if
  either succeeds. (Disambiguated from H10 only by a follow-up that
  flips isPrivate.)
- H12 (existing AVAudioEngine instance holds HAL state) — predicts
  both fail, since both run inside the AppViewModel whose AVAudioEngine
  was instantiated at init. Falsified by H10's success of the
  minimal-reader (the engine instance is unchanged between the two
  paths in EXP-029).
- H13 (leaked HAL state from prior runs) — predicts both fail and
  remain failing across app restarts. Falsified by either succeeding,
  or by a reboot-then-retry succeeding.

**Pre-registered outcomes** (predict THEN run):

- **Outcome E** — minimal-reader passes (`AudioDeviceStart=0`,
  IOProc fires ≥10 in 5s, frames > 0), production fails. **H10
  confirmed.** Engine.attach pre-empts the aggregate's start path on
  macOS 26.3. Fix: move `engine.attach(sourceNode)` to AFTER
  `reader.start()`, or otherwise decouple the engine state from the
  HAL state at start time. *Probability estimate*: ~45%.

- **Outcome F** — both fail with identical `AudioDeviceStart`
  return. The detailed log will reveal which observable differs
  from EXP-026. The most likely differences are tap description
  fields (H9 if `isPrivate`, H11 if other). Next experiment is
  bisecting field-by-field. *Probability estimate*: ~30%.

- **Outcome G** — both pass. The bug has self-healed between
  EXP-028 and EXP-029. Suspicious — should investigate environment
  changes (BT state, HAL daemon restart, system load). Re-run to
  confirm reproducibility before declaring victory. *Probability
  estimate*: ~10%.

- **Outcome H** — minimal-reader fails but production passes. Would
  refute everything I've assumed about the relationship between the
  two paths. Strong frame-check trigger. *Probability estimate*:
  ~5%.

- **Outcome I** — observable diff reveals something I haven't
  hypothesized (e.g., aggregate stream counts differ from EXP-026,
  or the tap description has a field I'm not tracking). *Probability
  estimate*: ~10%.

**Variables held constant**:
- Same build, same source process (Safari Graphics and Media), same
  BT headphones, same time window (back-to-back invocations).

**Variables changed** (vs EXP-028):
- TapIOProcReader gains a comprehensive observability block (see
  "Observability layer" below) — every step logs its inputs, outputs,
  and the readback of relevant HAL properties.
- A new debug-panel button ("Reader test") runs a `TapIOProcReader`
  for 5 s with NO `engine.attach` and NO graph wiring. Logs the same
  observability block. Counts IOProc fires and ring samples. This is
  the minimal control.
- The production Start button still attempts the full path; its
  observability block surfaces the same fields.

**Auxiliaries held** (any failure of these undermines the conclusion):
- The observability logging itself is not the cause of any failure
  (it's all `os_log` writes; should be inert).
- The minimal-reader button uses the SAME `TapIOProcReader`,
  `CoreAudioInterface`, and tap creation code as production. The
  ONLY difference is the absence of `engine.attach(sourceNode)`.
- The user's BT state, TCC grants, and the source process are
  identical in both back-to-back tests.

**Observability layer** (what gets logged at each step):
1. Pre-tap-creation: full CATapDescription field dump (uuid, name,
   isPrivate, isExclusive, isMixdown, isMono, muteBehavior, processes,
   deviceUID, stream).
2. Post-tap-creation: AudioHardwareCreateProcessTap status, tap ID,
   readback of isPrivate + muteBehavior from the live tap object.
3. Pre-aggregate-creation: full aggregate dictionary dump.
4. Post-aggregate-creation: AudioHardwareCreateAggregateDevice
   status, aggregate ID, stream count for input + output scopes.
5. Pre-tap-list-set: payload type and tap UID array contents.
6. Post-tap-list-set: AudioObjectSetPropertyData status, stream count
   readback (should be input=1 now).
7. Post-IOProc-create: AudioDeviceCreateIOProcID status, IOProc ID.
8. Pre-AudioDeviceStart: aggregate's `kAudioDevicePropertyDeviceIs-
   Running`, engine.isRunning (if engine exists), enumeration of
   process taps in HAL (for leak detection per H13).
9. Post-AudioDeviceStart: status with FourCC translation (so
   1852797029 prints as 'nope').

**Method**:
1. Apply the observability layer and the new "Reader test" button
   to the code. No other code changes.
2. Build, ship to user.
3. User: with Safari playing, press "Reader test" (minimal control).
   Wait 6 s for the verdict line.
4. User: press main Start (production). Capture the resulting error.
5. Both paths produce a structured log block. Compare side by side
   to identify the divergent observable.

**Artifacts**:
- Build CDHash `263e524def28a4cd0026688014df74803abb69c0`
  (instrumentation only; no functional code changes vs EXP-028 except
  for the addition of the Reader test button and logger plumbing).
- `~/Library/Logs/tap-n-filter/app.log` entries 00:37:20 EDT
  (production path) and 00:43:18 EDT (Reader test).
- Tagged log lines: every step's log entry starts with
  `[EXP-029.<phase>]` for grep-ability.

**Observations**:

User ran them in reverse order (production first, then Reader test
after a 5-minute gap with capture fully idle in between). Both
sequential. Diff of the two log blocks:

| Observable | Production (00:37:20) | Reader test (00:43:18) | Diff? |
|---|---|---|---|
| Path tag | `PRODUCTION (CaptureController.start)` | `RDRTEST (TapIOProcReader, NO engine.attach)` | by design |
| `audioProcessID` | 129 (Safari) | 129 (Safari) | no |
| `tap.create` status | OK, `tapID=154` | OK, `tapID=154` (HAL recycled the ID after teardown) | no |
| Tap stream format | 48 kHz × 2 ch Float32 | 48 kHz × 2 ch Float32 | no |
| Ring capacity | 96 000 frames/channel | 96 000 frames/channel | no |
| `engine.preattach` outputFormat | 44.1 kHz × 2 ch (A2DP) | n/a (no engine) | n/a |
| `engine.postattach` engine.isRunning | false | n/a | n/a |
| `prestart.taps` count | 1 (our own) | 1 (our own) | no |
| Aggregate dictionary | identical key set (SubDeviceList=[] + MasterSubDevice=0 + IsPrivate=true; no TapList; no TapAutoStart) | identical | no |
| `agg.create` | OK, `aggregateID=162` | OK, `aggregateID=155` (fresh) | only IDs |
| `agg.streams.pre` | input=0 output=0 | input=0 output=0 | no |
| `taplist.set` | OK | OK | no |
| `agg.streams.post` | **input=1 output=0** | **input=1 output=0** | no |
| `ioproc.create` | OK | OK | no |
| `prestart.agg.isRunning` | false | false | no |
| **`AudioDeviceStart` return** | **0 (success)** | **0 (success)** | **no** |
| IOProc delivery in 5 s (Reader test only) | n/a | 196 608 frames, 99 % non-zero, peak 0.736 | n/a |
| Post-start `outputNode` (engine path only) | 16 kHz × 1 ch (HFP route-switch fires 65 ms after AudioDeviceStart) | n/a | n/a |

User-reported audible behaviour:
- Production: audio audible through BT headphones in HFP-quality mode.
  EQ + reverb parameter changes audibly responsive (verified by a
  ~30-second slider-sweep block in the log from 00:37:40 → 00:38:00).
- Reader test: Safari audio went silent for the 5 s test window (tap
  with `.mutedWhenTapped` is active and being read → OS mutes the
  source). No processed audio reached the user (no engine in the
  picture). 99.5 % non-zero ring samples confirm the tap delivered
  real Safari audio into the buffer.
- Reverb-bypass toggle during the production run caused audio to cut
  out entirely (user-reported; not present in the log because
  `setBypass` is not currently instrumented).

**Conclusion**: **Outcome G with a twist** (and a partial **Outcome
I** for HFP and bypass).

Both pre-registered paths passed `AudioDeviceStart=0`. This is closer
to Outcome G ("both pass, suspicious") than to E or F because the
prior EXP-027 / EXP-028 runs failed deterministically with the same
production code path. The difference between EXP-028 (fail) and
EXP-029 (pass) is *not* a functional code change — only logging was
added and a new diagnostic button. The HAL state between sessions is
the most plausible discriminator.

Direct evidence for each refuted hypothesis:
- **H10 (engine.attach pre-empts) — refuted.** Production includes
  `engine.attach(sourceNode)` 18 ms before `reader.start()` (per the
  `engine.postattach` log line at 00:37:20.377). Production
  AudioDeviceStart returns 0. Reader test omits `engine.attach`
  entirely. Both return 0. The variable I expected to discriminate
  doesn't.
- **H9 (isPrivate=true) — refuted.** Both paths use
  `coreAudio.createTap` which sets `isPrivate=true`. Both pass. The
  field is not load-bearing.
- **H11 (other field difference) — refuted.** Same as H9; both
  paths use the same `CATapDescription` construction.
- **H12 (existing engine instance) — refuted.** Production uses the
  live `AppViewModel.engine` and passes. The engine instance does
  not block the aggregate's start.
- **H14 (combination) — refuted.** No combination of D-differences
  discriminates pass/fail when the HAL is clean.

What's *left*:
- **H13 (leaked HAL state) — survives, unconfirmed.** Both EXP-029
  runs had `prestart.taps count=1` with the ID being our own
  freshly-created tap. The HAL was in a clean state. EXP-027 /
  EXP-028 must have had different prestart.taps content (orphans
  from prior crashes) — but those runs had no instrumentation so we
  can't verify directly. Confirmation requires deliberate
  reproduction: force-kill the app mid-capture, restart, observe
  prestart.taps count > 1 AND AudioDeviceStart fail.
- **H15 (HFP forced by capture) — new active, source-grounded.**
  Production's `outputNode` was at 44.1 kHz × 2 ch (A2DP) at
  `engine.preattach` time. 65 ms after `AudioDeviceStart returned 0`,
  the `AVAudioEngineConfigurationChange` fires with
  `outputNode=16000Hz × 1ch` (HFP rate). The architectural refactor
  fixed the AVAudioEngine-side problem, but the macOS routing layer
  still forces BT into HFP whenever a process-tap IOProc is active.
  Codex flagged this at the start of the investigation as
  intrinsic-to-the-platform; the prediction is now empirically
  confirmed in our app.
- **H16 (bypass toggle cuts audio) — new active, unlogged.** The
  `setBypass` action is invisible to the file log; the
  graph-mutation path may or may not log; the engine-restart-on-
  config-change path that Codex P1 introduced may interact with
  it. Cannot articulate a sharper hypothesis until we instrument.

**Follow-ups**:
- Step 2 (planned): make H13 *deterministically reproducible* and
  add defensive cleanup at `CaptureController.init` (or
  AppViewModel.init) that enumerates orphan process taps tagged with
  our `tap-n-filter.aggregate.*` UID prefix and destroys them.
- Step 3 (planned): instrument `setBypass`, `Graph.mutate`,
  SourceNode `attach/detach`, and the engine-restart-on-config-change
  branch. Reproduce H16 with logs flowing.
- Step 4 (decision): document H15 as an OS-layer limitation in an
  ADR or uncertainty entry. Decide whether V0.1 ships with the
  HFP-on-BT caveat or blocks on a HAL-plugin investigation (V0.2
  scope).

### EXP-028 — muteBehavior `.muted` → `.mutedWhenTapped` (REFUTED)

**Status**: completed, refuted
**Date**: 2026-05-28 00:16 EDT
**Author**: current session

**Question**: Does flipping the tap's `muteBehavior` from `.muted`
(ADR-014's original choice) to `.mutedWhenTapped` (EXP-026's choice)
get `AudioDeviceStart` to return 0 in production?

**Hypothesis at run time**: H8 — `.muted` is incompatible with
direct-IOProc `AudioDeviceStart` in our TCC context. *Methodological
note*: H8 was framed as a single-variable hypothesis even though at
least 6 other observable differences existed between EXP-026 (works)
and EXP-027 (fails). I noted in passing that audiotee uses `.muted`
from Terminal and works, which should have lowered confidence in H8
*before* running EXP-028. I did not let it.

**Pre-registered outcomes** (at the time):
- A: AudioDeviceStart succeeds, audio plays, effects audible. H8
  confirmed.
- B: Still `nope`. H8 refuted; cause is something else.
- C: AudioDeviceStart succeeds but downstream issues.

**Variables changed (vs EXP-027)**:
- `CoreAudioInterface.createTap` now sets
  `description.muteBehavior = .mutedWhenTapped` (was `.muted`).
- Build CDHash changed from `c9d8bc645954839b...` to
  `6808f106a8247222...`.

**Observations**: `AudioDeviceStart returned 1852797029`.
Identical failure mode to EXP-027. No new log lines (no observability
was added).

**Conclusion**: **Outcome B — H8 refuted.** The muteBehavior change
alone does not get AudioDeviceStart to return 0. The cause is one or
more of the other 6 differences between EXP-026 and EXP-028.

**Methodological lesson**: I had no observability to back-pocket if
the prediction was wrong, and no plan for what to do next. This
exhausted a turn for one bit of information (`.mutedWhenTapped` is
not the sole cause) when, with proper instrumentation, the same
trial could have eliminated 3-4 hypotheses at once.

**Follow-ups**: → EXP-029 (observability + minimal control). Do NOT
re-attempt single-variable fixes until EXP-029 reports.

### EXP-027 — First live test of merged refactor (REFUTED H7-was-the-only-issue)

**Status**: completed, refuted (the implicit assumption that the
refactor alone would unblock live audio).
**Date**: 2026-05-28 00:09 EDT
**Author**: current session

**Question**: Does the merged Phase 1 rework (ADR-018,
`TapIOProcReader` + `AVAudioSourceNode`, all V1-architecture code
deleted) produce audible processed audio through BT headphones on
macOS 26.3?

**Hypothesis at run time**: H7 (unified-IO-AU silent-discard) is the
ONLY remaining barrier; with the architecture refactor, capture
works end-to-end. EXP-026 had already source-grounded that the
direct-IOProc pattern fires correctly with non-zero samples.

**Pre-registered outcomes** (at the time):
- A: Clear full-fidelity audio, effects audibly responsive. FC-003
  validated; Phase 4 ready.
- B: Degraded audio (HFP-style or distorted). Something specific
  still wrong.
- C: Silence. Architectural fix didn't fix anything. Catastrophic.
- D: App crashes/freezes.

**Observations** (from `~/Library/Logs/tap-n-filter/app.log`):
```
00:09:34.717 [WARNING] lastError set: Engine configuration failed: AudioDeviceStart returned 1852797029
00:09:34.740 [INFO]    captureState: idle -> starting
00:09:34.740 [INFO]    captureState: starting -> failed(...AudioDeviceStart returned 1852797029...)
```

The user pressed Start; capture transitioned to `starting`, then
immediately to `failed`. No intermediate logging captures what the
tap, aggregate, or IOProc actually did.

**Conclusion**: **None of the pre-registered outcomes A/B/C/D
match.** What actually happened is an entirely new failure mode in
the new architecture: `AudioDeviceStart` returns `kAudioHardware-
IllegalOperationError` (1852797029 = 'nope'). The refactor did not
hit AVAudioEngine's unified-IO-AU bug — it didn't even get to a
running engine.

This **does not refute H7** (unified-IO-AU is still believed broken
in v1). It refutes the implicit assumption that the architecture
refactor was sufficient to unblock live audio — there's a new bug
in the refactor itself, specific to running the EXP-026-proven
pattern inside the production CaptureController + AppViewModel
context.

The verification subagent's PASS was correct about its scope
(unit tests, code shape, fake-HAL behavior). The integration test
(TI.1) was an accepted-deviation because the autonomous run
couldn't produce a real audio source. So this failure mode was
outside the verification's evidence frame; not the verifier's fault.

**Failure mode**: I (this session) jumped immediately to a fix
(EXP-028 muteBehavior) without enumerating the alternative
differences between EXP-026 and EXP-027. The single-variable
framing of H8 was the methodological error.

**Follow-ups**: → EXP-028 (refuted) → EXP-029 (the proper response).

### EXP-026 — Audiotee EXACT pattern with SubDeviceList + MasterSubDevice keys

**Date**: 2026-05-27 22:30 EDT (pre-registration; run pending)
**Author**: current session

**Question**: Does audiotee's exact aggregate-creation pattern — with
`kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
`kAudioAggregateDeviceMasterSubDeviceKey: 0` keys present, tap list
set AFTER creation as `CFArray<CFString>` — get the IOProc to fire
from inside `tap-n-filter.app`? EXP-016 attempted "audiotee post-set
pattern" but the lab record doesn't confirm those two aggregate-init
keys were included; this is the gap.

**Hypothesis under test**: H3 (HFPSpike IOProc-no-fire is a code-level
setup bug, not a platform constraint). Specifically: the missing
`SubDeviceListKey: [] as CFArray` and `MasterSubDeviceKey: 0` in our
prior aggregate creations may be required to initialize the
aggregate's clock infrastructure before a tap can be attached and
driven.

**Pre-registered outcomes**:
- **Outcome α** — IOProc fires (fires > 0) with non-zero samples
  (maxAbs > 0). **Architecture validated**. The missing keys were
  the issue. Proceed to production refactor using this pattern.
- **Outcome β** — IOProc fires (fires > 0) with all-zero samples
  (maxAbs = 0). **macOS 26 zero-buffer bug** (forums thread 825780)
  confirmed hitting our app despite TCC. Refactor stalls; need
  different approach (HAL plugin, or wait for Apple fix).
- **Outcome γ** — IOProc doesn't fire (fires = 0). Even audiotee's
  exact pattern doesn't work in our app's TCC/signing context.
  Suggests something more fundamental (FDA-like TCC requirement,
  hardened-runtime restriction) is blocking us. Need entirely
  different architecture (HAL plugin, virtual device).
- **Outcome δ** — `AudioDeviceStart` returns 'nope' (1852797029,
  `kAudioHardwareIllegalOperationError`). Same failure as EXP-016
  earlier audiotee-pattern attempt. The two missing keys aren't the
  fix either; something else is required.

**Variables held constant**:
- Same build infrastructure as EXP-024/025.
- BT (Bose QC) connected, Safari playing YouTube as the source.
- tap-n-filter.app's existing TCC grant.

**Variables changed** (vs prior audiotee-pattern attempts):
- Aggregate creation dictionary now includes
  `kAudioAggregateDeviceSubDeviceListKey: [] as CFArray` and
  `kAudioAggregateDeviceMasterSubDeviceKey: 0`.
- Tap list is set AFTER aggregate creation via SET on
  `kAudioAggregateDevicePropertyTapList`, with the tap list as a
  `CFArray` containing a single `CFString` (the tap's UID).
- `kAudioAggregateDeviceTapAutoStartKey` removed (audiotee doesn't
  use it).
- `kAudioAggregateDeviceTapListKey` removed from creation dictionary.

**Auxiliaries held**:
- The two missing keys (`SubDeviceListKey: []`, `MasterSubDevice: 0`)
  are necessary for the IOProc to fire on a tap-aggregate. Audiotee's
  working pattern includes them; our prior failures didn't.
- `CFArray<CFString>` (just UIDs) is the correct format for the
  post-set tap list; not `CFArray<CFDictionary>` (which is the
  embedded-creation format).
- The `audioteeTestIOProc` C function pointer is correct and would
  fire if registered against a working aggregate (confirmed by
  audiotee itself working from Terminal).

**Would shift confidence down**: the IOProc still doesn't fire
(Outcome γ or δ). Then we have to conclude that even audiotee's
exact pattern doesn't transfer to our app — meaning audiotee's
success from Terminal hinges on something we haven't replicated
(possibly the Terminal-spawned process inheriting some TCC scope
we don't have access to).

**Method**:
1. Quit any running tap-n-filter.
2. Launch new build (CDHash will change; TCC may or may not re-prompt).
3. Play music in Safari.
4. Open debug panel; pick Safari Graphics and Media as source.
5. Press the **Audiotee test "Run 5s"** button (purple scope icon).
6. After ~6 s, the verdict is logged. Three numbers to look for:
   - `fires=N` — IOProc callback count
   - `bytes=N` — total bytes delivered by the IOProc
   - `nonZero=N` — count of non-zero samples in delivered audio
   - `maxAbs=N` — peak amplitude

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 22:07:11 → 22:07:16
  EDT (2026-05-27).

**Observations**:

```
22:07:11.138 AudioteePatternTest.run: source=Safari Graphics and Media (pid 77880)
22:07:11.148 tap created id=159
22:07:11.161 aggregate created id=160 (audiotee exact pattern: empty SubDeviceList + MasterSubDevice=0, tap list set after creation)
22:07:11.164 tap list set on aggregate via SET (CFArray of CFString)
22:07:11.167 aggregate streams — input=1, output=0
22:07:11.185 AudioDeviceStart=0; IOProc registered and started
22:07:16.219 RESULT: SUCCESS — ioProc fired 471 times, 1929216 bytes
            (482304 samples), 479702 non-zero (99.5%), maxAbs=0.7290.
22:07:16.221 AudioDeviceStop=0, DestroyIOProcID=0
```

- 471 IOProc fires in 5 s = ~94 fires/sec at 48 kHz × ~512-sample
  buffers = textbook normal.
- 99.5% non-zero samples, peak 0.73 → loud, real, recognizable
  Safari/YouTube audio captured byte-for-byte.
- Aggregate streams: `input=1, output=0` — the tap is properly
  wired as the aggregate's input source.

**Conclusion**: **Outcome α — architecture validated**. The
direct-IOProc-on-tap-aggregate pattern Codex recommended at the
start of this investigation works inside `tap-n-filter.app` when
the aggregate is created with `kAudioAggregateDeviceSubDeviceList-
Key: [] as CFArray` and `kAudioAggregateDeviceMasterSubDeviceKey: 0`
present, and the tap list is set after creation as
`CFArray<CFString>` (just UIDs, not array-of-dict).

**H3 resolved**. The IOProc-no-fire bug across HFPSpike + earlier
AudioteePatternTest attempts was a missing-aggregate-keys bug, not
a Swift-block, TCC, signing, BT, or platform issue. All the rule-
outs (R3, R4, R5, R6) stand; H3 itself now joins them in "ruled
out" — *with a positive finding*: the architecture works, we just
needed the right keys.

**Side-effect of resolution**: this also implicitly retires the
zero-buffer-bug concern (FC-002's alternative frame). The macOS 26
zero-buffer issue, whatever its scope, is NOT hitting our app —
99.5% of samples are non-zero.

**Follow-ups**: → ADR-XXX (Direct IOProc + AVAudioSourceNode
architecture). The production refactor is now de-risked. Concrete
template for the working aggregate setup lives in
`Sources/ViewModel/AudioteePatternTest.swift` lines 159-211.

### EXP-025 — Three-point tap (inputNode + mainMixerNode + outputNode)

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session

**Question**: At which point in the engine pipeline does audio stop
flowing? `inputNode` is push-driven by the device IOProc; `mainMixer-
Node` and `outputNode` are pull-driven by the output side. The combo
of which taps fire vs which return zero buffers will localize the
failure to a specific stretch of the pipeline.

**Hypothesis under test**: refined H7 — outputNode's IOProc isn't
firing on macOS 26.3 when the unified IO AU's CurrentDevice points at
the no-output tap aggregate. EXP-024 returned `bufferCount=0` on
mainMixer, which is consistent with the refined story. EXP-025 should
show inputNode firing (with non-zero samples, proving the tap delivers
real audio to the engine) while mainMixer and outputNode both return
zero buffers.

**Pre-registered outcomes**:
- **Outcome P** — inputNode > 0 buffers (nonZero > 0), mainMixerNode = 0
  buffers, outputNode = 0 buffers. **Refined H7 confirmed.** Tap
  delivers real audio; output side of the pipeline is dead because
  outputNode's IOProc isn't pulling. Architectural fix:
  Codex-recommended direct-IOProc + AVAudioSourceNode (engine output
  bound to default output, never to the aggregate).
- **Outcome Q** — inputNode = 0 buffers, mainMixerNode = 0,
  outputNode = 0. The tap isn't delivering audio at all (macOS 26
  zero-buffer bug, forums thread 825780, possibly intermittent).
  Different fix path: investigate whether the tap is actually pumping,
  or whether the aggregate's input streams are broken.
- **Outcome R** — inputNode > 0 (nonZero > 0), mainMixerNode > 0
  (nonZero > 0), outputNode = 0 or all-zero buffers. Graph is pumping,
  output side is unique problem. Subset of refined H7.
- **Outcome S** — inputNode > 0 (nonZero > 0), mainMixerNode = 0,
  outputNode > 0 buffers. Unusual; would mean outputNode is being
  pulled but mainMixer isn't (different engine wiring than we think).
- **Outcome T** — All three > 0 with non-zero samples. Then the audio
  IS reaching outputNode and somehow not getting written to a device.
  Closer to the original H7 framing.

**Variables held constant**:
- Same build as EXP-024 plus the multi-tap modification.
- BT (Bose QC) connected; same source (Safari Graphics and Media).

**Variables changed**:
- `runMixerTap` now installs taps on three nodes simultaneously, logs
  per-node stats (bufferCount, totalFrames, nonZeroFrames, maxAbs),
  and writes whichever has the most signal to WAV (input > mixer >
  output priority).

**Auxiliaries held**:
- `installTap` on `engine.inputNode` is the documented way to observe
  device-delivered samples on the engine input side.
- `installTap` on `engine.outputNode` is supported in AVAudioEngine
  (Apple docs say you can tap any node including the output node).
- The tap callbacks themselves are not subject to engine pull (the
  callback fires when the node renders, even if that render is from
  push-driven device data on inputNode).

**Method**:
1. User presses "Tap 5s" once.
2. Three taps installed, 5s window, three taps removed.
3. Three log lines `STATS <nodeName>: bufferCount=N frames=N nonZero=N maxAbs=N`.
4. One WAV file written (the node with most signal).
5. User reports the three stat lines and what (if anything) the WAV
   contains.

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 21:48:50 → 21:48:55
  EDT (2026-05-27). First attempt with `outputNode` tap crashed the
  app at 21:44; second attempt (this entry) skips outputNode.
- `/var/folders/.../tap-n-filter-mainMixerNode-1779918535.wav` —
  0-byte WAV.

**Observations**:

First attempt (with outputNode tap) crashed/hung the app after
"installed tap on mainMixerNode bus 0" with no further log lines. The
outputNode `installTap` apparently raised an Objective-C exception
that Swift can't catch. The app exited (or hung). New auxiliary
ruled out: tapping `engine.outputNode` is reliably supported on
macOS 26.3 with our setup — it's not.

Second attempt (two-point tap, no outputNode):

```
21:48:50.583 powerOn complete: engine started, chain: tnf.reverb -> tnf.eq
21:48:50.611 installed tap on inputNode bus 0
21:48:50.611 installed tap on mainMixerNode bus 0
21:48:50.611 collecting for 5s
21:48:50.716 AVAudioEngineConfigurationChange fired: engine.isRunning=FALSE, outputNode=16000.0 Hz × 1 ch
21:48:50.716 engine stopped itself on configuration change; detaching graph and calling attemptReattach
21:48:55.669 STATS inputNode: bufferCount=0 frames=0 nonZero=0 maxAbs=0.0
21:48:55.669 STATS mainMixerNode: bufferCount=0 frames=0 nonZero=0 maxAbs=0.0
```

105 ms after powerOn the engine killed itself in response to the
HFP route-switch. The H4 handler fired, logged its message,
detached the graph, and called `attemptReattach`. But the log shows
**no** evidence `attemptReattach` actually re-started the engine
(no "engine started" / "graph reattached" / "powerOn complete"
follow-up log line). The engine sat in a stopped state for the
remaining ~4.95 s of the tap window.

**Conclusion**: **Outcome Q** *and* a new failure mode (call it
mode B for the Status block):

- inputNode tap fired zero times because the engine wasn't running.
- mainMixerNode tap fired zero times because the engine wasn't
  running.
- The engine wasn't running because:
  1. HFP route-switch fired `AVAudioEngineConfigurationChange` with
     `isRunning=false`.
  2. The H4 handler detached the graph and called `attemptReattach`.
  3. `attemptReattach` silently failed to bring the engine back —
     no log evidence of restart, no `captureState` transition back
     to running.

This is distinct from EXP-024's failure mode (where the engine
survived the config change with `isRunning=true` but no IOProc
pulled). Both end with user-perceived silence; the engine just gets
there via two different broken paths.

**Frame check trigger**: we've now diagnosed *two* independent
broken paths for the same architectural choice (unified IO AU +
CurrentDevice = tap aggregate). The right framing is no longer
"which subtle bug is causing silence" but "this architecture cannot
be made to work on macOS 26.3 — we need to remove the tap aggregate
from the engine's input AU entirely." → FC-003.

**Follow-ups**:
- → FC-003 (frame shift to "architectural rewrite required").
- → ADR-XXX for the chosen architectural approach (direct IOProc +
  AVAudioSourceNode is the leading candidate per Codex's original
  recommendation).
- H4's `attemptReattach` failing in this scenario is a real bug but
  it would only matter for an architecture where `attemptReattach`
  is part of the recovery path. If we abandon AVAudioEngine.inputNode
  for capture, we don't need attemptReattach at all.

### EXP-024 — Tap `mainMixerNode` output to disambiguate H7

**Date**: 2026-05-27 (pre-registration; run pending)
**Author**: current session
**Question**: Is `mainMixerNode`'s output producing non-zero audio
samples during capture? I.e., does processed audio reach the engine's
final pre-output stage, or is the chain producing silence upstream?

**Hypothesis under test**: H7 (unified IO AU's CurrentDevice → tap
aggregate → engine output silently discarded). H7 predicts the mixer
output has real audio content; the silence happens at the
outputNode-to-device step. Alternative hypotheses predict different
upstream zero-points.

**Pre-registered outcomes**:
- **Outcome X**: WAV file contains audible Safari audio (recognizable
  music / speech) → engine processes correctly through to
  mainMixerNode; H7 confirmed. Audio is being silently discarded by
  the device-write step. Next step: architectural fix (Codex's direct
  IOProc + SourceNode, or separate HALOutput).
- **Outcome Y**: WAV file is all zeros (or very close to it) → audio
  doesn't reach mainMixerNode at all. H7 refuted. The bug is upstream
  — either tap delivers zeros (macOS 26 bug #825780), or
  inputNode→graph→mixer chain has a routing problem. Next step:
  install tap on `engine.inputNode` instead to locate where the
  signal becomes zero.
- **Outcome Z**: WAV file has audio content but with telephone-grade
  low-pass character (HFP-style) → tap audio is being captured but
  the route is already being degraded by HFP before reaching mixer.
  Refines H7 with HFP entanglement; still architectural.

**Variables held constant**:
- Same build watermark as current top-of-tree (post-EXP-023, sans
  pre-capture diagnostics).
- BT (Bose QC) reconnected as default output.
- Safari Graphics and Media playing audible YouTube content.

**Variables changed**:
- Install `AVAudioNodeTapBlock` on `engine.mainMixerNode` via
  `installTap(onBus: 0, bufferSize: 1024, format: nil)`.
- Tap block writes each buffer to a `.wav` file in `/tmp/` using
  `AVAudioFile`.
- New debug-panel button "Tap mixer (5s)" that arms the tap, lets
  capture run for 5 s, then stops capture and closes the file.
- Tap is opt-in (button-driven), not on every powerOn.

**Auxiliaries held**:
- `AVAudioEngine.installTap` on `mainMixerNode` does not interfere
  with the engine's normal operation (Apple docs say it observes,
  does not redirect).
- Writing to a local `.wav` is reliable from a real-time audio
  callback (Apple's AVAudioFile is thread-safe; we'll write off the
  callback if needed).
- The file we read back is the one the tap wrote — no stale file
  caching.

**Method**:
1. Implement `mixerTap` armable from `AppViewModel.runMixerTap()`,
   parallel to `runAudioteeTest()`.
2. Button in `DebugPanel` ("Tap mixer 5s") armed only when source is
   selected. Pressing it: powerOn (or assume already on), install tap,
   wait 5 s, stop capture, deinstall tap, close file. Log path of
   file written to debug log.
3. User: pick Safari source, press button, wait, then open the WAV
   in QuickLook / iTunes / `afinfo` to inspect.
4. Report: is the file content audible Safari audio, all-zero
   silence, or HFP-degraded audio?

**Artifacts**:
- `~/Library/Logs/tap-n-filter/app.log` entries 07:02:44 → 07:02:50
  EDT (2026-05-27).
- `/var/folders/.../tap-n-filter-mixer-1779865369.wav` — 0 frames
  (empty file; AVAudioFile created but no buffers written).

**Observations**:

```
07:02:44.937 powerOn complete: engine started, capture running on Safari Graphics and Media, chain: tnf.reverb -> tnf.eq
07:02:44.938 runMixerTap: mainMixerNode.outputFormat = 16000.0 Hz × 2 ch
07:02:44.941 runMixerTap: installed tap on mainMixerNode bus 0; collecting for 5s
07:02:45.015 AVAudioEngineConfigurationChange fired: engine.isRunning=true, inputNode=48000.0 Hz x 2 ch, outputNode=16000.0 Hz x 1 ch
07:02:49.949 runMixerTap: removed tap. bufferCount=0 totalFrames=0 nonZeroFrames=0 maxAbs=0.0
07:02:50.084 runMixerTap: wrote 0 buffers to /var/folders/.../tap-n-filter-mixer-1779865369.wav (0 frames @ 16000.0 Hz × 2 ch); nonZero=0, maxAbs=0.0
```

Five seconds of "running" capture produced **zero buffer-render
callbacks** on `mainMixerNode`. Not "rendered silence" — rendered
nothing. The tap callback was registered (we have the install/remove
log lines bracketing the window) and the node was nominally part of
the engine, but the render thread never asked it for samples.

**Conclusion**: **Outcome Y** (refined). The pre-registered Y was
"WAV file is all zeros," which we read as "render pulls zero-valued
buffers." The actual outcome is more extreme: render doesn't pull at
all. AVAudioEngine uses a pull-based model — `outputNode` requests
samples from `mainMixerNode` requests from upstream — so zero pulls on
mainMixer means **outputNode never pulled either**. The engine
reports `isRunning=true` and the configuration-change observer says
the engine is fine, but the actual render loop is dead.

This is **consistent with refined H7**: when the unified IO AU's
`CurrentDevice` is the tap aggregate (no-output device), the output
side of the AU has no device IOProc to drive — so it never pulls
upstream samples. The engine's nominal state is "running" because the
AU's `start` call succeeded, but no actual IO is happening on the
output side.

Refines H7's wording: it's not that audio is produced and silently
discarded by a no-output device. It's that audio is **never produced
at all** because nothing is pulling on the graph. The audible outcome
is identical (silence at the headphones), but the mechanism is one
step earlier than I originally framed it.

This rules out two other candidate mechanisms:
- Tap delivers all-zero samples (macOS 26 bug) — would have produced
  zero-valued buffers, not zero buffers.
- Effect chain breaks the signal somewhere — would have produced
  zero-valued buffers (chain renders silence), not zero buffers.

**Follow-ups**: → EXP-025 (multi-point tap: inputNode + mainMixer +
outputNode) to confirm the pull is dead end-to-end and that inputNode
is the only node still receiving samples. If EXP-025 confirms, the
architectural fix Codex recommended originally (direct IOProc + AVAudio-
SourceNode, output bound to default output device) is the right path.

---

### EXP-036 — Force default input ≠ Bluetooth, observe BT output stays A2DP

**Date**: 2026-05-29 (manual user intervention; ran)
**Type**: intervention (manual, not app code) — the test of whether the
system default *input* device is a load-bearing lever for the HFP trigger.

**Pre-registration note**: this entry documents a manual test the user
ran on 2026-05-29 and reported. The Prediction block is reconstructed
from what we would have predicted; the load-bearing conclusion rests on
the objective format readback in the artifacts, not on a timestamped
pre-registration. The *app-side automation* of this lever (EXP-037) is a
separate intervention and **will** be pre-registered before its code, per
`docs/governance/debugging-protocol.md`.

**Target mechanism**: H15, refined — the HFP route switch is gated on the
Bluetooth device being the system default *input* while a capture session
is active, not on a tap being active per se. Forcing the default input to
a non-BT device should keep the BT output on A2DP.
**Mechanism type**: behavior-inferred (the causal link); the format
readback is source-grounded.

**Question**: with an active process-tap capture and a Bluetooth output,
does forcing the system default *input* to the Mac built-in microphone
keep the BT output on A2DP (44.1 kHz stereo) rather than HFP (16 kHz mono)?

**Prediction** (reconstructed):
- **If load-bearing**: with default input on the built-in mic, the output
  diagnostic shows A2DP (`outputOut rate=44100 ch=2`) not HFP
  (`16000 ch=1`), and the reverb tail / stereo width audibly return.
- **Risky branch**: if the output still drops to HFP (`16000 ch=1`) with
  the default input on the built-in mic, the input-device lever is NOT
  load-bearing — the trigger is the active tap regardless of default
  input, H15's original "OS forces HFP for any active tap on BT output"
  stands, and the HAL-plugin virtual device (V0.2) is the only path. The
  app-side auto-switch idea would be dead.
- **Did-not-land branch**: if the default input did not actually change
  (verify in System Settings ▸ Sound ▸ Input), the test is void; re-run.

**Variables changed**:
- System default input device: Bluetooth headset → Mac built-in mic.

**Variables held constant**:
- Output device: same Bluetooth headphones.
- Source: Safari/YouTube; same effect chain; same build (post-EXP-034).

**Method**: connect BT headphones as default output. In System Settings ▸
Sound ▸ Input, set input to the Mac built-in microphone. Relaunch the app;
start capture on Safari/YouTube. Grep `[EXP-029.engine.preattach]` and
`[EXP-032.format.outputOut]`.

**Artifacts** — `~/Library/Logs/tap-n-filter/app.log`:
- 01:30:58 run (default input = BT): `[EXP-029.engine.preattach] …
  outputFormat=16000.0Hz×1ch`; `[EXP-032.format.outputOut …]
  rate=16000.0 ch=1` — HFP.
- 03:42:53 run (default input = built-in mic): `[EXP-029.engine.preattach]
  … outputFormat=44100.0Hz×2ch`; `[EXP-032.format.outputOut …]
  rate=44100.0 ch=2` — A2DP retained.

**Observations**:
- [source-grounded] The output route format went from 16 kHz × 1 ch (HFP)
  to 44.1 kHz × 2 ch (A2DP) between the two runs (readback above).
- [behavior-inferred] The default input device was the responsible
  change: it was the manipulated variable while output device, source,
  chain, and build were held constant. The user reported reverb depth and
  stereo width audibly returned.

**Landed?**: yes — default input changed to the built-in mic (confirmed in
System Settings; the run shows the input path at 44.1 kHz).
**Resolved?**: **yes** — the symptom moved: the output stayed on A2DP and
the reverb depth/width returned. The default-input device is a
**load-bearing, user-space-manipulable** lever for the HFP trigger.

**Conclusion**: outcome matched the load-bearing branch. H15 is refined —
the HFP switch is gated on the BT device being the *default input* during
capture, not merely on a tap being active. Because that lever is reachable
from user space (no entitlement, no kext), an **app-side mitigation
exists**: switch the default input away from the BT device for the
duration of capture, then restore it. This overturns the earlier H15
disposition ("intrinsic OS limitation; only a HAL plugin can fix it"). The
HAL-plugin path drops from "required fix" to "V0.2 robustness."

The app-side automation is a *separate* intervention (EXP-037), because it
adds failure modes this manual test did not exercise: save/restore
correctness, crash recovery (restore the original input if the app dies
mid-capture), Macs with no built-in or non-BT input, and races with the
user's own microphone usage.

**Follow-ups**: EXP-037 (app-side auto-switch — pre-register before code);
ADR-019 reframed from "intrinsic limitation" to "app-side mitigation +
deferred HAL path"; resolves Q4.

### EXP-037 — App-side default-input auto-switch + restore (PRE-REGISTERED, code not yet written)

**Date**: 2026-06-08 (pre-registration; the intervention has not run — no
device-switch code exists yet)
**Type**: intervention (fix attempt) — the app-side automation of the
EXP-036 lever. This entry is the gate required by
`docs/governance/debugging-protocol.md` and ADR-019: it is written *before*
any device-switch code, and it must be revisited and completed (Landed? /
Resolved? / Revision) after the implementation runs.

**Target mechanism**: H15 (refined by EXP-036). The HFP route switch is
gated on the Bluetooth device being the system default *input* while a
capture session is active. The automation: when capture starts on a
Bluetooth output and the BT device is also the default input, set the
system default input to a non-BT device (prefer built-in mic) for the
duration of capture, then restore the prior default input on stop.

**Mechanism type**: the lever is **already source-grounded + load-bearing**
— EXP-036 moved the symptom by manipulating exactly this variable. EXP-037
does **not** re-test whether the lever is load-bearing; that is settled.
EXP-037 tests two new, distinct claims the manual test did not exercise:
1. **Equivalence** — the *automated* switch reproduces EXP-036's effect
   (BT output stays A2DP) under real capture-start timing.
2. **Reversibility safety** — the prior input is reliably restored on clean
   stop and recovered after a crash, so the system-wide side effect never
   strands the user.

**Auxiliaries** (must hold for the automation to resolve the symptom *and*
be safe):
- **A1 (timing/ordering)**: the default-input switch takes effect *before*
  macOS negotiates HFP. EXP-029 timed the HFP flip at ~65 ms after
  `AudioDeviceStart`; the switch must precede the point where the active tap
  registers as a running input on the BT-default-input route. This is the
  auxiliary most likely to be false and is the pre-named revision site for a
  landed-but-unresolved result (see Risky branch).
- **A2 (device identity)**: the device the app classifies as "the BT output"
  and "the BT default input" are correctly identified via
  `kAudioDevicePropertyTransportType == kAudioDeviceTransportTypeBluetooth`
  (and `…BluetoothLE`), and the replacement is genuinely non-BT.
- **A3 (restore target exists)**: at stop/recovery time the saved input UID
  still resolves to a present device; if not, a defined fallback applies
  (restore to current system default, else built-in input).
- **A4 (no contention)**: switching the default input does not hijack a
  device the user is actively using as a microphone (the call-mid-call
  race).

**Race policy decided here** (ADR-019 left this as EXP-037's open design
point): **decline to switch when the BT input is already in use by another
process.** Before switching, query the BT input device's
`kAudioDevicePropertyDeviceIsRunningSomewhere`; if true (e.g. an active
call), the app does **not** touch the default input and surfaces the
README-style caveat instead. Hijacking a live call microphone is a worse
failure than degraded playback. The switch only engages on an idle BT input.

**Question**: does app code that switches the default input away from the BT
device on capture start (subject to the engage conditions) keep the BT
output on A2DP automatically, and does it leave the user's default input
correct on clean stop and after a crash?

**Diagnostics defined** (so "landed" and "resolved" are separable — the
ambiguous-fix anti-pattern is the thing to avoid):
- **D1 (switch landed)**: `[EXP-037.switch] from=<origUID> to=<replUID>
  btOutput=<uid> engaged=true` plus a readback that
  `kAudioHardwarePropertyDefaultInputDevice` now equals `replUID`.
- **D2 (symptom resolved)**: the existing output-route readback
  `[EXP-032.format.outputOut] rate=44100 ch=2` (A2DP) during *app-driven*
  capture, where the unmitigated run shows `rate=16000 ch=1` (HFP).
- **D3 (clean-stop restore landed)**: `[EXP-037.restore] to=<origUID>
  trigger=clean-stop ok=true` plus a readback that the default input equals
  `origUID` after stop.
- **D4 (crash recovery landed)**: with capture killed mid-session
  (simulated crash), on next launch with capture inactive
  `[EXP-037.recover] restoredTo=<origUID> markerCleared=true`, driven by the
  persisted `hfpMitigation.strandedInputUID` marker.
- **D5 (race decline)**: when the BT input is in use,
  `[EXP-037.switch] engaged=false reason=bt-input-in-use` and the default
  input is unchanged.

**Prediction** (locked before writing the code):
- **If load-bearing (automation correct and safe)**: D1 shows the input
  switched to a non-BT device on capture start (engage conditions met); D2
  shows A2DP retained automatically; D3 shows the original input restored on
  clean stop; D4 shows crash recovery restoring it on the next launch; D5
  shows the switch is declined when the BT mic is busy.
- **Risky branch (switch lands, symptom persists)**: D1 shows the input
  changed but D2 still shows HFP (`16000×1`). Because EXP-036 already
  established the lever is load-bearing, this does **not** refute the
  mechanism — it falsifies auxiliary **A1**: the switch landed too late,
  after HFP negotiated. Revision goes to the switch's *ordering* (perform it
  before `AudioDeviceStart` / before the tap registers as a running input,
  and re-verify the flip timing against EXP-029). Only if the switch is
  provably before capture start *and* HFP still wins does the revision
  escalate to "the automated context differs from EXP-036 in a way we have
  not modeled," at which point the HAL-plugin virtual device (V0.2) returns
  as the candidate. Blaming A1 is legitimate *here specifically* because the
  mechanism has independent intervention support (EXP-036); this is recorded
  now to prevent it reading as post-hoc auxiliary-rescue later.
- **Restore-risky branch (mitigation works, restore fails)**: D1 and D2
  succeed but D3 or D4 fails — the input is not restored on clean stop, or
  the crash marker does not recover it. The mitigation is then *effective
  but unsafe* (it strands the user on the wrong input). This is a
  **ship-blocker**, not a tuning note: ADR-019 makes restore reliability a
  safety requirement. Revision targets the save/restore call (D3) or the
  marker + launch-recovery logic (D4) — never the mechanism.
- **Did-not-land branch**: D1 does not show a switch when the engage
  conditions were met → the engage-condition evaluation or the
  `AudioObjectSetPropertyData` call on
  `kAudioHardwarePropertyDefaultInputDevice` is wrong. The mechanism is
  untested; fix the call and re-run rather than concluding anything about
  H15.

**Variables to change** (in the implementation under test):
- System default input device, app-driven, for the capture lifetime, under
  the three ADR-019 engage conditions plus the A4 race check.

**Variables to hold constant**:
- Output device (the BT headphones); source; effect chain; the post-EXP-034
  build of the audio path. The only manipulated variable is the default
  input automation, mirroring EXP-036.

**Method** (when the code exists): on a BT output with the BT device as
default input, start capture on Safari/YouTube with the setting on. Grep
`[EXP-037.*]` and `[EXP-032.format.outputOut]`. Then: clean-stop and confirm
D3; re-run and `kill -9` the app mid-capture, relaunch, confirm D4; start a
call on the BT mic, start capture, confirm D5 (declined). Compare against a
setting-off control run (expect HFP `16000×1`).

**Landed?**: pending — no implementation yet.
**Resolved?**: pending — no implementation yet.
**Revision taken**: pending.

### FC-006 — Cross-vendor review falsifies the EXP-037 race-signal auxiliary

**Date**: 2026-06-16
**Trigger**: a cross-vendor review (Codex GPT-5.5, xhigh) of the Layer B-core
implementation (PR #20) before merge.

The EXP-037 race policy (above) decided to gate the switch on the Bluetooth
input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`: if true, decline
(diagnostic D5, auxiliary A4). That choice was source-grounded only as "the
device reports running, so treat it as busy." It was never tested for the
property it actually needs: that the signal *discriminates* a Bluetooth device
merely playing A2DP output from one whose microphone is in active use by a call.

Codex finding #3 supplies the discriminating case. On a single Bluetooth headset
that is both the default input and the default output (AirPods and most
single-device BT headsets), audio is already playing when the user presses Start
— that is the whole scenario. The device is therefore running, so
`IsRunningSomewhere` reads true, so the guard takes the D5 decline path
(`reason=bt-input-in-use`) and the mitigation never engages in its primary
scenario. The shipped race check inverts its own intent: it fires on exactly the
case the mitigation exists to handle, and the "active call" case it was meant to
protect is indistinguishable from it by this signal.

This is a coherence-capture near-miss. The race policy read as a complete,
plausible design — query a documented "is the device in use" property, decline
if busy — and the internal adversarial reviewer accepted it. The property obtains
when a call is active (true), so the policy looked confirmed. The unstated
auxiliary was "and it is false during ordinary playback," which is the load-
bearing half and was never checked. The EXP-035-era lesson repeats at a new
boundary: a condition obtaining is not the condition being load-bearing for the
decision that rests on it.

The EXP-032 baseline run of the new probe (read-only, current machine state, no
Bluetooth attached) already corroborates the mechanism without the headset: with
music playing, the default *output* device (`MacBook Air Speakers`) reads
`runningSomewhere=true` purely from output, while the default *input* (the
separate built-in mic) reads `runningSomewhere=false`. The false-positive is a
property of output playback, and it lands on the input read only when input and
output are the same device. The headset run (EXP-037-R, below) tests whether the
Bluetooth case is in fact one device.

Codex finding #4 (readback timing) is a separate auxiliary on the same fix: the
`455d9c8` "drop the marker if the immediate default-input readback does not
match" logic assumes the HAL write is synchronous. If the write is asynchronous,
the immediate readback can miss a switch that lands a few milliseconds later,
which both reports a false failure and — having dropped the marker — strands the
user on the replacement input with no recovery breadcrumb. EXP-037-R measures the
write-to-readback latency to settle whether the immediate readback is safe.

**AMENDED 2026-07-31 by the EXP-037-R condition-Y run (below).** The signal was
tested and came back adequate: the headset is *two* device objects, so
`IsRunningSomewhere` read on the default-input object is false during A2DP
playback and the D5 decline path does not fire in the primary scenario. Codex
finding #3 is refuted for split-object hardware; the shipped race check stands
unchanged. What this frame check got right is the process point — the auxiliary
was load-bearing and untested. What it got wrong is the verdict it reached
without testing: it inferred the false-positive from the premise "input and
output are the same device," which measurement contradicts. The near-miss was
symmetrical — accepting a reviewer's mechanism claim on its plausibility is the
same error as accepting one's own.

Findings #2, #5, #6 are correctness refinements that do not bear on the
mechanism (require input==output same BT device for engage; preserve a valid
current non-BT default in the A3 fallback; skip non-defaultable candidates).
They are tracked on PR #20 and folded into the Layer B-core rework, not here.

### EXP-037-R — On-device race-signal discrimination + write-readback latency (PRE-REGISTERED)

**Date**: 2026-06-16 (pre-registration; the discriminating conditions Y and Z
have not yet been run — only the X baseline, as apparatus validation)
**Type**: measurement (signal selection) — supplies the corrected auxiliary for
the EXP-037 race check before the Layer B-core rework is written. Read-only
except for the optional `--measure-write` latency mode, which restores the prior
default input.

**Instrument**: `docs/investigations/probes/exp037_race_signal.swift`, compiled
with `swiftc -O -framework CoreAudio`. For the default input device it reports
five candidate race signals:
- **SIG_A** `kAudioDevicePropertyDeviceIsRunningSomewhere`, global scope — the
  shipped signal.
- **SIG_B** the same property, input scope.
- **SIG_C** any HAL process object with `kAudioProcessPropertyIsRunningInput`.
- **SIG_D** any process with `IsRunningInput` whose `kAudioProcessPropertyDevices`
  (input scope) includes the default-input device — the device-attributed form.
- **SIG_E** the input stream is present at an HFP-class rate (≤ 16 kHz).

**Question**: which signal reads FALSE when a Bluetooth headset is only playing
A2DP output (so the mitigation should engage) and TRUE when its microphone is in
active use by another process (so the mitigation should decline)?

**Conditions** (the BT headset is the default output throughout; the user sets
the default input to the BT headset where the scenario requires it):
- **X (baseline, done)**: current machine state, no Bluetooth. Validates that the
  probe runs and that the per-process list is populated. Result recorded below.
- **Y (A2DP playback, no call)**: BT headset connected and default output, music
  playing to it, BT headset also the default input, no app using the mic.
- **Z (active call on the BT mic)**: BT headset connected, an app actively
  *capturing* from the BT microphone, so the link is in genuine HFP voice use.
  Voice Memos, Photo Booth, or a call app (FaceTime, Zoom) all qualify. `say`
  does **not** — it synthesises output and never opens an input stream, so
  recording it would leave the microphone path untouched and the condition
  untested.

**Predictions** (locked before running Y and Z):
- **SIG_A** is TRUE in both Y and Z (the false positive Codex #3 predicts). If
  SIG_A is false in Y, finding #3 is refuted on this hardware and the shipped
  race check is adequate — the risky branch for Codex's claim.
- **SIG_C / SIG_D** are FALSE in Y and TRUE in Z. SIG_D is preferred if it holds,
  because it attributes the input use to the Bluetooth device specifically and
  will not decline because some unrelated app holds the built-in mic. SIG_C is
  the fallback if per-process device attribution (SIG_D) proves unreliable.
- **SIG_E** is FALSE in Y (A2DP, no input stream or a high-rate one) and TRUE in
  Z (HFP input stream at 16 kHz). SIG_E is a coarse fallback if the per-process
  signals do not discriminate.
- **Risky branch (no signal discriminates)**: if every candidate reads the same
  in Y and Z, the per-process approach fails on this HAL and the race check
  cannot be made precise from user space. The revision then goes to accepting a
  residual race and relying on prompt restore plus the documented caveat, or to
  gating on whether the headset is already in HFP at engage time (SIG_E) and
  treating "already HFP" as "leave it alone." This branch is named now so a
  same-in-both result is not quietly explained away later.
- **Single-device question**: the run also records whether the BT headset is one
  AudioObject exposing both input and output channels, or two. Codex #3 only
  bites if input and output resolve to the same device read; a two-device headset
  would localize the false positive differently and is recorded as a finding.

**Write-readback latency** (Codex #4, `--measure-write` mode): set the default
input to the built-in mic, poll the readback at 5 ms granularity with
timestamps, record the latency, restore. A latency at or near 0 ms means the
write is effectively synchronous and the `455d9c8` immediate-readback guard is
safe. A non-trivial latency means the immediate readback can false-fail and the
guard must poll for confirmation before declaring the switch landed or dropping
the marker.

**X baseline result (collected 2026-06-16)**: probe runs; 40 process objects
returned (per-process signals are available to an unsigned CLI binary). Default
input is the built-in mic (`runningSomewhere=false`); default output is the
built-in speakers, which reads `runningSomewhere=true` while music plays. SIG_A
on the default input is false because input and output are different devices
here. Apparatus validated; the discriminating Y/Z conditions require the headset.

**Y result — A2DP output active, no call (collected 2026-07-31)**: run with a
Bose QuietComfort headset connected as both the default input and the default
output, with the system sound server holding the output
(`pid=53912 systemsoundserverd runningInput=false runningOutput=true`), so the
Bluetooth link was genuinely carrying output at read time.

```text
DEFAULT INPUT : QuietComfort Headphones [BC-87-FA-23-5B-E0:input]  in=1ch rate=16000
DEFAULT OUTPUT: QuietComfort Headphones [BC-87-FA-23-5B-E0:output] out=2ch rate=44100

  [108] QuietComfort Headphones  Bluetooth  in=1 out=0  runningSomewhere=false  <DEF-IN,BT>
  [102] QuietComfort Headphones  Bluetooth  in=0 out=2  runningSomewhere=true   <DEF-OUT,BT>

  SIG_A  IsRunningSomewhere (global)              : false
  SIG_B  IsRunningSomewhere (input scope)         : false
  SIG_C  any process IsRunningInput               : false
  SIG_D  any process IsRunningInput on this device: false
  SIG_E  input stream present at HFP rate (<=16k) : true
```

**Single-device question — answered: the headset is TWO device objects.** macOS
publishes it as an input-only object (`108`, `in=1 out=0`) and an output-only
object (`102`, `in=0 out=2`), with distinct `AudioDeviceID`s and UIDs that are
the same MAC address suffixed `:input` / `:output`. The two never merge.

**This takes the risky branch named for Codex finding #3: SIG_A is FALSE under
condition Y, so the finding is refuted on this hardware and the shipped race
check is adequate.** Output playback marks the *output* object running
(`102` → true) and cannot mark the *input* object running, because the input
object carries zero output channels. `IsRunningSomewhere` read on the default
*input* device is therefore not contaminated by A2DP playback. FC-006's
"single Bluetooth headset that is both default input and default output"
premise does not hold: it is both, but as two separate device reads.

Scope of the refutation (measured on one headset, macOS 27): the two-object
split is a property of the macOS Bluetooth audio driver rather than of the
peripheral, so it is *expected* to generalise to AirPods — but that is reasoned,
not measured, and a combined-object headset would reinstate finding #3 exactly
as Codex described. The corrected auxiliary is therefore "SIG_A on the default
input is clean **whenever input and output are distinct device objects**," and
the residual risk is a device that presents them as one.

Condition Z (active call on the BT mic) is still owed. It would confirm the
other half — that SIG_A goes TRUE when the microphone is genuinely in use — and
cannot be automated, since it needs a real capturing app on the Bluetooth mic.
Y alone establishes no-false-positive; Z establishes no-false-negative.

Note in passing: the input object advertises `rate=16000` while the output
object is at `44100`. SIG_E reading true here is therefore *not* evidence that
the link was in HFP during this run — the input stream appears to report a
voice-class rate whenever it is present. SIG_E is unreliable as a
"currently in HFP" signal and is not adopted.

**Landed?**: Y yes (signal measured, finding #3 refuted for split-object
headsets). Z pending.
**Resolved?**: the race check is unchanged; no code fix was required for
finding #3. The Layer B-core rework instead carries findings #2, #5, #6 plus a
bounded readback poll for #4.
**Revision taken**: none to the race signal. FC-006's conclusion is amended —
the auxiliary it declared falsified is in fact sound on split-object hardware,
and FC-006's own corroborating evidence (built-in speakers vs built-in mic)
turns out to have been the *general* case rather than a Bluetooth-specific
near-miss. The frame check remains correct that the auxiliary was never tested;
testing it returned "adequate."

## External references

### Codex investigation report (this session)

**Source**: Codex 5.5 reply to `/codex:rescue` investigation request,
2026-05-24, reasoning effort xhigh.

**Most-relied-on quote** (verbatim, from Codex's response analyzing
the failing `pinEngineOutputToDefault`):

> [Setting `kAudioOutputUnitProperty_CurrentDevice` on
> `AVAudioEngine.outputNode.audioUnit`] returns `-10851`
> (`kAudioUnitErr_InvalidPropertyValue`)… `AVAudioEngine.outputNode`'s
> underlying AU is `kAudioUnitSubType_DefaultOutput`, which always
> uses the system default and refuses
> `kAudioOutputUnitProperty_CurrentDevice`. Only
> `kAudioUnitSubType_HALOutput` accepts that property.

**How we used it**: this exact warning is why H1 in the hypothesis
ledger is rated high-confidence. EXP-012 confirmed the warning empiri-
cally against our production logs.

### audiotee — makeusabrew/audiotee

**Source**: `/tmp/audiotee/` (locally cloned). Specific files
referenced:
- `Sources/AudioTeeCore/Core/AudioTapManager.swift`
- `Sources/AudioTeeCore/Core/AudioRecorder.swift`

**Pattern noted** (from `AudioTapManager.swift`, lines 105-151): the
aggregate device is created with an *empty* tap list, then the tap
list is set via `AudioObjectSetPropertyData(...,
kAudioAggregateDevicePropertyTapList, ...)` after creation:

```swift
let description = [
    kAudioAggregateDeviceNameKey: "audiotee-aggregate-device",
    kAudioAggregateDeviceUIDKey: uid,
    kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
    kAudioAggregateDeviceMasterSubDeviceKey: 0,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
] as [String: Any]
// … AudioHardwareCreateAggregateDevice(...) …
// Then post-creation:
let tapArray = [tapUID] as CFArray
AudioObjectSetPropertyData(deviceID, &kAudioAggregateDevicePropertyTapList,
                           0, nil, propertySize, &tapArray)
```

Our spike (and our production code) embeds `kAudioAggregateDeviceTap-
ListKey` in the creation dictionary instead. This is the most plausible
remaining cause for H3 (spike's IOProc-never-fires), if we ever return
to investigating it.

### Apple — `kAudioUnitSubType_DefaultOutput`

**Source**: `AudioUnit/AudioComponent.h` and Apple documentation.

**Relevant property**: `kAudioOutputUnitProperty_CurrentDevice` is
defined for `kAudioUnitSubType_HALOutput`. Default Output units are
locked to system default by design; they do not expose the
`CurrentDevice` property.

### insidegui/AudioCap

**Source**: project's coding standards
(`docs/governance/coding-standards.md`) cites AudioCap as the canonical
reference for the Core Audio tap API. We have not read AudioCap's
playback path in detail this session; their published code is more
focused on capture-to-file than capture-then-play-through-output.

### Apple Developer Forums thread 825780 — Process Tap all-zero buffers

**Source**: https://developer.apple.com/forums/thread/825780

**Most-relied-on content** (paraphrased from a 2026-05-25 fetch; 0
Apple replies as of fetch):

> During long sessions using `AudioHardwareCreateProcessTap`, the
> `AudioDeviceIOProc` callback continues firing normally but every
> PCM sample is exactly 0.0f — while the system is producing audible
> output. Affected: macOS 26.5 Beta and likely 26.x. More frequent on
> MacBook Air M2. Workaround: full teardown and rebuild of BOTH the
> Process Tap and Aggregate Device (restarting IOProc alone or
> recreating only the aggregate is not reliable).

**How we used it**: this is the alternative explanation for the all-
zero samples we observed in EXP-007/008/009 from Terminal-launched
audiotee. It retroactively weakens R7-adjacent claims about TCC
silencing and forms the basis of FC-002's frame reconsideration.

### "Voice processing causes A2DP→HFP" — Apple Developer Forums

**Source**: synthesized from
https://developer.apple.com/forums/thread/775256 (PTT Framework
compatibility) and related AVAudioEngine threads.

**Most-relied-on content**:

> Switching from A2DP to HFP while audio is playing will cause a
> noticeable decline in audio quality. That same behavior occurs
> when enabling voice processing because voice processing enables
> input and output, which is effectively the same as playAndRecord.

**How we used it**: confirms that the HFP trigger is the "input +
output on the same engine" pattern, not specifically voice
processing. Our `engine.inputNode` binding to the tap aggregate makes
the engine effectively `playAndRecord`, which forces HFP. Reinforces
Codex's architectural recommendation: avoid putting capture on the
engine's input side at all.

### Rogue Amoeba ARK (Audio Routing Kit)

**Source**:
https://www.rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Legacy

**Most-relied-on content**:

> As of MacOS 15 (Sequoia), ACE is fully deprecated. On MacOS 14
> (Sonoma) and higher, our newer Audio Routing Kit (ARK) technology
> is used in place of ACE. ARK provides the same audio capture and
> routing capabilities as ACE, without requiring the complex
> installation process that was necessary to use ACE on Apple
> Silicon Macs. … The Audio Capture Engine (ACE) framework provides
> Mac apps with the ability to capture audio from specific running
> applications, as well as all audio currently being produced by the
> system. … It's provided in two parts: A C library that applications
> integrate to communicate with ACE, and a CoreAudio server plugin to
> be installed on the user's computer.

**How we used it**: Audio Hijack does NOT use `CATapDescription` —
they ship a CoreAudio HAL plugin instead. The professional commercial
app in this space chose a different architecture because the
lightweight tap API isn't reliable enough for production BT capture.
Validates our pain and provides an alternative architectural reference
if we ever decide the tap API is unviable for v0.x (would require a
separate signed/notarized installer for the HAL plugin).

### macOS HFP disable workaround

**Source**: synthesized from search results for "AVAudioEngine
Bluetooth HFP A2DP prevent macOS".

**Documented command**:

```bash
sudo defaults write com.apple.BluetoothAudioAgent "Disable HFP" -bool true
```

**How we use it**: testing-only workaround applied in EXP-018 to
verify whether HFP routing is the *only* remaining issue affecting BT
audio quality. Not a production fix (requires sudo, system-wide,
disables HFP for ALL apps not just ours).

## Open questions

- **Q1** (resolved by EXP-011): does LOCAL_SIGNING_IDENTITY cert persist TCC grants
  across launches? **Yes**, as long as the binary doesn't change.
- **Q2** (resolved by EXP-012): why does production "fail" on built-in
  speakers? **Because `pinEngineOutputToDefault` throws -10851 every
  time, and on speakers there's no HFP downsampling to mask the
  capture failure.**
- **Q3** (open): why does HFPSpike's IOProc never fire? Top suspect:
  the embedded-vs-post-set tap list difference between our aggregate
  creation and audiotee's. Less likely: a leaked aggregate from prior
  failed production runs interfering. Not yet pinned.
- **Q4** (resolved by EXP-036): once capture works, will it work on BT?
  **Yes, with the mitigation.** Unmitigated, active capture forces HFP
  (16 kHz mono) on a BT output (H15). But forcing the system default
  *input* away from the BT device keeps the output on A2DP (44.1 kHz
  stereo). The app automates this behind a default-on toggle (ADR-019,
  EXP-037). The original Codex thesis ("`configureEngineInput` will
  trigger HFP on BT") was right about the unmitigated path and is
  superseded for the architecture by ADR-018 (direct IOProc).
- **Q5** (open): are the existing Phase 1 / Phase 2 / Phase 3
  verifications still valid given that production capture has been
  silently broken on this branch? Probably need a phase-3 re-verify
  after H1's fix lands.

## Glossary

- **AUHAL**: AudioUnit Hardware Abstraction Layer. The specific
  `kAudioUnitSubType_HALOutput` audio unit Core Audio exposes for code
  that needs to bind to a specific hardware device. Distinct from
  `kAudioUnitSubType_DefaultOutput`, which is what `AVAudioEngine.-
  outputNode` uses and is locked to system default.
- **A2DP**: Advanced Audio Distribution Profile. The Bluetooth profile
  used for high-quality stereo music playback (44.1 / 48 kHz × 2 ch).
- **CATapDescription**: the `CoreAudioTypes` configuration object that
  describes a process tap.
- **CDHash**: the cryptographic hash a code signature seals over the
  binary. TCC and Gatekeeper match against the CDHash via the
  designated requirement. Changes when the binary changes.
- **Designated requirement**: a Code Signing expression
  (`identifier "X" and certificate leaf = H"Y"`) that TCC stores per
  grant. A future launch matches its own signature against this expres-
  sion to decide whether the existing grant applies.
- **HFP**: Hands-Free Profile. The bidirectional voice Bluetooth pro-
  file (16 kHz mono in, 16 kHz mono out — sometimes 8 kHz). macOS
  forces BT devices into HFP when any process opens an active capture
  session and the BT device is the system default output. Audible as
  a heavy low-pass + telephone-quality artifact.
- **IOProc**: a Core Audio I/O callback function registered via
  `AudioDeviceCreateIOProcID` or `AudioDeviceCreateIOProcIDWithBlock`.
  Fires whenever the device's I/O cycle completes. For a tap-only
  aggregate device, this is how captured audio is delivered to user
  space without going through an AUHAL.
- **TCC**: Transparency, Consent, and Control. macOS's privacy frame-
  work. Each TCC service (Microphone, Screen Recording, Screen &
  System Audio Recording, System Audio Recording Only, …) is a
  separate grant tied to a specific app's designated requirement.
- **LOCAL_SIGNING_IDENTITY**: the user's self-signed code signing identity, finger-
  print `<local certificate fingerprint>`. Self-signed →
  `TeamIdentifier=not set`. Sufficient for TCC persistence on macOS
  26.3, as proved by EXP-010 + EXP-011.

## Programme health

### FC-001 — Frame check on the HFP-is-the-cause programme (retroactive)

**Date**: 2026-05-25 06:35 EDT (entered retroactively; the trigger
condition fired around EXP-005 / EXP-006 but was not noticed at the
time)

**Trigger**: 4+ consecutive same-null experiments
(EXP-003, EXP-004, EXP-005, EXP-006) all reporting `ioProc fires=0`
with only protective-belt tweaks (output device, IOProc API variant,
tap config). The protocol now requires this check after 3.

**Current frame** (the paradigm we operated in for hours):

> The user reports degraded audio on BT and no audio on speakers. The
> root cause is that production's `configureEngineInput` binds an
> aggregate device to `AVAudioEngine.inputNode`, which forces BT into
> HFP voice mode. The fix is the HFPSpike architecture (direct IOProc
> + `AVAudioSourceNode`). We just need to get the spike's IOProc to
> fire.

**Alternative frame to consider** (which we eventually discovered in
EXP-012):

> Production capture itself is broken upstream of HFP. Every
> `capture.start` throws -10851 from `pinEngineOutputToDefault` before
> any audio flows. The user's reported symptoms have downstream
> explanations:
> - **BT low-pass character**: `configureEngineInput` already triggered
>   HFP in step 3 before the crash in step 4. After the crash, the BT
>   profile is in HFP mode but our engine is dead; Safari's *own* audio
>   continues playing through BT-HFP and that's what the user hears.
> - **Speakers silence**: same crash, no HFP downsampling on speakers,
>   so the failure is inaudible.
> Under this frame, HFP is real but secondary, and the spike was
> chasing a symptom.

**Distinguishing observation**: test production `Start` on built-in
speakers with audio playing. Under the current frame, it should at
least produce *something* (degraded by AUHAL coercion but audible).
Under the alternative frame, it should produce nothing audible and
log an error.

**What we actually saw later** (EXP-012, log inspection):
production fails on both BT and speakers with -10851 every time. The
alternative frame is correct.

**Decision**: switch frame. H_BT_only-is-the-cause moves to ruled out
(R1). HFP becomes a secondary concern (H2). Production-broken-upstream
becomes the primary frame (H1).

**Lesson**: a frame check at EXP-005 — when the third same-null run
on the spike landed — would have spawned a "test production Start on
speakers" experiment hours earlier. That single experiment would have
surfaced -10851 immediately. The cost of not having a programme-health
checkpoint was about 4-6 hours of session time chasing the wrong
paradigm.

**Mechanism added to protocol**: the README now mandates `FC-NNN`
entries after 3 consecutive same-null experiments. Future investiga-
tions will hit this trigger earlier.

### FC-002 — Frame check after secondary-source research

**Date**: 2026-05-25 14:30 EDT
**Trigger**: external research surfaced new context that retroactively
weakens conclusions from EXP-007, EXP-008, EXP-009, and partially from
H3's auxiliaries. Triggered manually after the research pass.

**Current frame (pre-research)**:

> Audiotee returns all-zero samples from Terminal because Terminal
> lacks the macOS 14.4+ "System Audio Recording Only" TCC grant. Our
> tap-n-filter.app has that grant, so its IOProc should fire with
> real audio if we can get the setup right. HFPSpike's IOProc-no-fire
> bug is independent of TCC. The architectural path forward is direct
> IOProc + AVAudioSourceNode (Codex's recommendation).

**Alternative frame surfaced by research**:

> Audiotee's all-zero samples from Terminal may have been the
> documented macOS 26 zero-buffer bug
> (https://developer.apple.com/forums/thread/825780), not TCC. Our
> TCC interpretation was behavior-inferred from one observation
> ("audiotee returns zeros") combined with one assumption ("Terminal
> lacks granular TCC"). The macOS bug provides an alternative
> explanation that doesn't require any TCC assumption. This means our
> own app's IOProc-on-tap may *also* be subject to intermittent
> all-zero returns, regardless of TCC.

**Distinguishing observations**:

- If the `defaults write … Disable HFP true` workaround (EXP-018)
  makes production audio clean and effects audibly responsive →
  capture is correctly delivering audio to our effect chain. TCC is
  not silencing us. HFP routing is the only remaining issue.
- If audio is still degraded with HFP system-disabled → either the
  macOS zero-buffer bug is hitting our app too, or there's another
  bug. Need finer investigation.

**Decision**: Run EXP-018 as a cheap test of the alternative frame.
Hold off on EXP-017 — its B/C/D outcomes are now all ambiguous because
we can't cleanly distinguish "TCC silencing" from "macOS 26 bug" from
"real setup failure." Pivot to the OS-level workaround as the next
data point.

**Lesson**: secondary-source research has high signal-per-effort and
should be the FIRST move (not the last) on any investigation where
documented platform behavior might explain symptoms. AI-driven
investigation has a structural blind spot for "what's already known by
the broader community" — the lab notebook protocol should explicitly
require an external-research checkpoint before running >3 experiments
on any hypothesis.

**Mechanism added to protocol**: the README will mandate an external-
research pass after the first hypothesis fails its initial test.
Pending update to `docs/investigations/README.md`.

### FC-003 — Frame check after EXP-025: architectural rewrite required

**Date**: 2026-05-27 22:00 EDT

**Trigger**: EXP-024 returned `bufferCount=0` on `mainMixerNode`.
EXP-025 returned `bufferCount=0` on `inputNode` AND `mainMixerNode`,
via a distinct failure mode (engine self-kills on HFP config change,
H4's `attemptReattach` silently fails to restore it). Two
independent failure paths confirmed for the same architectural
choice.

**Current frame (pre-FC-003)**:

> AVAudioEngine + process tap + aggregate device CAN work on
> macOS 26.3 if we wire it correctly and handle the BT HFP edge
> cases. H7 was the "last bug." Once we install enough tap-callback
> diagnostics and recovery logic, capture will pump audio reliably.

**Alternative frame surfaced by EXP-024 + EXP-025**:

> AVAudioEngine + process tap + aggregate device is *structurally
> incompatible* with macOS 26.3's unified IO AU. The render loop
> cannot reliably drive output when the AU's CurrentDevice has no
> output streams. *Multiple* failure paths exist (engine survives
> config change but doesn't pull / engine dies on config change and
> can't recover / outputNode.installTap throws), all converging on
> the same user-perceived silence. No combination of recovery logic
> can fix what is structurally broken at the AU level.

**Distinguishing observations** (already-collected):

- EXP-024: engine reports `isRunning=true` post-config-change but
  mainMixer renders 0 frames in 5 s → render loop dead even when
  engine "is running."
- EXP-025: engine reports `isRunning=false` post-config-change,
  H4 recovery runs detach + attemptReattach but engine doesn't
  re-engage → recovery path itself is broken.
- Both: source process is muted (ADR-014 works), user hears literal
  silence.
- outputNode.installTap throws uncatchable ObjC exception → engine
  state is too fragile to even *probe* without crashing it.

**Decision**: **Frame shifted.** Drop the "patch AVAudioEngine.input-
Node + tap aggregate" approach. Commit to Codex's originally
recommended architecture:

1. Drive a Core Audio IOProc on the tap aggregate directly
   (`AudioDeviceCreateIOProcID`).
2. Push captured PCM into a lock-free ring buffer.
3. AVAudioEngine has **only output** wired: source node reads from
   ring buffer → effect graph → mainMixer → outputNode.
4. Engine's `inputNode` is never touched — `outputNode` stays bound
   to the system default output device naturally.

This is the same pattern HFPSpike was attempting (H3 / EXP-002 ff).
HFPSpike's bug was that its IOProc never fired — a separable bug to
fix as part of the rewrite. The architecture itself is the right
one; only the implementation needs to be debugged.

**Why we didn't see this sooner**: we entered the investigation
believing the AVAudioEngine path was viable because (a) it was the
documented "happy path" and (b) the AudioCap reference repo uses it.
But AudioCap's tests are on older macOS versions where the IO AU
wasn't unified; the macOS 26.3 unified-AU semantics break that
assumption. EXP-023 was the source-grounded turning point
(`inputNode.audioUnit === outputNode.audioUnit`); EXP-024 and
EXP-025 are the empirical confirmations.

**Lesson**: when a published reference works on macOS N but not on
N+1, suspect platform-level invariant changes BEFORE suspecting your
own wiring. The macOS 26.3 unified-AU change is exactly the kind of
silent semantic-version-bump that breaks downstream apps.

**Next**: ADR-XXX (Direct IOProc + AVAudioSourceNode architecture)
documenting the decision; then incremental refactor of CaptureCont-
roller + AppViewModel to use the new path. HFPSpike code can be
adapted (with the IOProc-no-fire bug fixed) as the seed.

### FC-004 — Frame check after B1 negative + speaker test: a foundational bug was masked

**Date**: 2026-05-28 ~05:30 EDT.

**Trigger**: EXP-B1 returned DOES_NOT_REPRODUCE for the topology
mechanism we had narrowed to over EXP-031's three runs. Speaker
test then refuted the "bypass cuts on all routes" framing and
exposed a previously-invisible capture-path artifact (pitched-
down + crackling + left-shift) that had been present all along
but masked by HFP downsampling on BT and by Bug A's dramatic
cutout.

**Current frame (pre-FC-004)**:

> Bug A (reverb bypass cuts audio) is THE bug to fix. We've been
> instrumenting it, narrowing the mechanism, and would have
> refactored ReverbNode to use AVAudioUnitReverb's native
> wetDryMix + bypass per Codex's research recommendation. Once Bug
> A is fixed, capture works correctly.

**Alternative frame surfaced**:

> The investigation has been chasing the most dramatic symptom
> (Bug A's full cutout) while a more fundamental capture-path
> bug (Bug B / H17 — sample-rate or channel-layout mismatch at
> the AVAudioSourceNode boundary) has been silently degrading
> every capture. Bug B is route-independent; Bug A is
> BT/HFP-specific. They are independent. The "fix" for Bug A
> would not have improved capture quality on speakers at all,
> because Bug B would still have been making every capture sound
> wrong. The investigation should have included an "is the
> output of the chain bit-correct against a reference?" gate
> earlier — *before* deep-diving on any specific user-reported
> symptom.

**Distinguishing observations**:

- On speakers (no BT, no HFP, no cutout), capture still sounds
  wrong: voice-changer-anonymize pitch shift + crackling +
  left-shift artifact. Present even with both effects bypassed.
- On BT, the cutout dominates perception; HFP downsampling
  further obscures the underlying capture quality.
- EXP-024 / EXP-025 / EXP-027 / EXP-028 all heard "silence" or
  "HFP-degraded" — never characterized as
  "voice-changer-anonymize" until speaker test, because every
  prior run had either BT in HFP or a more dramatic upstream
  failure.

**Decision**: **Frame shifted.** Bug B (H17) becomes the
top-priority investigation. Bug A is downgraded to "BT-route-
specific; may be intrinsic OS routing pathology adjacent to H15;
re-evaluate post-Bug-B fix." The proposed ReverbNode refactor is
parked.

**Why we didn't see this sooner**: Three compounding factors:
1. User testing was BT-default; HFP downsampling on every BT
   run masked the capture quality.
2. The cutout (Bug A) was the loudest symptom — every Phase-3-
   era experiment was structured around it.
3. We never built a "capture quality vs. reference" gate. EXP-024
   captured `mainMixerNode` to WAV but interpreted the output as
   "engine isn't pulling," not as "engine IS pulling but the data
   it pulls is corrupted." With hindsight, EXP-024's zero-buffer
   result was consistent with engine-not-pulling *and* with
   engine-pulling-corrupted-format; we picked the first
   interpretation because the user's stated symptom was silence,
   not corruption.

**Lesson**: When investigating a user-reported symptom, build a
baseline test that validates the *non-symptomatic* properties of
the output (correctness, quality, bit-accuracy) early — not just
the property the user complained about. Otherwise, fixing the
loud bug exposes the quiet bug only at the end, and the
investigation arc is unnecessarily long.

**Mechanism added to protocol** (proposed for `docs/investigations/README.md`):

> Every Phase ≥ 1 investigation that touches a capture or render
> path must include a "correctness baseline" experiment that
> compares the path's output against a reference (e.g., a WAV
> dump of a known signal through the system, compared to the
> input signal). This sits alongside the user-reported-symptom
> investigation. It is allowed to be a single early experiment;
> it is not allowed to be omitted.

### FC-005 — Frame check after EXP-033: a confirmed condition was mistaken for the cause

**Date**: 2026-05-28 (evening, local)
**Trigger**: a result that felt suspiciously coherent (the EXP-032
rate readback "explained everything" and was called a "smoking gun"),
followed by the EXP-033 intervention failing to move the symptom.

**Current frame** (the reasoning that produced the error):
- EXP-032 source-grounded that a sample-rate mismatch *obtains* (source
  node 44.1 kHz, tap 48 kHz). That observation was then treated as
  having established the rate mismatch as the *cause* of the audible
  artifact, and a fix was proposed and shipped on that basis without a
  pre-registered prediction.
- The leap was from "condition C obtains" (source-grounded, cheap) to
  "C is the cause of symptom S" (a load-bearing claim that confirming C
  does not establish). The unstated auxiliary — "no other mismatch at
  this boundary contributes to S" — was false: the tap is interleaved
  and the pipeline is planar, a second mismatch whose evidence
  (`formatFlags=9`, `bytesPerFrame=8`) had been in the
  `[EXP-029.tap.format]` log since the first instrumented run.

**Alternative frame** (adopted): a fix is an intervention and an
intervention is the test of a hypothesis. Confirming a condition
obtains warrants nothing about its salience; only an intervention that
moves the symptom does. EXP-033 was exactly that test, and its
"yes-landed / no-resolved" outcome was an informative refutation of
H17a-as-cause, not a disappointment.

**Distinguishing observations**: the `[EXP-032.format.source]` readback
after the fix showed the rate genuinely changed to 48 kHz. That
collapsed the "fix didn't land" and "apparatus lying" revision
candidates and forced the revision onto "rate is not load-bearing."
The routing was available from the data the moment EXP-033 ran; it
should not have needed an external prompt.

**Decision**: keep the rate fix (it is correct on its own terms), split
H17 into H17a (rate, refuted as cause) and H17b (interleaving, the new
dominant-cause hypothesis under test in EXP-034), and adopt the
intervention discipline going forward.

**Lesson** (retroactive, and the reason for the new protocol): three
things should have happened and did not. (1) Rivals enumerated before
committing — "pitched down" at a format boundary has at least two
candidate causes (rate, channel layout), and only one was checked.
(2) The intervention pre-registered with a discriminating prediction
including the risky branch ("if the rate changes but the artifact
persists, rate is not load-bearing"). (3) The word "confirmed" withheld
until an intervention moved the symptom. These are now codified in
`docs/governance/debugging-protocol.md`, enforced via `CLAUDE.md`, and
recorded per-fix in the Intervention ledger above. FC-004's
"correctness baseline" lesson and this entry's "obtains vs
load-bearing" lesson are the same failure seen from two angles: the
investigation chased the loud symptom with coherent-sounding stories
instead of testing causal salience by intervention.

## Changelog

- 2026-05-25 06:35 EDT — initial notebook created (this session).
  Captured EXP-001 through EXP-012; documented environment, hypothesis
  ledger, references; queued EXP-013 (remove `pinEngineOutputToDefault`).
- 2026-05-25 06:50 EDT — retrofitted hypothesis ledger to new schema
  (source-grounded vs behavior-inferred tags, auxiliaries,
  resurrection conditions); added FC-001 capturing the retrospective
  Kuhnian shift from HFP-as-cause to production-broken-upstream;
  pre-registered EXP-013. Coincided with README amendments to the
  epistemic protocol.
- 2026-05-25 12:00 EDT — ran EXP-013. H1 verified
  (source-grounded); H2 empirically confirmed (no longer behavior-
  inferred from Codex's report alone); new H4 added (alreadyAttached
  re-attach loop). Updated Status block and TL;DR accordingly. Queued
  the H4 fix as the next experiment.
- 2026-05-25 12:05 EDT — ran EXP-014. H4 verified (source-grounded).
  Production capture now reaches sustained `running` state.
- 2026-05-25 12:09 EDT — ran EXP-015. H3's "entanglement with broken
  production state" auxiliary refuted; spike has its own bug.
- 2026-05-25 13:12 EDT — ran EXP-016 (audiotee post-set pattern).
  `AudioDeviceStart` returned 'nope' (1852797029) — new failure mode.
- 2026-05-25 14:00 EDT — pre-registered EXP-017 (HFPSpike setup
  pattern in minimal harness) as the decision-point experiment.
- 2026-05-25 14:30 EDT — pivoted away from EXP-017 after external
  research. Surfaced macOS 26 zero-buffer Apple bug (forums thread
  825780), confirmed HFP trigger mechanism (input+output on engine
  ≈ playAndRecord), discovered Audio Hijack uses HAL plugin
  architecture (ARK). Added FC-002 frame check, EXP-018 pre-
  registration (defaults write HFP disable test). Augmented External
  references with the new sources. Notebook protocol gap identified:
  external-research checkpoint should be earlier than after 3+
  failed experiments.
- 2026-05-27 08:15 EDT — ran EXP-021. **Outcome D** (literal silence;
  none of the pre-registered A/B/C predictions). Status block updated
  to reflect the reframing: source-mute working correctly + engine
  running with no errors + zero audio reaching user = engine output
  is silently discarded somewhere between mainMixerNode and the BT
  headphones. Added H7 to the active ledger and pre-registered
  EXP-024 (mainMixerNode tap to WAV) as the disambiguator. Built
  with CDHash `6a0f14fbe912...`. User will re-prompt for TCC on
  first launch.
- 2026-05-27 22:30 EDT — ran EXP-026 (audiotee exact pattern with
  `SubDeviceList: [] as CFArray` + `MasterSubDeviceKey: 0` and
  post-set tap list as `CFArray<CFString>`). **Outcome α** — IOProc
  fired 471× in 5s with 99.5% non-zero samples and peak 0.73. H3
  resolved (moved to ruled-out R8); architecture validated. Status
  block updated to point at the validated direct-IOProc path.
- 2026-05-27 23:30 EDT — formalised the refactor plan. Wrote
  ADR-018 (`docs/decisions/ADR-018-direct-ioproc-capture-architecture.md`),
  technical spec (`docs/specs/capture-v2.md`, with `capture.md`
  marked superseded), and phase spec
  (`docs/orchestration/phases/01-capture-spike-rework-1.md`) with
  TDD anchors T1.* — T4.* + TI.* and 14 gate criteria. Updated
  state.json: Phase 1 transitions to `in_progress` with
  `rework_spec` pointing at the new phase doc; Phase 4
  `blocked_on` rewritten to reference the rework rather than the
  underlying bugs. Composed a fresh `/goal` prompt (~3525 chars,
  under the 4000 limit) referencing the above; the user runs it
  in a cold-context session to execute the refactor autonomously.
- 2026-05-28 00:09 EDT — ran EXP-027 (first live test of merged
  refactor): `AudioDeviceStart returned 1852797029` ('nope').
  Refuted the implicit "refactor alone unblocks audio" assumption.
  Reactive jump to EXP-028 was the methodological error.
- 2026-05-28 00:16 EDT — ran EXP-028 (muteBehavior `.muted` →
  `.mutedWhenTapped`): identical 'nope' failure. **H8 refuted.**
  No observability in the failing path; user pushed back on the
  reactive single-variable fix approach.
- 2026-05-28 (this session) — pre-registered EXP-029 with proper
  hypothesis discipline (H9–H14 + falsification conditions),
  designed observability layer (`[EXP-029.*]` tagged log block at
  every HAL step), restored a minimal-reader control button in
  DebugPanel. Built CDHash `263e524def28a4cd...`.
- 2026-05-28 00:37 / 00:43 EDT — ran EXP-029. **Both production and
  Reader test pass** with `AudioDeviceStart=0`, identical observables
  at every step except by-design differences (`engine.attach` absent
  in Reader test). H9, H10, H11, H12, H14 all refuted. H13 (leaked
  HAL state) survives as the leading explanation for EXP-027 /
  EXP-028 failures. Two new active hypotheses: H15 (HFP forced by
  capture, source-grounded) and H16 (bypass toggle cuts sound,
  unlogged). Filled in EXP-029's Artifacts / Observations /
  Conclusion sections. Updated Status block. Moved H9–H12 + H14 to
  Inactive with refutation entries.
- 2026-05-28 01:45 / 01:46 / 01:47 EDT — ran EXP-030 (3-launch
  force-kill protocol for H13). Implemented defensive orphan
  cleanup at `CaptureController.init` with `[EXP-030.preinit.*]`
  instrumentation and a `UserDefaults` knob for negative control.
  Build CDHash `b783086404388259697a76ac6264322c9a0a04d8`.
  **Outcome H13-β — H13 refuted.** Post-force-kill instance saw
  zero orphan taps and zero orphans matching our aggregate UID
  prefix; `AudioDeviceStart` returned 0 anyway. EXP-027/EXP-028
  mechanism remains unexplained but inert. Cleanup code stays as
  benign defensive infrastructure. H13 moved to Inactive.
- 2026-05-28 ~03:05 EDT — ran EXP-031 run 1 (build v1 CDHash
  `a12e6f535d29b53aa9652c4bd080499f3b093ece`). Reverb bypass
  false→true cuts audio on BT; EQ bypass does not. Log line shape
  exposed a Swift dispatch bug: `debugStateDescription()` declared
  only in protocol extension was statically dispatched; Reverb/EQ
  overrides not called. Promoted to a protocol requirement.
- 2026-05-28 ~03:13 EDT — ran EXP-031 run 2 (build v2 CDHash
  `fbf5d113e8d562a5010b89ce7ce6d2b11d5c3e42`). With dynamic
  dispatch fixed, every state field is logged: both Reverb and EQ
  show identical `dryDestExists=true dryDestVol=1.0
  dryMixerVol=0.0 wetDestExists=true wetDestVol=0.0
  wetMixerVol=1.0` after bypass=true. `dryMixerVol=0.0` traced to
  `applyMixGains` fallback path running at attach time with
  persisted-state wetDryMix=1.0.
- 2026-05-28 ~03:30 EDT — fixed the `applyMixGains` fallback (no
  longer writes `mixer.volume`; always keeps it at unity).
  Extended `debugStateDescription` with format readback per
  internal mixer + the wet processor. Build v3 CDHash
  `78daded470d4d1aaa9660826de8f39990423d7a8`. Re-tested: every
  format reads `44100.0Hz×2ch` for both Reverb and EQ; mixer
  master volumes now 1.0 as intended; **audio still cuts on
  reverb bypass on BT**. The fallback fix was correct in itself
  but not the audible cause. Outcome H16-A confirmed (gain set as
  intended, audio still cuts), with the additional refinement
  that every observable field is identical between Reverb (cuts)
  and EQ (works) — mechanism must be invisible to our
  instrumentation.
- 2026-05-28 — delegated to Codex (`codex:rescue` model=gpt-5.5
  effort=high). Codex reported no documented Apple bug; canonical
  AVAudioUnitReverb wet/dry pattern uses the AU's own
  `wetDryMix`; Apple's `AVAEMixerSample` does not build a parallel
  scaffold for reverb; explicitly flagged that the
  "wet=0 prunes the sibling dry path" mechanism is a plausible
  inference but must be validated by a minimal standalone repro
  outside tap-n-filter before driving an ADR.
- 2026-05-28 04:48 EDT — ran EXP-031.B (chain-order swap). User
  drag-reordered chain to `tnf.eq → tnf.reverb`. Source-grounded
  via `moveEffect: from 1 to 0` log + the
  `Graph.attach`-wires-in-array-order code path. EQ bypass
  (first-node) did not cut; Reverb bypass (second-node) cut.
  **Chain position refuted as discriminator.** Reverb cuts
  wherever it is in the chain; EQ doesn't cut wherever it is.
- 2026-05-28 — spawned chip session for EXP-B1 (standalone
  isolation repro) on branch
  `investigation/exp-b1-parallel-fanout-repro`. Designed 5
  configurations probing the parallel-fan-out topology in
  isolation using `AVAudioPlayerNode` (not `AVAudioSourceNode`)
  and `mainMixer.installTap` output (not hardware).
- 2026-05-28 — EXP-B1 returned **DOES_NOT_REPRODUCE.** All 5
  configurations produced audible signal: `reverb_wet_0` peak
  0.5012 matched `eq_wet_0` peak 0.5012 exactly; `reverb_wet_0.001`
  peak 0.5018 essentially identical (refuting exact-zero-pruning
  too). The parallel-fan-out topology with AVAudioUnitReverb is
  not the cause. Refutes T1, T3, T5 from the EXP-031.A
  underdetermination space. The proposed ReverbNode refactor is
  paused — would have been fixing the wrong thing. Remaining
  hypothesis space: variables B1 omitted (AVAudioSourceNode
  semantics, ring-buffer pull cadence, hardware output / BT HFP,
  `AVAudioEngineConfigurationChange` observer + recovery branch).
- 2026-05-28 ~05:26 EDT — ran EXP-031.D (speaker route test).
  Disconnected BT; system output = built-in speakers. Repeated
  reverb bypass toggle. **Audio no longer cuts entirely on
  reverb bypass.** State fields identical to BT-route runs; no
  `[EXP-031.configChange]` events (no HFP route switch with BT
  disconnected). Bug A (H16) refined to **BT-route-specific**.
- 2026-05-28 ~05:28 EDT — same speaker session: user reported a
  **new persistent artifact during capture**, present even with
  both effects bypassed. Characterized as "very low pitched,
  voice-changer-anonymize + static crackling + left-channel
  shift." Present regardless of which effect (if any) is
  bypassed → must be upstream of every effect → implies
  source-node boundary. Added **H17 (sample-rate /
  channel-layout mismatch at AVAudioSourceNode boundary)** to
  active ledger. The artifact was masked on BT by HFP
  downsampling and the Bug A cutout. **Bug B is now the
  top-priority investigation; Bug A is parked pending Bug B
  resolution.**
- 2026-05-28 — added FC-004 frame check. Lesson: the
  investigation should have included a "capture output
  correctness baseline" earlier, separate from chasing
  user-reported symptoms. EXP-024's zero-buffer interpretation
  was consistent with both "engine not pulling" and "engine
  pulling corrupted format" — we picked the first because the
  user reported silence, not corruption. Proposed protocol
  update: require a correctness-baseline experiment for any
  capture/render investigation.
- 2026-05-28 15:44 EDT — ran EXP-032 (source-node + chain format
  readback). Build v4 (added `logChainFormats` helper in
  `AppViewModel`, called from `powerOn` and
  `reattachAfterMutation`). Speaker route. **Outcome H17-α —
  rate-mismatch mechanism CONFIRMED.** Tap delivers 48 kHz, but
  `[EXP-032.format.source]` reports `rate=44100.0`. AVAudioEngine
  silently overrode the format we passed to
  `AVAudioSourceNode(format: reader.format)`. Mainmixer chain
  runs at 44.1 kHz; SRCs to 48 kHz for the output device.
  Channel-layout byte-clean (`ch=2 interleaved=false` at every
  boundary) — left-shift portion is unexplained by this readback
  and parked as a residual to re-evaluate post-fix. Updated H17
  in ledger (mechanism confirmed for rate portion), Status block,
  added EXP-032 entry. Fix in flight: `AVAudioConverter` between
  ring buffer and source node, source node declared at engine
  rate, converter rebuilt on configChange.
- 2026-05-28 ~15:45 EDT — ran EXP-033 (rate-mismatch intervention).
  Pinned the chain to the tap rate via `graph.attach(sourceFormat:)`
  + `captureFormat` on the capture protocol; reverted the no-op
  converter. **Landed but did not resolve**: `[EXP-032.format.source]`
  changed to `rate=48000.0`, the artifact persisted ("still pitched
  super low"). The rate mismatch obtains but is **not load-bearing**
  for the audible artifact — refuting the post-EXP-032 causal leap.
  Rate fix kept (correct on its own terms).
- 2026-05-28 — re-examined the tap format. `formatFlags=9` +
  `bytesPerFrame=8` (in the `[EXP-029.tap.format]` log since the first
  instrumented run) decode to *interleaved* stereo; the ring/render
  pipeline is planar. Ran EXP-034 (de-interleave intervention):
  `TapIOProcReader` detects interleaving and de-interleaves in the
  IOProc at the correct frame count. Pre-registered with a four-symptom
  discriminating prediction + risky branch; built clean; **awaiting the
  user's audio verdict**. Split H17 into H17a (rate, refuted as cause)
  + H17b (interleaving, under test). Added EXP-033, EXP-034, the
  Intervention ledger, and FC-005.
- 2026-05-28 — added FC-005 frame check (a confirmed condition mistaken
  for the cause) and formalized the debugging methodology:
  `docs/governance/debugging-protocol.md` (fixes are interventions;
  obtains vs load-bearing; pre-register the discriminating prediction
  before code; revise the web holistically on a failed prediction),
  with the binding rule in `CLAUDE.md` and the searchable Intervention
  ledger added to the notebook + README structure.
- 2026-05-28 — **EXP-034 verdict: Bug B RESOLVED** on the speaker
  route. User confirmed no pitch-down, no left-spatial-shift, no
  crackle, and a correct wet/dry slider (wet=0 ≡ bypass). All four
  pre-registered consequences resolved together → H17b confirmed
  load-bearing. Updated the Intervention ledger, EXP-034 conclusion,
  H17b status, and Status block. Committed `9c0ae2c` (protocol) +
  `47cee0c` (capture fixes + notebook).
- 2026-05-28 — **EXP-035 verdict: Bug A RESOLVED, coupled to Bug B.**
  BT retest — the reverb-bypass cutout is gone after the de-interleave
  fix (Outcome 1). Bug A was a downstream symptom of the same
  interleaving frame-count error, not a reverb- or BT/HFP-specific
  mechanism; the long Bug A hypothesis search never reached the IOProc
  layer where the cause sat. Reverb is now audible on BT but slighter
  than on speakers — the expected H15/HFP 16 kHz mono degradation, not
  a new bug. Marked H16 resolved, updated Status. **Remaining
  capture-quality issue: H15 / HFP degradation on BT** (decision
  pending per the user: ADR-019 caveat vs deeper workaround vs V0.2
  HAL plugin).
- 2026-05-29 — **EXP-036: H15 mitigation found.** A manual test
  (default input switched to the Mac built-in mic) kept the BT output on
  A2DP (`outputOut 44100×2`) instead of HFP (`16000×1`) — confirmed in
  the app.log across two runs (01:30:58 HFP vs 03:42:53 A2DP). H15
  refined: the HFP switch is gated on the BT device being the system
  default *input* during capture, which is manipulable from user space.
  Disposition decided in **ADR-019** (default-on "Preserve Bluetooth
  quality" toggle; HAL plugin deferred to V0.2). Updated H15, Status,
  TL;DR, the Intervention ledger, and resolved Q4. The app-side
  automation is queued as **EXP-037**, to be pre-registered before its
  code on the settings branch per the debugging protocol.
- 2026-06-08 — **EXP-037 pre-registered** (code not yet written),
  satisfying the ADR-019 / debugging-protocol gate before any
  default-input switch code. The entry frames EXP-037 as testing the
  *automation* (equivalence to EXP-036 under real capture-start timing,
  plus restore/crash-recovery safety) rather than re-testing the lever,
  which EXP-036 already proved load-bearing. It names auxiliary A1
  (switch must precede HFP negotiation, ~65 ms post-`AudioDeviceStart`
  per EXP-029) as the pre-committed revision site for a
  landed-but-unresolved result, makes a restore-failure (D3/D4) a
  ship-blocker, and settles the open race-policy design point: **decline
  to switch when the BT input is already in use**
  (`kAudioDevicePropertyDeviceIsRunningSomewhere`). Added the Intervention
  ledger row (Landed?/Resolved? = pending) and diagnostics D1–D5.
- 2026-06-16 — **FC-006 recorded and EXP-037-R pre-registered.** A cross-vendor
  review (Codex GPT-5.5) of the Layer B-core guard argued that the D5 race
  signal, `kAudioDevicePropertyDeviceIsRunningSomewhere`, reads true whenever a
  Bluetooth headset is playing output, which would make the mitigation decline
  in its own primary scenario. The frame check named the untested auxiliary
  ("and it is false during ordinary playback") and pre-registered EXP-037-R to
  select a signal on-device rather than reason about it.
- 2026-07-31 — **EXP-037-R condition Y run; Codex finding #3 refuted.** With the
  headset connected as both default input and default output and the system
  sound server actively holding the output, SIG_A on the default *input* read
  false. The cause is structural: macOS publishes the headset as two device
  objects (`BC-87-FA-23-5B-E0:input`, `in=1 out=0` and
  `BC-87-FA-23-5B-E0:output`, `in=0 out=2`), so playback marks the output object
  running and cannot touch the input object. This is the risky branch the
  pre-registration named, so the shipped race check needs no change; FC-006 is
  amended in place. Condition Z (active call on the BT mic) is still owed and
  establishes the other direction — no false *negatives*. The same run supplied
  the measured UID shape behind the Layer B-core same-physical-device fix
  (Codex #2), which cannot be an `AudioDeviceID` comparison precisely because
  the two objects are distinct.

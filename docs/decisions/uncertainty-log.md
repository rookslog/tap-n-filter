# Uncertainty Log

Open questions whose answers would affect behavior but aren't currently determined. Each entry records what triggered it, current best guess, and what would resolve it.

## Format

Each entry:

```markdown
## U-NNN: <Short title>

**Status**: Open | Resolved (link) | Deferred to <future-version>
**Triggered by**: <what surfaced the question>
**Question**: <the actual uncertainty>
**Current best guess**: <what the project is doing in the meantime>
**Resolution path**: <how the question would get answered>
**Revisit trigger**: <when to come back to this>
```

Entries are numbered U-001, U-002, etc. Numbers persist. Resolved entries stay in the log (with status updated and the resolving ADR or commit linked) — they're not deleted. The point is for the auditor and future contributors to see what was unknown when decisions were made.

## Entries

---

## U-001: Capture API bridge approach

**Status**: Open
**Triggered by**: Phase 1 design (`docs/orchestration/phases/01-capture-spike.md`).
**Question**: Is AudioCap's aggregate-device pattern (Core Audio Process Tap wrapped in an aggregate device that AVAudioEngine reads as input) the right approach, or should the implementation use a raw `AudioDeviceIOProcID` callback feeding a ring buffer that AVAudioEngine reads via manual input?

**Current best guess**: AudioCap's pattern is the cleaner approach and is what `docs/specs/capture.md` commits to. The fallback (raw callback + ring buffer) is more code but avoids the aggregate-device complexity.

**Resolution path**: Phase 1 implementation. If the aggregate-device path produces stable audio with acceptable latency, U-001 is resolved with status "Resolved (AudioCap pattern)". If not, an ADR (likely ADR-006) documents the fallback.

**Revisit trigger**: Phase 1 spike work.

---

## U-002: AVAudioUnitReverb factory presets sufficiency

**Status**: Open
**Triggered by**: Phase 2 design (`docs/orchestration/phases/02-dsp-chain.md`).
**Question**: Will `AVAudioUnitReverb`'s factory presets (largeHall, plate, cathedral, etc.) produce the aesthetic the user wants — specifically, "engines drowning in long reverb" — or is custom IR convolution needed?

**Current best guess**: Factory presets are sufficient for V1. `largeHall` at 70% wet, combined with aggressive lowpass, should give the dissociating quality.

**Resolution path**: Phase 2 ear test. If `[EAR_TEST: PASS]` on the distant-engines preset using factory reverb, U-002 is resolved with status "Resolved (factory IRs sufficient)". If `[EAR_TEST: FAIL]` for reasons tied to the reverb sound, the orchestrator writes a new custom-ir-implementation ADR (next free ADR number at write time — likely ADR-009 or later, depending on what the build has produced by then) and adds a convolution node to Phase 2's scope.

**Revisit trigger**: Phase 2 ear test response.

---

## U-003: MenuBarExtra modal panel hosting

**Status**: Open
**Triggered by**: Phase 3 design (`docs/orchestration/phases/03-ui-control.md`).
**Question**: Can SwiftUI's `MenuBarExtra` window cleanly host `NSSavePanel` and `NSOpenPanel` modals on macOS 14.4, or do those panels need to be presented from a separate `NSWindow`?

**Current best guess**: A direct `NSSavePanel.runModal()` call from a button action in the MenuBarExtra window should work. The SwiftUI `.fileImporter` modifier may behave less reliably.

**Resolution path**: Phase 3 implementation. The orchestrator tests both paths and documents the chosen approach in code comments and an ADR if the choice has follow-on implications.

**Revisit trigger**: Phase 3 preset I/O implementation.

---

## U-004: Multi-pair output device level attenuation

**Status**: Deferred to V0.2
**Triggered by**: Apple Developer forum thread on Core Audio process taps cited during scribing.
**Question**: When the user's output device has more than 2 stereo pairs (e.g., RME Fireface, MOTU 8M), the tap produces audio attenuated by approximately `20 * log10(N_pairs)` dB. Should V1 compensate, or accept the attenuation and note it as a known issue?

**Current best guess**: V1 accepts the attenuation and notes it as a known issue in `docs/specs/capture.md` and the README. The target audience runs on MacBook Air-class devices with 1 pair; the attenuation is invisible to them. Power users with multi-pair interfaces are a V0.2 audience.

**Resolution path**: Deferred. A V0.2 ADR can document a compensation hook (a per-source gain that defaults to 0 dB and can be set per the user's device).

**Revisit trigger**: A V1 user reports the issue or V0.2 planning begins.

---

## U-005: Bundled ear-test input source licensing

**Status**: Resolved (ADR-008)
**Triggered by**: Phase 2 ear test harness design.
**Question**: The ear test harness uses a 30-second F1 onboard clip as input. Is there a freely-licensable source for this, or does the user need to provide one personally?

**Current best guess**: Resolved by ADR-008. The harness defaults to a synthetic test signal (pink noise + sine sweep + test tones); the user provides a personal clip via `--input` for the aesthetic ear test. No bundled audio, no licensing risk.

**Resolution path**: Resolved by ADR-008 — `docs/decisions/ADR-008-ear-test-input-source.md`.

**Revisit trigger**: If the synthetic default is insufficient to verify the chain is working correctly at the technical level (i.e., the user reports the synthetic output doesn't tell them whether the chain is broken or just rendering pink noise weirdly). In that case, the orchestrator can revisit with a different synthetic signal or a different bundled CC-licensed clip.

---

## U-006: Codex review re-trigger pattern

**Status**: Open
**Triggered by**: Phase 0 and review-protocol design.
**Question**: After pushing fixes for Codex review findings, does Codex auto-re-review or does the orchestrator need to re-post `@codex review`? Documentation suggests manual re-trigger but behavior may have changed.

**Current best guess**: Manual re-trigger. The orchestrator posts `@codex review` after the final round of fixes before requesting verification.

**Resolution path**: Verify during Phase 0's no-op PR cycle.

**Revisit trigger**: First Codex review during Phase 0.

---

## U-007: Snapshot test stability across macOS versions

**Status**: Open
**Triggered by**: Phase 3 design.
**Question**: SwiftUI snapshot tests are known to drift between macOS minor versions (different default fonts, slight layout changes). How brittle will the snapshot tests be in practice?

**Current best guess**: Pin CI to a specific macOS runner version and accept that snapshot updates are needed when the pin is bumped. Document the pin in `coding-standards.md` and as a CI comment.

**Resolution path**: Phase 3 implementation. If snapshots prove too brittle, the orchestrator may swap them for a smaller set of accessibility-tree-based tests that are more stable across versions.

**Revisit trigger**: Phase 3 testing.

---

---

## U-008: macOS audio capture permission location and entitlements

**Status**: Open
**Triggered by**: Framing audit F-007 (`docs/audits/framing-audit-001.md`).
**Question**: (a) Which exact System Settings pane on the orchestrator's macOS version controls the audio capture permission for tap-n-filter, and what is its deep-link URL? (b) For an unsandboxed hardened-runtime app using Core Audio Process Taps, what (if any) entitlements does Apple's current documentation require?

**Current best guess**: (a) Recent macOS minor versions surface a distinct "Audio Capture" or "Audio recording" pane separate from Microphone in Privacy & Security. The bundle's scribed-as text referred to "Microphone" which appears to be stale. (b) `com.apple.security.device.audio-input` is the microphone-hardware entitlement for sandboxed apps and likely does nothing for an unsandboxed app using process taps. No process-tap-specific entitlement is documented in the public Apple developer reference at scribing time; `NSAudioCaptureUsageDescription` in `Info.plist` is the binding control.

**Resolution path**: (a) Resolved during Phase 1 when the orchestrator runs the app on the build machine and observes which pane lists tap-n-filter. (b) Resolved during Phase 4 when the orchestrator verifies entitlement requirements against Apple's current notarization documentation. Both resolutions update `docs/specs/capture.md` and `docs/orchestration/phases/04-polish-release.md` to match observed behavior.

**Revisit trigger**: Phase 1 permission-flow implementation (part a); Phase 4 signing setup (part b).

---

## U-009: Snapshot test baselines auto-bootstrap on missing files

**Status**: Closed by ADR-015 (`docs/decisions/ADR-015-snapshot-baseline-environment-deviation.md`).
**Triggered by**: Codex review on PR #7 (`Tests/UISnapshotTests/SnapshotHelper.swift`).
**Question**: `SnapshotHelper.assertSnapshot` originally wrote a fresh baseline PNG on the first run when no baseline was present, then asserted byte-equality on subsequent runs. In CI on a clean checkout with no baseline images committed, every run wrote a baseline and passed — the snapshot tests therefore never caught a visual regression on first push. Generating cross-runner-stable baselines locally is blocked: only Command Line Tools are installed on the build host, so `swift test` cannot run the snapshot target locally, and CI runners differ enough in font rendering / color profile that baselines captured on one runner can fail byte-equality on another (U-007 covers the broader drift question).

**Resolution**: PR #7 round 2 (commit `14b240b`) made strict mode the default — missing baseline → `XCTSkip` with a regen instruction message, opt back into write-on-missing via `TNF_SNAPSHOT_REGEN=1`. The Phase 3 verification rerun (per `docs/audits/verification/phase-3-rerun-1.md`) flagged that `XCTSkip` is still not enforcement and required the deviation to be promoted from this U-log entry to an ADR. ADR-015 records the accepted env-bounded deviation; this entry is closed in favour of that ADR. V0.2's resolution path (dedicated `record-snapshots` CI workflow + automated baseline PR) is documented in ADR-015's "Consequences" section.

---

## U-010: Source resolution falls back to bundle ID, not PID

**Status**: Resolved — commit `14b240b` on PR #7; bundle fallback narrowed by the source-identity update on PR #26 (2026-10-20).
**Triggered by**: Codex review on PR #7 (`Sources/ViewModel/AppViewModel.swift` `powerOn`).
**Question**: `AppViewModel.powerOn` originally re-resolved the user's selected source from the live HAL list by `bundleIdentifier`. If two processes with the same bundle ID were running (multiple instances of the same app), the resolver could pick a different PID than the one the picker selection identified, capturing the wrong instance.

**Historical resolution (PR #7)**: `powerOn` used `candidates.first(where: { $0.pid == source.pid }) ?? candidates.first(where: { $0.bundleIdentifier == source.bundleIdentifier })` — PID first, bundle ID only as a fallback for the relaunch-between-pick-and-start case. The original V0.2 deferral was unnecessary; the change was contained to two lines.

**Source-identity amendment (PR #26, 2026-10-20)**: Exact live PID still wins,
including for bundle-less sources. When that PID is absent, fallback requires
a nonempty bundle ID and a unique display-name match; ambiguous or missing
matches do not start capture and ask the user to choose the source again.
Session restoration uses the saved bundle ID and display name; legacy bundle-only
sessions restore only a unique live bundle match. Display names discriminate
candidates without guaranteeing stable identity. See
[Source identity and session restoration](../specs/ui.md#source-identity-and-session-restoration).
Responsible-parent resolution and process-ancestry heuristics remain deferred.

---

## Future entries

The orchestrator appends new entries during build whenever an open question surfaces that's substantial enough to record. Examples:

- A Core Audio API behavior that's not documented and isn't yet certain.
- A choice between two implementation approaches where the right pick depends on empirical evidence the orchestrator doesn't yet have.
- A V0.2 design choice that affects V1 architecture and needs to be flagged for revisiting.

Entries that are resolved during build are updated in place (status changed, link to resolving ADR or commit added) but never deleted.

---

## U-011: AppError collapses domain failures into UI-ready strings

**Status**: Open — deferred to V0.2.
**Triggered by**: CodeRabbit review on PR #7 (`Sources/ViewModel/AppViewModel.swift` `AppError`).
**Question**: `AppError` keeps `.capture(CaptureError)` structured but collapses `.graph`, `.parameter`, `.preset`, `.engine`, and `.persistence` into `String` payloads. That loses typed context the lower layers know (which preset, which parameter ID, which engine subsystem) and hard-codes presentation into the view-model's public API — any future consumer that wanted to react programmatically to "preset deserialization vs. preset migration failed" has to string-match.

**Current best guess**: For V0.1.0 the collapse is acceptable. Every error of these kinds funnels into the same `lastError` slot and the same UI surface (the debug-log panel + the header status pill); no consumer programmatically discriminates between the variants today. The lower-layer errors (`GraphError`, `PresetError`, `AVAudioEngine`'s `NSError` payloads) all reach the AppError construction site, so the typed payloads exist — they just don't propagate through.

**Resolution path**: V0.2 promotes each variant to a typed payload mirroring `.capture(CaptureError)`'s pattern: `case graph(GraphError)`, `case preset(PresetError)`, `case parameter(ParameterError)`, `case engine(EngineError)`, `case persistence(PersistenceError)`. UI surfaces continue rendering through `userMessage` (which would dispatch over the typed payload), but any V0.2 UI that wants to discriminate (a "Retry preset migration" button, a "Pick a different source" hint) can pattern-match the typed values.

**Revisit trigger**: V0.2 work that touches `AppViewModel`'s error surface — preset migration UI, or any user-facing affordance that branches on the kind of failure.

---

## U-012: Orphan-cleanup matches by UID prefix with no ownership/liveness check

**Status**: Open — deferred to V0.2.
**Triggered by**: Codex review on PR #10 (`Sources/Capture/CaptureController.swift` orphan-cleanup pass, EXP-030).
**Question**: The defensive orphan cleanup that runs at `CaptureController` init enumerates aggregates/taps and destroys everything matching the global `tap-n-filter.aggregate.` / `tap-n-filter.tap.` UID prefix, with no check that the owning process is dead or that this controller owns the resource. If a second app instance, a helper, or a test controller is created while an existing capture is running, the new instance's cleanup would tear down the first instance's *active* aggregate/tap and interrupt capture.

**Current best guess**: Acceptable for V0.1.0. tap-n-filter ships as a single-instance menubar app, so two live controllers contending for the same prefixed resources is not an expected runtime configuration. The `UserDefaults` `tap-n-filter.disableOrphanCleanup=true` escape hatch already exists for anyone who hits trouble (e.g., running the app alongside an integration-test harness). The cleanup's purpose — reclaiming aggregates/taps leaked by a *crashed prior run of this same app* — is served by prefix matching because a crashed run leaves no live owner.

**Resolution path**: V0.2 adds an ownership/liveness marker so cleanup only reclaims genuinely-orphaned resources. Options: embed the owning PID in the aggregate UID (`tap-n-filter.aggregate.<pid>.<uuid>`) and skip destruction when that PID is still alive; or check `kAudioDevicePropertyDeviceIsRunning` on each match and never destroy a running device; or take a per-launch lock file the cleanup consults.

**Revisit trigger**: any work that makes multiple concurrent capture controllers a real configuration (a helper process, a second window, automated tests that run capture against the live HAL), or a bug report of capture stopping when a second tap-n-filter-adjacent process launches.

---

## U-013: Per-tab audio filtering parked behind a browser-extension spike

**Status**: Open — parked (outside the tap-based architecture); see ADR-020.
**Triggered by**: V0.2 targeting-granularity planning (ADR-020).
**Question**: ADR-020 establishes that per-tab audio isolation is impossible via Core Audio process taps (PID-granular; browsers mix all tabs into one shared output process — Safari `WebKit.GPU`, Chrome audio service, Firefox parent cubeb). The only path to genuine per-tab filtering is a browser extension intercepting the tab's in-page Web Audio / media graph. Whether that path is worth building, and whether it can clear a useful bar, is unresolved.

**Current best guess**: Not worth building as part of the tap-based product. The extension route works on cooperating (Chromium) browsers only, cannot touch native apps, goes silent on DRM-protected media (Netflix/Widevine, Spotify Web Player), and reimplements the effect chain in Web Audio rather than reusing the `AVAudioEngine` DSP. It is a separate product surface.

**Resolution path**: If revisited, a pre-registered spike must demonstrate either (1) a distinct per-tab audio PID exists for the target browser and a tap on it isolates that tab [predicted: false], or (2) for the extension route, that a WebExtension can intercept a tab's Web Audio/`<media>` graph, apply effects, and play back — while quantifying the DRM failure and the per-browser support matrix. Either path gets its own ADR. A secondary undocumented question surfaced during research: whether two same-origin Safari "Add to Dock" web apps run as separate renderer processes (separately tappable) or coalesce — relevant only to the deferred in-app per-site launcher, not to the per-tab verdict.

**Revisit trigger**: a future macOS/browser that splits tab audio into distinct output processes; a decision to build the in-app per-site launcher (which needs the same-origin coalescing question answered); or sustained user demand for per-tab that justifies a separate extension product.

---

## U-014: Accessibility dump never exercises conditional controls

**Status**: Open — deferred; blocked on a build host that can compile the UI target.
**Triggered by**: Codex review on PR #21 (`Sources/UI/PowerToggle.swift`).

**Question**: The ADR-011 accessibility audit rests on a committed artifact,
`test-artifacts/phase-3-accessibility-tree.json`, produced by the
`tap-n-filter-a11y-dump` executable. That executable hosts a single
`AppViewModel` in its default idle state with no error published. Every control
that renders conditionally is therefore absent from the artifact — including the
error banner and its dismiss button added in PR #21, and any future
error-, transition-, or drawer-gated affordance. `AccessibilityTreeTests`
validates the artifact, so it cannot catch a missing or empty label on a control
that the dump never rendered. The audit's coverage is narrower than it reads.

**Current best guess**: The dump renders at minimum idle, running, and
failed-with-error, emitting either one artifact per state or one artifact with a
per-state section. The mechanism is available: the
dump's `MockCapture` can be made to throw from `start`, which drives
`powerOn()` down its failure path and publishes `lastError`, since that property
is `private(set)` and cannot be set from outside the view model.

**Why deferred rather than fixed in PR #21**: applying the change means
regenerating the committed JSON artifact, which means running the dump
executable, which means compiling the UI target. The maintainer's host has
Command Line Tools only, so `swift build` fails on the SwiftUI macro plugins and
the artifact cannot be regenerated here. Landing a dump change without the
regenerated artifact would leave the committed evidence inconsistent with the
tool that produces it — worse than the gap it closes.

**Resolution path**: On a host with full Xcode (or a CI job that regenerates and
commits the artifact), extend the dump to cover the three states, regenerate,
and extend `AccessibilityTreeTests` to assert that the error-state controls carry
non-empty labels. A CI regeneration lane would also close the related snapshot
baseline gap in ADR-015, which is blocked on the same missing capability.

**Revisit trigger**: Xcode becomes available on the build host; or the CI
artifact-regeneration lane contemplated in ADR-015 and ADR-022 is built; or a
VoiceOver user reports an unlabelled control in a conditional state.

## U-015: EQ band parameters intermittently read back at their minimum

**Status**: Open — cause unidentified; observed once, not reproduced.
**Triggered by**: a macos-15 CI failure of
`GraphTests.test_snapshot_restore_roundtrip_preserves_chain` on PR #22
(run 30681407164).

**Question**: The test set `hp.frequency` to 100 Hz, round-tripped a graph
through JSON, and asserted the restored node reported 100 Hz. It reported 20.0 —
which is simultaneously the `hp.frequency` catalog lower bound and the
`AVAudioUnitEQ` band frequency minimum. The macos-14 and macos-26 legs of the
same run passed.

The obvious reading was a regression from the resonant-filter change in #23,
which had just landed underneath that branch. That reading is wrong. A
diagnostic branch (PR #24) instrumented every boundary — the audio-unit write,
`snapshot()`, the encoded JSON, the decoded parameters, the restored readback,
and the two-node shape the failing test uses — and all three legs came back
clean, macos-15 included:

```
[15] B.afterSetFrequency hp.freq=Optional(100.0)
[15] D.snapshot  params=[... "hp.frequency", value: 100.0 ...]
[15] F.decoded   params=[... "hp.frequency", value: 100.0 ...]
[15] G.restored  hp.freq=Optional(100.0)
```

Re-running the originally failing job at its identical SHA then passed. Same
tree, both outcomes: the failure is intermittent, and no layer of the
save/restore path loses the value on a good run.

**Current best guess**: the underlying `AUNBandEQ` audio unit occasionally fails
to instantiate or configure under CI resource pressure, leaving band parameters
at their minimums, so `configureEQBands()`'s writes are discarded. That would
produce exactly 20.0 and would be load-independent of the code path — which
matches the evidence. This is conjecture: nothing has been measured that
distinguishes it from a toolchain-specific `AVAudioUnitEQ` bug on the 15.7.7
image, and a single unreproduced observation cannot separate them.

**Why it matters beyond the test**: if an `AVAudioUnitEQ` can silently come up
unconfigured, the shipping app has the same exposure — the user would get an EQ
whose cutoffs sit at the band minimums with no error surfaced. The test is the
only place this has ever been seen, and it may well be CI-only, but the failure
mode is invisible by construction and would be reported as "the EQ does
nothing."

**Resolution path**: make the condition self-reporting rather than chasing a
reproduction. Every path that writes a band frequency — `configureEQBands()` at
init and `restore(from:)` when loading a preset — now reads the value back,
records any mismatch in `EQNode.configurationWarnings`, and logs it to the
unified log at the point of detection. The restore path is the one that matters
most: the failure above was observed there, on the 100 Hz preset write, not on
the 80 Hz default, so a check that ran only at construction would have stayed
silent for the case actually seen. The log call is the load-bearing part: recording the
warning on the instance alone would be invisible, because the only production
reader of `debugStateDescription()` is a wet/dry or bypass change, so a node
that comes up misconfigured and is never touched again would leave no trace.
The roundtrip assertion also dumps full band state on failure, so the next CI
occurrence arrives with evidence rather than a bare diff.

**Revisit trigger**: a second occurrence in CI; any user report of an EQ that
appears to do nothing or to sit at its lowest cutoff; or a macOS release that
changes `AVAudioUnitEQ` instantiation behaviour.
---

---

## U-016: The stranded-input marker may not survive the crash it exists for

**Status**: Open — deferred to the HFP wiring PR, where the risk first becomes
reachable.
**Triggered by**: CodeRabbit review on PR #20 (`Sources/Capture/DefaultInputGuard.swift`).

**Question**: `DefaultInputGuard` persists the pre-switch default-input UID with
`UserDefaults.set` immediately before switching the system default input, so a
crash mid-capture can be recovered on the next launch (EXP-037 diagnostic D4).
`UserDefaults.set` updates the in-process store synchronously and forwards the
change to `cfprefsd` asynchronously. A crash inside that window — after the
device switch has landed but before the flush — leaves no marker, and launch
recovery has nothing to restore from. The user stays on the replacement input
with no path back except System Settings.

That is precisely the stranding ADR-019 names as a ship-blocker, reached by the
exact failure mode the marker was introduced to cover. `synchronize()` is not the
answer: it is deprecated and Apple documents it as unnecessary rather than as a
durability guarantee.

**Current best guess**: the window is short — `cfprefsd` receives the write
promptly under a normal run loop — so the joint probability of a crash landing
inside it is low. Low is not zero, and the consequence is the blocker rather than
a degraded experience, so this should not rest on the window being small.

**Why deferred rather than fixed in PR #20**: the guard has no call sites. It is
Layer B-core only; nothing calls `engageIfNeeded`, so no switch is ever performed
and there is no marker to lose. The risk becomes live exactly when the wiring PR
connects the guard to `powerOn`/`powerOff`, which is also where crash recovery
first becomes testable. Changing the persistence mechanism now would alter the
storage named in the EXP-037 pre-registration while the experiment is mid-flight,
without the integration that would let the change be verified end to end.

**Resolution path**: write the marker to an atomic file
(`Data.write(to:options:.atomic)`) in Application Support before the switch, and
treat that file as the record of truth, with the `UserDefaults` key kept in step
so the pre-registered key name and the D4 diagnostic stay valid. The write must
complete before `setDefaultInputDeviceID`, mirroring the current ordering. A
recovery test should assert that a marker written but never flushed through
`UserDefaults` is still found on the next launch.

**Revisit trigger**: the HFP wiring PR; or any report of a user stranded on the
wrong input after a crash.

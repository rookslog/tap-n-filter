# Changelog

Notable changes to tap-n-filter. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Build history before the first release is recorded per phase under
`docs/orchestration/state.json` and per decision under `docs/decisions/`.

## [Unreleased]

Work toward v0.1.0. Nothing has been tagged or released yet.

### Added

- Audio capture from a chosen application via Core Audio process taps, with a
  direct IOProc reader and a single-lock SPSC ring buffer (ADR-018). The
  buffer guards each read and write with an `OSAllocatedUnfairLock` over a
  bounded copy; a genuinely lock-free implementation is deferred to V0.2 and
  gated on measured glitching.
- Configurable effect graph: a two-band resonant EQ, a reverb built on
  `AVAudioUnitReverb`'s factory presets, and a gain stage, each with bypass.
  Wet/dry mixing is per node and applies where it is meaningful; `GainNode`
  declares `supportsWetDry = false`, and the EQ hides the control by default
  (ADR-007). Convolution with custom impulse responses is future work, not
  shipped here.
- Always-on output limiter, not user-defeatable, which prevents the graph from
  clipping above 0 dBFS (ADR-021). It bounds digital peak level, not loudness:
  a gain stage can still raise a quiet source by up to +12 dB without reaching
  the limiter threshold, so it is not a hearing-safety guarantee.
- Menubar control panel: source picker, chain editor with button-based reorder
  (ADR-013), power toggle, status pill, and a debug log panel.
- Preset save and load as `.tnf` JSON files, plus the bundled `distant-engines`
  and `dry` factory presets.
- "Preserve Bluetooth quality during capture" setting (ADR-019, Layer A).

- Release bundler producing a `.app` and a compressed `.dmg`. See the signing
  note under Known limitations for what the produced artifact is signed with.
- Accessibility labels, values, and hints across every control, with a
  committed accessibility-tree artifact and tests enforcing label discipline
  (ADR-011).

### Deferred to V0.2

- The `submerged` and `next-room` factory presets. Four presets were scoped for
  V1 and cut to two (`distant-engines`, `dry`) during the framing audit, because
  only the shipped pair had a documented design rationale and ear-test budget.
  README and `docs/specs/preset-format.md` both point here for this deferral.

### Fixed

- Future-format session graphs now produce a recoverable load warning instead
  of trapping. The version header is checked before decoding current graph
  fields, so changed future schemas also retain protection. The app uses
  `distant-engines` while preserving original session
  bytes through source-only persistence, failed edits, and no-ops. A successful
  explicit graph change resumes autosave and replaces the incompatible session.
  `PresetMigrator.migrate` now throws a typed unsupported-version error; existing
  EQ Q repair and reverb extras behavior are preserved.
- Menu panel collapsed on macOS 27, taking the effect list with it. The chain
  editor's `ScrollView` was constrained only by `maxHeight` inside a window
  that sizes to its content's fitting height; height floors now keep the panel
  usable across OS versions (ADR-022).
- Interleaved tap buffers were mishandled, corrupting captured audio.
- Source resolution preferred bundle identifier over pid, so with several
  instances of one app running it could capture the wrong process.

### Known limitations

- **Not notarized.** v0.1.0 ships without Developer ID signing or
  notarization, so Gatekeeper blocks the first open and the README documents
  the right-click-Open workaround. `Build/release-bundle.sh` signs ad-hoc
  (`-`) unless a self-signed codesigning identity is present on the build
  host, in which case it uses that instead; neither satisfies Gatekeeper on
  another machine. Developer ID is deferred (ADR-017).
- **Process granularity only.** Targeting is per-application; per-tab and
  per-window filtering are not achievable through process taps (ADR-020).
- **Bluetooth headsets may drop to HFP.** Capture can cause macOS to switch a
  Bluetooth device to the call profile, degrading audio to phone quality. The
  Layer A setting is shipped; the Layer B auto-switch mitigation is under
  active investigation (`docs/investigations/2026-05-audio-pipeline.md`).
- **No macOS 27 CI coverage.** GitHub Actions offers no macOS 27 runner, so
  the newest-OS check is a manual pre-merge step on the maintainer's machine
  (ADR-022).

[Unreleased]: https://github.com/rookslog/tap-n-filter/commits/main

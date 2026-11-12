# Architecture

tap-n-filter is a macOS menubar app that captures audio from a selected application via Core Audio process taps, runs the captured stream through a configurable graph of audio effects, and plays the result to the default output device.

This document describes the overall structure. Sub-specs cover each layer in more detail.

## Current Quick Menu branch

The current app uses the library owner and session store, coherent menu snapshots,
per-app playback assignments, and the fixed native renderer. The earlier Graph
and preset modules remain in the package for legacy consumers and tests. They
are not the Quick Menu app's authoring or audio owner.

The current delivery is a built-in-only Quick Menu candidate. Its enhanced
Everyday sound has option-qualified sub-controls; Filters remains available.
The normal Quick Menu does not offer an editor entry. Editor source remains in
the package, but this candidate is not a full-editor release.

See [Quick Menu development](../quick-menu-development.md) for the current source,
data and test boundaries. The [first model unit](block-model.md) and
[document-command slice](document-commands.md) are historical implementation
snapshots, not the current library API or archive contract.
[ADR-023](../decisions/ADR-023-apple-silicon-audio-execution.md) records proposed
Apple Silicon scheduling and analysis policy with unmeasured comparisons.

The remaining sections describe the earlier Graph-based application.

## System overview

```
                  ┌──────────────────────┐
                  │  Source Application  │ (Safari, Music, etc.)
                  └──────────┬───────────┘
                             │ audio output
                             ▼
            ┌──────────────────────────────────┐
            │  Core Audio Process Tap          │  (system layer)
            │  CATapDescription                │
            │  AudioHardwareCreateProcessTap   │
            └──────────────┬───────────────────┘
                           │
                           ▼
            ┌──────────────────────────────────┐
            │  Aggregate Device wrapping tap   │  (system layer)
            └──────────────┬───────────────────┘
                           │
                           ▼
            ┌──────────────────────────────────┐
            │  AVAudioEngine inputNode         │  (app layer)
            └──────────────┬───────────────────┘
                           │
                           ▼
            ┌──────────────────────────────────┐
            │  Effect Graph                    │
            │                                  │
            │   EQ Node  ──>  Reverb Node      │
            │                                  │
            │  (per-node wet/dry mixing,       │
            │   ordered chain)                 │
            └──────────────┬───────────────────┘
                           │
                           ▼
                  output trim (Graph.outputGain)
                           │
                           ▼
              safety limiter (always-on, ~0 dBFS, ADR-021)
                           │
                           ▼
                  mainMixerNode  →  outputNode (default speakers)
```

The app is a single process. There is no helper daemon, no XPC service, no kernel extension.

The output trim and the safety limiter are fixed stages owned by `Graph`, not user effects in the chain. The always-on `PeakLimiter` holds the output near 0 dBFS so neither a hot source, a boosting effect, nor a user-dialed `GainNode` can clip the output device. See `docs/decisions/ADR-021-output-safety-limiter.md`.

## Module layout

Top-level Swift modules:

| Module | Responsibility |
|---|---|
| `tap_n_filter` (app target) | App entry, scene composition, `MenuBarExtra`. |
| `Capture` | Core Audio process tap, aggregate device, bridge to `AVAudioEngine`. |
| `Graph` | The `Graph` type and `EffectNode` protocol. |
| `Effects` | Concrete effect implementations (`EQNode`, `ReverbNode`, `GainNode`). |
| `Presets` | `GraphPreset`, `PresetStore`, bundled presets. |
| `UI` | SwiftUI views, view model. |

Lower-level utilities (logging, error wrappers, helpers) live alongside their primary consumer rather than in a shared `Utilities` module.

## Threading model

- **Main thread** owns the UI and the view model.
- **Audio thread** is managed by `AVAudioEngine`. The orchestrator does not call into audio-thread code from the main thread except via the engine's safe-update APIs (`engine.attach`, `engine.connect`, etc.) called while the engine is paused.
- **Capture thread(s)** are managed by Core Audio. Buffer callbacks fire on a CoreAudio-internal queue and are bridged into the engine via the aggregate device.

The view model communicates with `CaptureController` via Combine publishers. State changes are observed on the main queue.

Locking: no manual locks. Concurrency is managed by Swift's structured concurrency (`async`/`await`) for setup/teardown, and by `AVAudioEngine`'s own synchronization for the live signal path. Parameter changes from the UI to effect nodes are written to `AVAudioUnit` parameter values, which are safe to update from any thread.

## Lifecycle

1. App launches. SwiftUI scene starts. The `MenuBarExtra` icon appears.
2. The view model initializes with the default graph (empty if no last-session state, otherwise the persisted state).
3. The user opens the menubar dropdown. The control panel renders.
4. The user selects a source. The view model creates a `CaptureSource` from the selection.
5. The user clicks the power toggle.
6. The view model asks `CaptureController` to start the capture for the selected source, passing in the configured `AVAudioEngine` instance.
7. `CaptureController` creates a tap on the source process, creates an aggregate device, configures the engine's input node to read from that device, starts the engine, and reports `.running`.
8. Audio flows: source → tap → aggregate device → engine input → graph → mixer → output.
9. The user adjusts parameters. The view model writes new values into the relevant effect nodes. Changes are audible in real time.
10. The user toggles power off. `CaptureController.stop` is called. The engine pauses, the aggregate device and tap are released, the source app's normal output resumes.

## Permission model

The app requests one permission: audio capture, granted via the system prompt triggered by the first call to `AudioHardwareCreateProcessTap`. The prompt's text comes from the `NSAudioCaptureUsageDescription` value in `Info.plist`.

No microphone, camera, screen recording, location, or contacts access. The app does not network. The app does not read or write files outside its sandbox-equivalent paths (`~/Library/Application Support/tap-n-filter/`, `~/Library/Preferences/`, and wherever the user saves `.tnf` files via the open/save panels).

## Sandbox

The app is **not sandboxed** in V1. See `docs/decisions/ADR-003-no-sandbox-v1.md`. This decision preserves the path to AUv3 plugin hosting in a future version. The trade-off: no Mac App Store distribution in V1. The app is distributed as a signed, notarized DMG instead, which is acceptable for the V1 audience.

## Persistence

The app uses two locations:

- `UserDefaults` for last-session state (current graph, last source, UI preferences).
- The Application Support directory at `~/Library/Application Support/tap-n-filter/` for any future state that's too large for UserDefaults (custom IRs, user-imported presets). V1 doesn't write here yet; the directory is created lazily.

User-saved presets are explicit `.tnf` files at user-chosen paths (typically `~/Documents/` or `~/Music/`). The app does not auto-save user presets anywhere.

## Extension points

The architecture commits to the following extension points for future versions:

1. **New effect types** — anything conforming to `EffectNode` can be added to the graph. V1 ships EQ and Reverb. Adding a new effect is one new Swift file plus registering its `typeIdentifier` with the preset deserializer.

2. **AUv3 plugin hosting** — reserved for V2. A future `AUv3Node: EffectNode` wraps a hosted AUv3 unit. The architecture does not include the loader in V1, but the protocol surface accommodates it.

3. **Custom IRs for reverb** — reserved for V2 unless the V1 ear test fails on factory IRs. A future `ConvolutionNode: EffectNode` would replace or supplement `ReverbNode` with `AVAudioUnitEffect`-based convolution or an `Accelerate.vDSP_conv` implementation.

4. **Preset registry** — V2 may add an in-app preset browser that pulls from a GitHub-hosted index of community presets. The `.tnf` format is designed to be shared as plain text files; a registry layer would only add discovery.

5. **Multi-source capture** — V2. The architecture allows the engine to be configured with multiple input buses if a future `MultiSourceCaptureController` is built; V1 hard-codes single-source.

## Constraints and non-goals

- **Latency.** V1 is for ambient listening, not real-time monitoring. Round-trip latency of 50–100ms is acceptable. The architecture doesn't optimize for sub-10ms latency.
- **Targeting granularity.** The finest unit the app can target is an OS process (one PID). The addressable hierarchy is System (all audio) → app-group (all PIDs of one app) → single process. Per-window and per-tab capture are out of scope: a process tap is PID-granular, and browsers mix every tab's audio into one shared output process (Safari `WebKit.GPU`, Chrome's audio service, Firefox's parent cubeb server) before any tap reaches it. See ADR-020. A user who wants to isolate one site can split it into its own process (Safari "Add to Dock", or a separate Chrome/Firefox instance), which the tap then captures as a distinct source.
- **Channel count.** V1 supports stereo only. Multi-channel (5.1, Atmos) is out of scope.
- **Sample rate.** The engine runs at the aggregate device's native sample rate (typically 44.1 or 48 kHz depending on the source). The graph is sample-rate agnostic.
- **Cross-platform.** V1 is macOS only. No iOS, no Linux, no Windows. The Core Audio process tap API is macOS-specific.
- **Recording.** V1 does not record processed output to a file. (V0.2 may add an "export rendered output" feature.)

## Open architectural questions

Tracked in `docs/decisions/uncertainty-log.md`. Notable entries seeded at scribing time:

- The exact bridging strategy from Core Audio process tap to `AVAudioEngine` (aggregate-device vs raw HAL callback). ADR-001 commits to AudioCap's pattern; uncertainty log captures the fallback.
- Whether `AVAudioUnitReverb` factory presets are sufficient or whether custom IR convolution is needed for V1's aesthetic. Phase 2's ear test resolves this.
- Whether `MenuBarExtra` can host modal panels (Save / Open) without workarounds on macOS 14.4. Phase 3 verifies.

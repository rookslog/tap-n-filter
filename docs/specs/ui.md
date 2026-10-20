# UI

The UI is a SwiftUI `MenuBarExtra` window. The user opens it by clicking the menubar icon. It hosts the full control surface: source selection, effect chain, parameter controls, preset I/O, power toggle.

This document specifies structure, behavior, and the view-model boundary. Visual styling details (exact colors, fonts, paddings) are left to the implementation, with the constraint that the result reads as a native macOS app, not a port from another platform.

## Window

```
MenuBarExtra("tap-n-filter", systemImage: "waveform")
    .menuBarExtraStyle(.window)
```

`.window` style (as opposed to `.menu`) gives us a fixed-width popover with arbitrary SwiftUI content. The menu style is too constrained for sliders and chain editing.

Width: 380pt. Height: dynamic, capped at 700pt, floored at 420pt. The cap rises to 900pt while either drawer below the footer is open — the settings section or the debug panel — because both add a section the 700pt cap would otherwise squeeze out of the chain editor. Above the cap the chain editor scrolls. The chain editor's own scroll region is capped at 440pt. These were widened from the original 320×600 because the chain editor's per-row header (chevron, reorder, name, bypass, wet/dry, remove) was too cramped to add and customize filters comfortably.

The icon in the menubar reflects state:
- `.waveform` when idle.
- `.waveform.path` when running.
- `.waveform.path.badge.minus` when failed.

## View hierarchy

```
ControlPanelView
├─ HeaderView (project name, settings affordance — V1: just title)
├─ SourcePickerView
├─ Divider
├─ ChainEditorView
│  ├─ EffectRow (for each node)
│  │  ├─ Header (name, bypass toggle, wet/dry slider, expand chevron, remove)
│  │  └─ EffectControlsView (when expanded)
│  └─ AddEffectButton
├─ Divider
└─ FooterView
   ├─ PresetMenu
   └─ PowerToggle
```

## State management

A single `AppViewModel: ObservableObject` owns:

```swift
@MainActor
public final class AppViewModel: ObservableObject {
    @Published var graph: Graph
    @Published var currentSource: CaptureSource?
    @Published var availableSources: [CaptureSource]
    @Published var captureState: CaptureState
    @Published var expandedEffectID: UUID?
    @Published var lastError: AppError?
    
    private let capture: CaptureControllerProtocol
    private let engine: AVAudioEngine
    
    public func setSource(_ source: CaptureSource)
    public func powerOn() async
    public func powerOff() async
    public func addEffect(of typeIdentifier: String)
    public func removeEffect(at index: Int)
    public func moveEffect(from: Int, to: Int)
    public func updateParameter(nodeID: UUID, paramID: String, value: Float)
    public func savePreset(to url: URL)
    public func loadPreset(from url: URL)
    public func loadFactoryPreset(named: String)
}
```

Views observe the view model via `@ObservedObject` (passed from the app root) or `@EnvironmentObject` (injected at the scene level).

The view model also runs a 5-second timer to refresh `availableSources` via `capture.availableSources()`.

## SourcePickerView

```swift
Picker("Source", selection: $viewModel.currentSource) {
    Text("Select a source").tag(Optional<CaptureSource>.none)
    ForEach(viewModel.availableSources) { source in
        SourceRow(source: source)
            .tag(Optional(source))
    }
}
```

`SourceRow` shows the app icon (from `NSWorkspace.shared.icon(forFile:)` or `NSRunningApplication.icon`) and the display name. The picker is disabled while `captureState` is `.starting` or `.stopping`. Changing source while `.running` triggers `viewModel.powerOff()` followed by re-setting the source, with the user invited to power on again — V1 does not auto-restart on source change, to avoid surprise.

### Targeting granularity and the no-tabs explainer

The picker lists sources at **process granularity** — one capturable OS process per row, which is the finest unit Core Audio process taps address (ADR-020). V0.2 groups these into tiers (System audio / app-group with a process count / single process); V1 shows the flat per-process list.

The picker must not imply a granularity the OS cannot deliver. Where a user looks for per-tab or per-window targeting, the picker surfaces an explainer rather than a control:

> macOS captures audio per app. Browser tabs share one process, so they can't be separated. To filter one site on its own, use Safari's **File → Add to Dock** (or launch it as a separate Chrome/Firefox instance) — it then appears here as its own source.

This is the only honest answer to the reframed "filter one tab" goal: the whole app is filterable, and a site can be carved into its own process by the user, but one tab among many cannot be isolated.

## ChainEditorView

Vertical `LazyVStack` (or `List` if drag-and-drop reordering is desired and `LazyVStack` proves awkward) of `EffectRow` views. Each row's expand state is governed by `viewModel.expandedEffectID` — only one effect is expanded at a time, to keep the panel height bounded.

Below the list, the "Add Effect" button presents a `Menu`:

```swift
Menu("Add Effect") {
    Button("Parametric EQ") { viewModel.addEffect(of: "tnf.eq") }
    Button("Gain") { viewModel.addEffect(of: "tnf.gain") }
    Button("Reverb") { viewModel.addEffect(of: "tnf.reverb") }
}
```

The menu's contents are sourced from `EffectNodeRegistry.shared`, so adding a new effect type to the registry automatically adds it to the menu.

## EffectRow

```
┌──────────────────────────────────────┐
│  ⏵ EQ      [ bypass toggle ]   ⋯  ⊗ │  (chevron, name, bypass, wet/dry, remove)
│                                      │
│  ┌────────────────────────────────┐ │
│  │ wet/dry: |═══════•════════| 70% │ │
│  └────────────────────────────────┘ │
│                                      │
│  [ expanded: EffectControlsView ]    │  (only when expanded)
└──────────────────────────────────────┘
```

The chevron toggles expansion. The bypass toggle is a small SwiftUI `Toggle` styled minimally. The wet/dry slider is visible by default for nodes whose effect is time-domain (e.g., reverb, future delay, future distortion) — for these the wet/dry control is the most-used adjustment. For nodes whose effect is spectral-shaping (e.g., EQ), the wet/dry slider is hidden by default and accessible only via the expanded controls panel; the rationale is that wet/dry on an EQ at any value other than 1.0 partially defeats the filter, which is rarely what a user adjusting the slider expects. The trash icon removes the effect with confirmation (or with undo via a toast — V1 implements confirmation modal).

The decision of "show wet/dry by default" is per-node. Each `EffectNode` exposes a static property `showsWetDryByDefault: Bool` (default `true`) that the UI consults when rendering the `EffectRow` header. `EQNode` overrides this to `false`; `ReverbNode` uses the default `true`. See `docs/decisions/ADR-007-wet-dry-on-eq.md`.

A second flag, `supportsWetDry: Bool` (default `true`), distinguishes nodes that have no wet/dry concept at all. `GainNode` overrides it to `false`: a gain trim only scales level, so a partial wet/dry blend is meaningless. When `supportsWetDry` is `false` the UI suppresses the wet/dry control everywhere — both the row header and the expanded controls panel — rather than showing a slider that does nothing. See `docs/specs/effect-node-protocol.md`.

## EffectControlsView

For each `EffectParameter` in the node's `parameters`:

- `ParameterUnit.hertz`, `.decibels`, `.ratio`, `.seconds`, `.milliseconds`, `.normalized`, `.percent` → native continuous `Slider`, with a numeric readout showing the value and unit. Its normalized 0…1 position maps logarithmically for positive frequency ranges; all other units, including decibels, map linearly to the declared range. DSP/catalog values and ranges are unchanged.
- `ParameterUnit.integer` → `Stepper` with the range.
- `ParameterUnit.enumValue(cases: [String])` → `Picker`.

Drag changes are coalesced to the latest value every 33 ms on the main queue to avoid overwhelming the underlying `AVAudioUnit`'s parameter setter. The final drag value is delivered immediately when editing ends. Exact numeric commits and reset are immediate; queued drag callbacks carry a generation check and cannot overwrite a later commit, reset, model resync, or disappearing control.

Frequency readouts use Hz below 1000 Hz and readable kHz at and above it (e.g., "800 Hz", "1 kHz", "1.5 kHz"). Other continuous readouts keep their unit conventions. Nonfinite readback is diagnosed as invalid; out-of-range readback retains its actual value with a warning. Only the thumb is constrained to the legal range; the readout never silently substitutes an endpoint.

Each continuous parameter's expanded controls expose an **Exact value** field with a visible unit and a **Reset** button. The field seeds the full native Float precision rather than the rounded readout. Frequency entry is numeric Hz only; unit suffixes/group separators are rejected. The current locale's decimal separator is used for both seeding and parsing. Percent entry uses 0…100 display units and converts back to native 0…1 values. Inputs must be finite, wholly numeric, and within the declared range before Float rounding. Return applies; Escape or focus loss discards a draft; invalid submit shows an inline message and leaves the draft available for correction without writing. Reset writes the catalog default.

Programmatic/preset updates resync the thumb, draft, and readout without echo writes. Replacing a node object, even with the same saved UUID, creates a new editor and retires the old queued drag. An acknowledgement of the control's own write does not cancel a newer pending drag. Each continuous-control write notifies view-model observers, uses the existing `updateParameter` callback, and checks actual node readback even if a refused write leaves the previous value unchanged; no persistence or DSP contract changes are introduced.

Repeated identical invalid readback, including NaN, does not republish diagnostic state or overwrite a correctable draft. Starting an exact edit discards a still-pending drag and rereads the actual parameter value; Cancel/focus loss restores actual readback without writing. When a slider takes over text editing, a delayed field focus-loss callback does not cancel that slider movement.

Sliders retain native arrow-key adjustment and accessibility values. Exact-value fields and Reset buttons have parameter-specific accessible labels. A focused numeric field publishes a UI-only focused value that removes Power's unmodified-Space shortcut for the duration of text focus, without changing Start/Retry readiness or mouse/button behavior. Runtime focus, VoiceOver, and current-macOS layout checks remain manual pre-merge gates alongside full-Xcode tests.

## PresetMenu

```swift
Menu {
    Button("Save As…") { showSavePanel = true }
    Button("Open…") { showOpenPanel = true }
    Divider()
    Menu("Factory Presets") {
        ForEach(FactoryPresets.all, id: \.name) { preset in
            Button(preset.displayName) { viewModel.loadFactoryPreset(named: preset.name) }
        }
    }
} label: {
    Label("Presets", systemImage: "doc")
}
```

`showSavePanel` and `showOpenPanel` trigger `NSSavePanel` and `NSOpenPanel` presentations. From a `MenuBarExtra` window, the standard `.fileImporter` / `.fileExporter` SwiftUI modifiers may behave unreliably; the orchestrator falls back to direct `NSSavePanel.runModal()` from the AppKit layer if needed, documenting the chosen approach in an ADR.

## PowerToggle

A large prominent button at the bottom of the panel:

- `.idle` → label "Start", filled style, accent color.
- `.starting` → label with spinner, disabled.
- `.running` → label "Stop", outlined style.
- `.stopping` → label with spinner, disabled.
- `.failed` → label "Retry", with error icon, accent destructive color.

Tapping in `.idle` calls `viewModel.powerOn()`. Tapping in `.running` calls `viewModel.powerOff()`. Tapping in `.failed` clears the error and returns to `.idle`.

While `viewModel.lastError` is non-nil, a full-width error banner sits above the footer showing the message text in full, with a warning icon and a separate dismiss control. It is a sibling of the footer, not part of the power control: the footer lays its actions out in one centre-aligned row, and a multi-line banner nested inside `PowerToggle` would drag the presets and quit buttons out of alignment.

Dismissing the banner clears the message only, and what the status pill does next depends on which failure it was. After a stalled engine — capture still `.running` while the engine is stopped — the pill keeps reporting a failure, because `engineStalled` is deliberately independent of `lastError` and audio is genuinely not flowing. After a failed start, the state is `.idle` and `lastError` is the only record of it, so dismissing returns the pill to "Off". That is correct: nothing is running, and there is nothing left to warn about.

The banner replaced an earlier "error detail expander" next to the button. That control's only action was to clear the error — it destroyed the information its label advertised — and the message itself was reachable only through a hover tooltip, so a keyboard user could not reach it. VoiceOver users could hear it, since the button carried `.accessibilityValue(error.userMessage)`; the gap was discoverability for sighted and keyboard users. Rendering the text unconditionally costs vertical space only while an error is outstanding, and dismissal is now a distinct, labelled affordance rather than a side effect of asking for detail.

## Persistence

The view model serializes its state to `UserDefaults` on:
- Every graph mutation.
- Every parameter change (throttled).
- Every source change.
- On power on/off transitions.

Serialized blob keys:
- `lastSession.graph` — `GraphPreset` JSON.
- `lastSession.sourcePid` — Int (pid of last source).
- `lastSession.sourceBundleID` — String (preferred for restoration; pids change between launches).

On launch, the view model attempts to restore:
1. The graph from `lastSession.graph`. On failure, falls back to the bundled `distant-engines` preset.
2. The source from `lastSession.sourceBundleID`. If that bundle ID is running, sets it as `currentSource`. Otherwise leaves source unset.

The view model never auto-starts capture. The user always has to click Power.

## Accessibility

Every control has `accessibilityLabel` (what it is). Sliders and pickers have `accessibilityValue` (current value spoken).

Keyboard navigation:
- Tab cycles through interactive elements.
- Arrow keys adjust sliders (in increments of 1% of the range).
- Space toggles `Toggle`s and presses focused `Button`s.
- Cmd+S saves preset, Cmd+O opens preset (when the menubar window has focus).

VoiceOver audit: the orchestrator runs the app with VoiceOver enabled, reads through every control, and documents any rough edges in `docs/audits/verification/phase-3-accessibility.md`.

## Localization

V1 ships English-only. All user-facing strings live in `Localizable.strings`. No actual localization is performed; the file is structured so that adding a localization later is a translation-only change.

## Testing

- **Snapshot tests** under `Tests/UISnapshotTests/`. Capture `ControlPanelView` in three states (idle, running, failed) and compare against pinned baselines. macOS version pinned in CI.
- **View model unit tests** under `Tests/ViewModelTests/`. Tests for state transitions, persistence round-trip, error propagation. Uses a `MockCaptureController` and a fresh `AVAudioEngine`.
- **Manual checks** documented in the Phase 3 verification report: source change while running, add/remove/reorder effects with audio flowing, save preset → quit → relaunch → load preset → verify identical graph.

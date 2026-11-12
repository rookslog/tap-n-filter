# Block model, first implementation unit

Historical first-slice snapshot, retained for implementation context. Its
unimplemented-boundary statements describe that slice, not the current source.
See [Quick Menu development](../quick-menu-development.md) for the current branch.

Status: independently source-reviewed; bounded corrections locally checked.
Not yet connected to UI, persistence, capture or the native renderer.

## Ownership and shape

`Sources/SoundModel/` is a SwiftPM target with Foundation only. Its types remain
module-internal until the document/adapter boundary is integrated. It does not
construct an Audio Unit or device, read global preferences, or start work threads.

- `Position` rejects non-finite/out-of-range imported and authored values.
  Internal evaluation clamps only after addition, or for bounded arithmetic
  roundoff. Its custom decoder cannot bypass those checks.
- `Choice` retains permanent option IDs and stores its value as a normalized
  position, for any option count of two or more (A19). Two options represent a
  switch. Evaluation uses the nearest option's position, not a prototype integer.
- `MappingCurve` implements Curve, Straight, Ease and Step. Curve tangents use
  the prototype's bounded monotone construction, implemented as cubic Bezier
  coefficients. Inserting a waypoint subdivides the existing segment instead of
  recomputing neighboring tangents. Step jumps keep their absolute position.
- Persisted segments are authoritative. `settingValue(_:at:)` regenerates only
  incident stretches, preserving all nonincident segments even after an exact
  subdivision. A no-op preserves the entire curve. Do not edit a stored curve
  by rebuilding it with the new-curve constructor. Local edits can change
  tangency at a waypoint; continuous first derivatives are not an M1–M6 promise.
- `ControlWaypoints` stores scalar points or independent X/Y point lists. M6
  validates each mapping against its source axis, not against their union.
- `SoundBlock` stores an explicit mixed sequence of parts and child occurrences.
  It is inline authoring content for this unit, **not** a proposed library/save
  format. Typed UUIDs distinguish roots, child sites, parts, controls and options.
- `CompiledSound` lowers that sequence to ordered part addresses and complete
  normalized targets, against an explicit descriptor catalog. Duplicate raw
  entries remain arrays until validated; missing/unknown parameters are refused.
  Mappings add relative to the target's baseline and clamp once after addition.

Renaming is not represented in inline SoundBlock. The separate
[document owner](document-commands.md) now stores library/root-use naming and
explicit root-control overrides with grouped history. Reordering changes the part sequence but not
an address, which consists of root use, stable child-site path, part ID and
parameter key. Separate occurrences produce separate addresses, even when their
part IDs are the same. This establishes identity in pure data, not independent
native processors or per-app capture.

The compiler never sends its Swift arrays/dictionaries into a render callback.
Native preparation must lower complete targets to the bounded mailbox contract
before runtime integration. Parameter unit/domain conversion is still that
adapter's responsibility; normalized values are not dB, hertz or native setters.

## Run the checks

On a macOS machine with Swift Command Line Tools, without opening any app or
audio device:

```sh
python3 tools/check-sound-model.py
```

This compiles the actual module sources and the shared contract scenarios with
Swift 6 strict concurrency and optimization, then runs them headlessly. It does
not replace XCTest with a fake implementation. The same scenarios are called
by the actual XCTest adapter when that framework is available:

```sh
swift test --filter SoundModelTests
swift build --target SoundModel
```

Local Command Line Tools may lack XCTest. Such a failed XCTest invocation is
not a test pass. The standalone runner is narrower evidence and is labelled
separately. It shares every contract assertion and case with the XCTest path.

## Acceptance coverage, not full parity

| Design acceptance | This unit |
|---|---|
| A19, every control value a position | Scalar/choice and explicit XY values covered; choices tested at 2, 3, 5 and 17 options. |
| mapcheck, M1-M3/M5 | 3,000 deterministic random curves, sampled per stretch; exact waypoints, direction, bounded steepness and range. |
| mapcheck, M4 | 2,000 deterministic insertion cases; the before/after curve is sampled over the whole domain and round-tripped through Codable. Explicit Step jump cases included. |
| mapcheck, M6 | Curve-point positions must belong to the driving control's waypoints. |
| Curve editing / XY axes | Local value edits preserve nonincident split stretches; X and Y have independently validated waypoint lists and round-trip as such. |
| R1, ordered persistence | Inline content round-trip and nested compiler order covered. Library publish, duplicate/paste/openPage and A24 classification are not implemented. |
| Complete targets | Explicit descriptor parameter sets must match exactly. Unknown references, duplicate identities and incomplete parameter lists are refused. |
| writecheck/RD1 | Not ported. No teaching/edit command owner yet. |
| librarycheck and R2/R3 | Root-only definition/use references, rename undo and explicit own-name/control state are in the separate document slice. Nested uses, version history, publication confirmation and full local overrides are not ported. |
| deepcheck/L5 | Nested flattening covered, but no macro/deeper reach, automatic intermediate controls, cycle checks or one-undo command exists yet. |
| blockcheck/designercheck | Only the ordered-value subset above. No structural draft, Discard, Undo/Redo or library-version rollback parity claim. |
| peer/club/face checks | Not ported. No demo recipe or full face/macro evaluator yet. |

Per-option curve sets, control-to-control mappings, parallel routing/latency
alignment, listening overlays, off/nudge state, full settings catalog, content
limits/recovery, autosave, native smoothing, limiter and capture all remain later
units. They are not silently defaulted or advertised as implemented behavior.

## Review prerequisites and engineering defaults

The independent model-01 review read the four source files only; it did not run
tests or review tooling/docs/UI. Its choice-edit and macro findings remain open:

- **Option edits are not implemented.** Reconstructing Choice with a different
  option count moves its evenly spaced coordinates. The document command must
  preserve OptionID identity while atomically remapping the stored position and
  all incoming/outgoing mappings and per-option sets. A19 remains positional;
  changing only the current position is insufficient. Adding an option must
  preserve what is heard (W4), including indirect and multiple additive drivers.
  Arbitrary removal/reorder and exact curve reparameterization remain command
  design gates. No silent approximation or reference dropping is allowed.
- **Teaching is not implemented.** Before it is, mapping targets must include
  local control axes and immediate child-use control axes as well as local
  parameters. A28 needs complete curve sets keyed by OptionID. All references,
  axes, option completeness and potential macro cycles must validate before
  evaluation; parent controls evaluate before children. Automatic deeper relay
  creation belongs to a single undoable command, not compiler repair (E20a).
- **Step jumps at the midpoint of a new stretch.** This is a provisional
  engineering default, also used in the prototype's Kit.swift, not a newly
  confirmed operator decision or a draggable-jump interface. Subdivision keeps
  the existing absolute jump. At the jump itself the higher-travel side wins;
  at an exact waypoint its explicit value wins (M2).
- **Choice ties select the higher-index option.** Nearest-option evaluation
  rounds an exact halfway landing upward. This deterministic engineering default
  is covered at 2, 3, 5 and 17 options. It does not address option-edit remapping.

This target is not integrated or released; its Codable form is internal authoring
content, not the shipped library/file schema. The per-axis representation change
does not purport to migrate saved user files.

## Engineering direction

[ADR-023](../decisions/ADR-023-apple-silicon-audio-execution.md) records the native
arm64, scheduling, Accelerate and visualization choices. No performance result
is inferred from these correctness checks. The previous curve constructor's
strict coefficient check rejected a valid bounded tangent when floating-point
arithmetic landed one ulp past an endpoint. Generation now bounds only roundoff
within the segment's endpoint interval; imported segments still validate
strictly. The deterministic random cases caught and retain that regression.

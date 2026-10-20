# Preset Format (`.tnf`)

tap-n-filter presets are plain-text JSON files with the `.tnf` extension. They are designed to be read, edited, and shared as files.

## Format

A `.tnf` file is a UTF-8 encoded JSON document conforming to the `GraphPreset` schema.

```json
{
  "formatVersion": 1,
  "name": "distant-engines",
  "outputGain": 1.0,
  "nodes": [
    {
      "typeIdentifier": "tnf.eq",
      "id": "2EF8A6F0-1234-5678-9ABC-DEF012345678",
      "displayName": "EQ",
      "bypass": false,
      "wetDryMix": 1.0,
      "parameters": {
        "hp.frequency": 80.0,
        "hp.Q": 0.707,
        "lp.frequency": 800.0,
        "lp.Q": 1.2
      },
      "extras": {}
    },
    {
      "typeIdentifier": "tnf.reverb",
      "id": "8B3C7D90-FEDC-BA98-7654-321098765432",
      "displayName": "Reverb",
      "bypass": false,
      "wetDryMix": 0.7,
      "parameters": {},
      "extras": {
        "preset": "largeHall"
      }
    }
  ]
}
```

## Field reference

### Top-level

| Field | Type | Required | Description |
|---|---|---|---|
| `formatVersion` | int | yes | Format version. Current: `1`. |
| `name` | string | yes | User-visible preset name. |
| `outputGain` | float | yes | Post-graph gain. Range 0.0–2.0, default 1.0. |
| `nodes` | array of `EffectState` | yes | Effect chain, ordered from input to output. |

### `EffectState`

| Field | Type | Required | Description |
|---|---|---|---|
| `typeIdentifier` | string | yes | Effect type. `tnf.eq`, `tnf.reverb`, etc. |
| `id` | string (UUID) | yes | Instance identifier. New UUID generated on save. |
| `displayName` | string | yes | User-visible name (may equal the type's default). |
| `bypass` | bool | yes | Whether the effect is bypassed. |
| `wetDryMix` | float | yes | Wet/dry mix, 0.0–1.0. |
| `parameters` | object (string → float) | yes | Parameter values keyed by parameter identifier. |
| `extras` | object | yes | Type-specific state that doesn't fit `parameters`. |

## Versioning

`formatVersion` is an integer that increments when the schema changes incompatibly. Loaders for version N must be able to load presets of version N or earlier (with migrations as needed).

V1 ships with version 1. Migrations from version 0 are not needed (no prior version exists).

`PresetMigrator.migrate(_:) throws -> GraphPreset` rejects decoded presets with
`formatVersion > PresetMigrator.currentFormatVersion` by throwing
`PresetMigrationError.unsupportedFormatVersion(Int)`, carrying the input version.
This is a recoverable load error, including for raw session JSON; it never
preconditions on user data. `PresetStore` retains its existing, earlier file
format guard and throws `PresetStoreError.unsupportedFormatVersion` for future
files. Callers use `try` and handle load errors at their boundary.

Supported presets still receive the unconditional EQ Q repair: corrupt Q values
at or above 100 become 0.707, legal Q=4 remains unchanged, and reverb extras are
preserved. The current format version remains 1. Synthetic version-0 fixtures
exercise the existing acceptance of lower version numbers, not a historical
schema migration.

### Future-version session recovery

Session restore first decodes a small private header containing only the integer
`formatVersion`, before attempting the current `GraphPreset` schema. If this
header identifies a future version, even with changed or absent graph fields,
`AppViewModel` uses the bundled `distant-engines` graph and surfaces an
`AppError.persistence` warning identifying the unsupported version. Capture
does not auto-start. The original graph bytes stay at the existing defaults key;
there is no rewritten copy or backup corpus.

Graph autosave remains suppressed during automatic persistence, source selection
or clearing, power transitions, warning dismissal, failed graph edits, and
successful no-ops. Source-key persistence continues normally. Unchanged
parameters, clamped mix writes with no effective change, unchanged bypass or
node order, and identical factory/file preset loads do not authorize replacement.
Preset comparisons use runtime-canonical graphs so AU conversions are compared
on both sides.

The first successful explicit edit that changes node identity/order, an
effective parameter/mix/bypass value, or the installed preset graph releases
the guard. The next debounced graph write then replaces the incompatible bytes
with the edited, current-version graph; later edits autosave normally. Saving a
separate preset file does not release the session guard. Relaunch before a
replacement repeats recovery from the original bytes. Malformed JSON or an
absent, non-integer or otherwise undecodable version retains the existing
generic fallback behavior; this guard does not introduce corrupt-data backups.

When the format version is bumped:
- Older presets are migrated on load via a `PresetMigrator`.
- An ADR documents the change and the migration logic.
- Tests verify migration produces equivalent graphs.

## Swift Codable mechanism

`GraphPreset.nodes` is declared `[EffectState]` in the on-disk representation (each element a fully-serialized state object with a `typeIdentifier`). The in-memory `Graph.nodes` is `[any EffectNode]`. The translation between the two is handled at the `GraphPreset` boundary, not the protocol boundary.

Encoding (`Graph.snapshot()` → `GraphPreset` → JSON):

```swift
public struct GraphPreset: Codable {
    public let formatVersion: Int
    public let name: String
    public let outputGain: Float
    public let nodes: [EffectState]

    public init(formatVersion: Int = 1,
                name: String,
                outputGain: Float,
                nodes: [EffectState]) {
        self.formatVersion = formatVersion
        self.name = name
        self.outputGain = outputGain
        self.nodes = nodes
    }
}

extension Graph {
    public func snapshot() -> GraphPreset {
        GraphPreset(
            name: "snapshot",  // caller can rename
            outputGain: outputGain,
            nodes: nodes.map { $0.snapshot() }
        )
    }
}
```

The `Codable` derivation on `GraphPreset` is automatic — `EffectState` is itself `Codable`, and an array of `Codable` is `Codable`.

Decoding (JSON → `GraphPreset` → `Graph.restore`):

```swift
extension Graph {
    public static func restore(from preset: GraphPreset,
                                using registry: EffectNodeRegistry) throws -> Graph {
        var nodes: [any EffectNode] = []
        var warnings: [PresetLoadWarning] = []

        for state in preset.nodes {
            do {
                let node = try registry.makeNode(typeIdentifier: state.typeIdentifier)
                try node.restore(from: state)
                nodes.append(node)
            } catch RegistryError.unknownTypeIdentifier(let id) {
                warnings.append(.unknownEffect(typeIdentifier: id))
                // Skip this node; loader is best-effort per preset-format.md
            }
        }

        let graph = Graph(nodes: nodes, outputGain: preset.outputGain)
        if !warnings.isEmpty {
            // Caller observes warnings via a side channel; one V1 approach is
            // a static `lastLoadWarnings` on PresetStore that the view model
            // reads after a load. V2 may pass warnings through directly.
        }
        return graph
    }
}
```

`EffectNodeRegistry.makeNode(typeIdentifier:)` returns a freshly-constructed node of the corresponding concrete type — typically by invoking the type's no-argument initializer, which produces a node in its default state. `restore(from:)` then writes the saved parameters, bypass, wet/dry, displayName, and id onto the fresh node.

This pattern scales to V2's AUv3 hosting: `AUv3Node` registers with the same `EffectNodeRegistry` at app launch (or on-demand when an AUv3 plugin is loaded), `restore(from:)` reads the AUv3-specific state from `EffectState.extras`, and the discriminated-union behavior is unchanged.

The `EffectNode` protocol's `init(from decoder: Decoder)` is not used by the preset I/O path — `GraphPreset` is the boundary. Concrete types may still provide `init(from:)` for direct decoding of a single node from JSON (a future "import single effect" feature), but it is not required for V1.

## Compatibility across effect versions

A preset may reference effects that don't exist (older preset, newer build) or that have new/removed parameters. The loader:

1. **Unknown `typeIdentifier`** — the loader logs a warning and skips the node. The user sees a warning banner: "Preset contained 1 unknown effect that was skipped."
2. **Unknown parameter identifier** — silently ignored (forward compat).
3. **Missing required parameter** — the effect uses its default value, logs a warning.
4. **Parameter out of range** — clamped to range, logs a warning.

The loader never throws on a recoverable mismatch. It returns the best-effort graph and a list of warnings. The UI surfaces warnings as a non-blocking notice.

## Bundled presets

Two presets ship inside the app bundle at `Resources/Presets/`:

- `distant-engines.tnf` — the original ambient-engines preset. Heavy lowpass at 800Hz, large hall reverb at 70% wet. The motivating preset (per `docs/audits/design-rationale.md`); ear-tested in Phase 2.
- `dry.tnf` — passthrough with a small gain trim. Useful as a baseline to confirm the chain wiring is correct.

`submerged` and `next-room` were considered during scribing but cut from V1 per audit finding F-005 (`docs/audits/framing-audit-001.md`); they are deferred to V0.2 as TODOs in `CHANGELOG.md`. The cut keeps V1's factory set in line with what the design rationale motivates and avoids shipping presets whose parameter choices haven't been ear-tested.

Factory presets are loaded by reference when the user selects from the "Factory Presets" menu. The actual file is read from the bundle on demand; the app does not copy them to a user-writable location.

## User presets

Users save and load presets via the File menu's "Save As..." and "Load..." options. These present standard macOS save/open panels filtered to `.tnf`. The app does not maintain a list of "your presets" — presets are just files at user-chosen locations.

A future version may add an in-app preset library that watches a configured directory.

## Sharing

`.tnf` files are plain text. They can be:

- Pasted into a gist or Discord message.
- Embedded inline in a forum post (using fenced JSON blocks).
- Versioned in git alongside a project.
- Edited in any text editor (Vim, VS Code, Obsidian).

The format is intentionally human-readable. Field names are descriptive, parameter identifiers use a `<band>.<param>` convention where helpful, and the structure is shallow.

## Validation

The app validates presets on load. Validation errors:

- Invalid JSON → loader throws, UI shows "Preset file is not valid JSON."
- Missing required top-level fields → loader throws, UI shows "Preset is missing required fields."
- `formatVersion` greater than supported → loader throws, UI shows "This preset was made with a newer version of tap-n-filter."

Validation passes through to the loader, which then handles per-node mismatches as described above.

## Schema reference

A JSON Schema document for `.tnf` files is published at `docs/specs/tnf-schema.json` (TODO: generate during Phase 2 from the Swift types). The schema is referenced from each bundled preset via `$schema`, enabling editor support in tools like VS Code.

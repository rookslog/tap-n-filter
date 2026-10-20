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
2. **Unknown parameter identifier** — ignored by effect restoration (forward
   compat), with a file-import fidelity notice and Save As requirement if the
   key is absent from the restored snapshot.
3. **Missing required parameter** — the effect uses its default value, logs a warning.
4. **Parameter out of range** — clamped to range, logs a warning.

The loader never throws on a recoverable mismatch. It returns the best-effort
graph and skipped-node warnings. The UI combines those warnings with independent
file-import fidelity checks into a nonblocking notice; range clamping need not
produce a skipped-node warning to require Save As.

## Bundled presets

Two presets ship inside the app bundle at `Resources/Presets/`:

- `distant-engines.tnf` — the original ambient-engines preset. Heavy lowpass at 800Hz, large hall reverb at 70% wet. The motivating preset (per `docs/audits/design-rationale.md`); ear-tested in Phase 2.
- `dry.tnf` — passthrough with a small gain trim. Useful as a baseline to confirm the chain wiring is correct.

`submerged` and `next-room` were considered during scribing but cut from V1 per audit finding F-005 (`docs/audits/framing-audit-001.md`); they are deferred to V0.2 as TODOs in `CHANGELOG.md`. The cut keeps V1's factory set in line with what the design rationale motivates and avoids shipping presets whose parameter choices haven't been ear-tested.

Factory presets are loaded by reference when the user selects from the "Factory Presets" menu. The actual file is read from the bundle on demand; the app does not copy them to a user-writable location.

## User presets

Users save and load presets via the Presets menu's Save, Save As and Open
options. Save (Cmd-S) writes to a known safe file target; without one it opens
Save As. Save As (Shift-Cmd-S) and Open present standard macOS panels filtered
to `.tnf`. The app does not maintain a list of “your presets” — presets are files
at user-chosen locations.

The UI's current-file name and Save As prefill use the file basename, regardless
of the internal JSON `name`. Loading leaves that metadata and original file bytes
untouched. An explicit save writes the chosen basename into `name`, as before.
Receipt/Modified/provenance state is memory-only and adds no schema fields.
Restored sessions and factory presets have no known writable file target.

Partial recovery skips unknown or failed effects and keeps a visible nonblocking
warning. Imports also require recovery when unsupported fields/keys would be
discarded or supported values require range clamping, even if no effects were
skipped. Their fidelity notice is separate from skipped-node warnings and does
not invent a skipped-effect count. The recovered version has no safe direct-Save
target, even if it matches
its canonical post-load baseline. Save As is required to establish a new clean
file receipt; its prefill retains the original basename and normal AppKit
confirmation applies if the user explicitly chooses to overwrite the original.
Cancel or failure preserves recovery context. Successful save establishes the
new baseline and clears warnings/notices. See [UI](ui.md#presetmenu) for receipt behavior.

### Same-read import fidelity

`PresetStore.loadResult(from:)` reads file data once and returns
`PresetLoadResult { preset, diagnostics }`. `decodeResult(_:source:)` decodes
and inspects through the same decoder/input bytes without opening `source`.
Existing `load` and `decode` remain compatible wrappers returning `.preset`,
with the existing error mapping. V1 root/node allowlists follow the fields in
the tables above. `PresetDecodeDiagnostic.path` exposes only schema locations
and occurrence indices (for example `$.nodes[0].unknownFields[0]`); unknown key
names and values are not included. Unknown values remain opaque during inspection.

After migration and restoration the VM checks corresponding node occurrences
for dropped parameter/extras keys and range clamping using runtime parameter
metadata. It does not use general float snapshot inequality as an import-loss
test: normal Q roundtrips, intentional corrupt-Q repair and legacy integer
reverb preset canonicalization remain supported. Actual restored state is the
clean graph baseline; original-file fidelity is a separate receipt concern.
No raw-JSON preservation store, persistence fields or schema version change is
introduced. Original imported bytes remain untouched until an explicit save.

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

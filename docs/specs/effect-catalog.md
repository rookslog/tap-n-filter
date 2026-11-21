# Effect catalog

`Config/EffectCatalog.json` is the editable engine parameter contract. The standard-library generator writes static Swift and C++ tables and the public C enums. The app never parses this JSON.

## Catalog schema 1

Each effect identifies its saved type, stable C kind, native component identity, and one node-family factory strategy. Its knobs identify the saved setting key, stable protocol ID, logical bounds, units, presence rule, conversion, smoothing policy, and native targets. Each native target records its parameter ID, scope, element, admitted units, required native range, and access flags.

The closed conversion set is identity, sample-rate-limited cutoff, and preset-relative bipolar size. The only admitted smoothing policy is the existing configuration-frame rule. A malformed catalog or stale generated file fails the generator. There is no fallback parameter list.

Preset entries pair explicit saved IDs with named Apple presets. Reverb IDs 1, 2, and 3 retain SmallRoom, MediumRoom, and LargeRoom. Hall is ID 4 and maps to LargeHall. Church is ID 5 and maps to Cathedral. Kind 7 remains reserved.

Historical profiles own normalization and seeds. `everyday.v1` retains its gain and dynamics domains. `filters.v1` retains its narrower gain domain and its existing dynamics defaults. `quickMenu.v1` retains preset normalization over IDs 1 through 3 and normalized room size. `unified.v1` defines the separate expanded reverb preset domain over IDs 1 through 5. The pure model uses `tnf.native.expanded-reverb.v1` only for that new preset capability. No existing profile widens its normalization.

The generated module has no AVFAudio or AudioToolbox dependency. Recipes select catalog profiles but retain their own control curves, IDs, ordering, and words. Optional knobs do not add settings to existing parts, seeds, editor rows, controls, or recipes.

## Reverb preparation

Reverb always uses kind 4. Its wet parameter is required and room size is optional. Wet-only parts prepare exactly one wet binding. They do not read, validate, or write the two size parameters.

Present room size expands into two bindings. Each captures the selected preset's native baseline before startup for admission, then captures and checks the actual baseline again after startup. At 0.5, the float conversion returns that baseline exactly. Endpoints use the catalog's fixed native limits. Interpolation and ramp arithmetic retain the previous renderer's implementation.

Preparation checks component identity and each present native target's metadata before publication. Unsupported units, access flags, target presence, or bounds refuse the bank. Cutoff admission uses the existing sample-rate-limited upper bound. Other saved values are not clamped or remapped to fit unsupported metadata. Callback code advances resolved bindings and ramps without catalog searches, strings, dictionaries, parsing, metadata calls, allocation, or locks.

## Saved content

Old revisions retain their spelling, canonical bytes, IDs, references, and hashes. Archive admission checks every original revision's canonical stream and hash before compilation. Compilation normalizes the read-only `sizedReverb` alias to reverb with its existing room-size setting. This does not rewrite the immutable revision.

New authored copies and publications use unified reverb. An authored change normalizes local nested payloads and binding provenance without resampling values or changing control, option, part, binding, or use-site IDs. Referenced historical revisions remain references. Listening-position saves do not perform this conversion or publish revisions.

Unified-size content and the expanded preset-domain capability use canonical version 6. Archive schema 9 gates those payloads across revisions, local drafts, workspaces, and nested payloads. Other payloads retain the previous version rules. Schema 9 can hold exact old history beside new content. Older readers refuse schema 9. Rollback uses the older app and its original data, not data copied back from a new reader.

## Checks

`python3 tools/generate-effect-catalog.py --check` checks generated drift. `python3 Tests/EffectCatalogChecks/test_generator.py` includes malformed contracts and a real stale-output failure control.

`python3 tools/check-engine-catalog.py --scratch-path <owned-scratch-directory>` compiles and runs the focused pure model, mapper, Core, metadata-fake, canonical, and owned-store drivers. Run it through the project's storage guard. It does not create native audio engines, windows, taps, or devices. `EngineCatalogTests` also runs the new cases under the default SwiftPM test suite on a full Xcode test environment.

Actual native output equality, supported-OS metadata coverage, realtime performance, and listening acceptance are separate checks. A pure or fake pass does not establish them. Native engine, device, and window tests remain opt-in and excluded from the default checks.

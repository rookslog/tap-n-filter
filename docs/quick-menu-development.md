# Quick Menu development

This branch integrates the current application and a built-in-only Quick Menu
candidate. It is not a public binary release or a claim of complete native or
listening acceptance.

## Source ownership

- `SoundModel` validates and evaluates library blocks, stable control identities,
  mappings and option-qualified scalar sub-controls.
- `SessionStore` owns bounded archive reads and atomic persistence.
- The app's library-session adapter owns commands and publishes immutable menu
  snapshots. Relation structure and effective parent values share one snapshot.
- `EverydayMenu` draws app cards, choices and sub-controls. Fold state lives in
  `MenuPresentation` for this run, keyed by app, sound and parent control. It is
  not saved audio state. Hiding a child does not disable or reset its mapping.
- Playback preparation lowers complete targets into the bounded native bridge.
  The callback does not read the UI or archive.

## Candidate and data boundaries

The enhanced Everyday definition is seeded into a fresh library session. An
existing destination is retained rather than overwritten. Room size uses a typed
continuous binding for supported fixed reverb presets, not wet level relabelled
as size. Native renderer behavior and sound quality need separate qualification.
Filters is unchanged. Additional new sounds and a full-editor release are later
work; editor source is retained but has no Quick Menu entry.

Each app/use retains separate values for its option-qualified child controls.
The relation-bearing content uses canonical version 5 and the library archive
uses schema 8. Those numbers are separate from built-in definition revisions and
app release numbers. Older readers refuse unknown versions. Developer trials
must use their own session path, not a working app's saved data. The existing
`--library-session-file` option selects an explicit library file.

Creating a new library block from a use with option-qualified controls currently
refuses atomically. This limitation does not discard those controls or prevent
ordinary use of the built-in candidate. Capture ownership checks and the
Safari-specific helper path remain separate runtime concerns; supporting a menu
entry is not evidence of captured audio.

## Checks

On macOS with full Xcode selected:

```sh
swift build
swift test --enable-code-coverage
```

The default test graph includes the shared model contracts, mapping and choice
owner commands, file-store scenarios, canonical/native compatibility witnesses,
and option-control/folding checks. Tests use owned temporary data. Engine/window
families require the `TNF_RUN_NATIVE_TESTS=1` opt-in. Real HAL capture tests use
their separate existing `RUN_INTEGRATION_TESTS=1` gate. Neither flag is set by
default CI. A skipped native test is not native acceptance.

The GitHub-hosted matrix uses macOS 15 and 26. GitHub retired the macOS 14 image;
the app's declared 14.4 deployment floor is not runtime coverage on those newer
runners. Local Command Line Tools can compile products but may not provide the
XCTest environment. Successful direct contract drivers do not substitute for
an actual Xcode `swift test` result.

Developer-owned diagnostic probes use the fixed checkout-local fixtures described
in [Owned probes](developer-owned-probes.md). Missing fixtures refuse. No local
fixture, saved session, build cache or review capture belongs in a public commit.

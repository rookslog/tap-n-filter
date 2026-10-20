# Rendered CI evidence

The dedicated **Rendered UI evidence** workflow uses a pinned `macos-15` runner
with full Xcode. It produces evidence artifacts for the checked-out source. It
does not replace the existing build/test matrix or required `Build and test`
aggregate, and it does not generate or accept golden baselines.

## Materialization

The workflow runs these steps in order:

1. Record `git rev-parse HEAD`, Swift, and Xcode versions. Pull requests retain
   the actual synthetic merge checkout SHA separately from the PR head and base
   SHAs. Push/manual events record unavailable PR metadata as JSON null.
2. Run `swift test -c debug --filter RenderedEvidenceStateTests` with full Xcode.
3. Run `swift run -c debug tap-n-filter-render-evidence` in CI only.
4. Run `python3 -B Tests/RenderedEvidenceTests/test_rendered_evidence.py` against
   the exported files. Any missing, empty, malformed, blank, or repeated-state
   image detected by these bounded checks fails the job.
5. Upload `test-artifacts/rendered-evidence` using `actions/upload-artifact@v7`,
   with missing files treated as an error and retention of 14 days. The artifact
   name includes the run ID and attempt. Upload retains the current attempt even after export/validation failure for
   diagnosis. A failed job or partial directory is not valid evidence; all
   validation gates still fail normally.

The exporter refuses execution unless both `CI=true` and `GITHUB_ACTIONS=true`
are present, before constructing NSApplication, a model, or a window. This is an
accidental-local-execution guard, not an authorization/security boundary. Do not
override it to render locally under this implementation contract.

Every state/theme gets a fresh injected fake capture controller, AVAudioEngine
object that is never started, registry, and UUID-scoped defaults suite. Fake
capture lifecycle calls throw and invalidate the fixture. Source enumeration
returns only a synthetic example. The model uses its normal public state APIs
and capture publisher; no production test-only setters were added. Existing
model logging may emit synthetic fixture diagnostics on the ephemeral CI host;
no operator defaults or logs are read by the harness.

## Images and metadata

The output contains `manifest.json` and exactly these combinations:

- States: `idle`, `running`, `multiline-error`, `expanded-eq`, `settings-open`.
- Themes: `light`, `dark`.
- Filename: `control-panel-<state>-<theme>.png`.

All images use the real `ControlPanelView`, with a canonical EQ/reverb chain,
380pt width, and measured fitting height. The native host is kept in a
borderless offscreen window. Two-second bounded waits assert state propagation
and stable fitting height. Height must be at least 420pt and no more than 700pt
(900pt with settings open). The measurement is taken before final window
sizing; zero/collapsed height is rejected rather than clamped away. A final
measurement rejects sizing-induced drift. The same host/model/node identities
are retained through state preparation, layout, and `cacheDisplay` capture.

The PNG presentation is explicitly opaque sRGB at 1 pixel per point. A light
background is white; a dark background has RGB `(0.12, 0.12, 0.12)`. Both the
SwiftUI host background and native window appearance follow the theme. The
native cache is composited over that recorded background when normalized to an
8-bit RGB PNG. Transparent native text/control pixels must not be interpreted
as absent controls because an image viewer previews them against black. No
controls are drawn or replaced by the harness, and `ImageRenderer` is not used.

Manifest schema version 1 includes:

- `source`: `checkoutSHA`, `eventName`, `ref`, separately nullable `prHeadSHA`,
  `baseSHA`, `baseRef`. CI also passes the actual checkout/head values to the
  validator for equality checks.
- `environment`: actual macOS, Swift, and Xcode versions.
- `limits`: fake capture, isolated defaults, no audio start, no actual
  MenuBarExtra, no satisfaction of the mandatory manual layout gate.
- `images`: filename/state/theme; width/fitting height in points; decoded target
  pixel dimensions and scale; prepared/rendered host identity; state observed
  at capture; EQ/expanded node UUID and type; error/source text; background RGB
  and opaque-presentation description. Optional state values are explicit nulls.

The standard-library Python validator decodes PNG scanlines, checks CRCs and
dimensions, composites alpha on white for content checks, rejects at most eight
distinct visible colors, and rejects identical decoded state pixels within a
theme. Synthetic in-memory decoder fixtures calibrate these checks; they are
not product screenshots. These heuristics do not establish visual correctness.
An additional presentation check rejects any transparent output pixel and
checks the panel corner against the explicitly recorded theme background.

## Review and limits

Root must download and visually inspect the real source-backed images in both
themes, including error wrapping, expanded controls, settings, and native
buttons/text. Metadata describes observed model state; it cannot independently
establish that every intended control is visible. KVC accessibility omissions
alone also cannot establish that a button is absent.

Images cover only their recorded checkout, including its merged features. They
are not a composition of other unmerged implementation branches. Fake running
state does not mean audio was flowing. A hosted panel does not exercise actual
MenuBarExtra creation or lifecycle, and CI evidence does not satisfy the
mandatory newest-OS manual layout gate in `governance/review-tiers.md`.

Downloaded artifacts can be checked without launching UI:

```sh
TNF_RENDERED_EVIDENCE_DIR=/path/to/downloaded/artifact \
  python3 -B Tests/RenderedEvidenceTests/test_rendered_evidence.py
```

Output directories must be absent before export; stale output is rejected
rather than mixed into the next run. Generated artifacts are covered by the
existing `test-artifacts/*` ignore rule and are never committed as baselines.

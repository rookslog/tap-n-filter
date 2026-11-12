# TNF branch, PR and release flow

Operator decision, 2026-11-12: trunk-based ("yes, go with trunk-based"). This draft goes into the app repo as `docs/RELEASE.md` and replaces the "PR workflow" section of its `CLAUDE.md`.

## Branches
- `main` always builds, passes its tests and runs. It is protected: changes land only through a pull request with green CI. No direct pushes, and no force pushes.
- Each piece of work gets a short-lived branch from `main`, named for the work (for example `qm-01a-everyday-subcontrols`, `engine-01-parameter-table`). Commit to it as often as you like; these steps are not measured.
- There is no `develop` or testing branch. If an old release ever needs a patch after `main` has moved on, cut `release/vX.Y` from that tag at that point, and only then.

## Pull request into main
1. Privacy pass over the outgoing diff and commit metadata: no local paths, host names, emails, secrets or private notes. Required before the first push of any branch.
2. CI on GitHub: build, plus `swift test` with the automated contract and model tests. Device, audio-engine and window tests stay out of CI and are labelled.
3. Performance check on this Mac, with the five scenarios: menu closed and sound off; menu closed and sound playing; menu open and idle; slider drag; option switching. It reports CPU, main-thread share, memory and settings writes. Results go in the PR description and must meet the budget, and never be worse than the last release.
4. Large PRs: a try build for the operator. The designer reviews design scope; the lead accepts engineering and privacy.
5. Merge (squash or merge, never rebase-rewrite `main`). Delete the branch.

## Native restore qualification

Default `swift test` retains exact public `EffectState` JSON and `GraphPreset`/
`PresetStore` ordered-chain roundtrips, including a lost-parameter corruption
control. Existing registry/type admission checks remain enabled.

The two AU-backed restore/readback cases below require explicit opt-in before
constructing any Audio Unit in those methods. Run them only in a prepared,
explicitly authorized native qualification environment:

```sh
TNF_RUN_NATIVE_TESTS=1 swift test -c debug --filter 'EQNodeTests/test_snapshot_restore_roundtrip_preserves_state'
TNF_RUN_NATIVE_TESTS=1 swift test -c debug --filter 'GraphTests/test_snapshot_restore_roundtrip_preserves_chain'
```

The native assertions and tolerances are unchanged. [Run 43190465399](https://github.com/rookslog/tap-n-filter/actions/runs/43190465399)
built both runners and passed macOS 26 tests, but macOS 15 restored EQ frequency 80
instead of 100 and Q 0.707 instead of 1.5. The graph diagnostic retained 100 in the
snapshot and decoded preset before native readback returned 80. That native
restore failure remains unresolved; opting in or passing deterministic DTO tests
does not fix it, establish its cause, or qualify audio behavior on that OS.

## Release
1. Pick a commit on `main`. Optionally tag a pre-release (`v1.0.0-beta.1`) for the operator to try; that replaces any "testing branch".
2. Release checklist:
   - performance check against the budget;
   - operator listening acceptance;
   - privacy pass on the release notes and assets;
   - the working app's data path untouched, with rollback to the previous release possible.
3. Tag `vX.Y.Z` on `main`. CI builds the app from the tag and attaches it to a GitHub Release. Signing and notarization are a later, separate decision.

## Lanes
- Light lane: work on a branch.
- Full lane: a saved-format change, the realtime audio engine, anything public. A PR into `main` is the point where the full checks above run.

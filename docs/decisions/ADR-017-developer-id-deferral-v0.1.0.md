# ADR-017: Ad-hoc signing for v0.1.0; Developer ID deferred

Public-copy privacy edit: `LOCAL_SIGNING_IDENTITY` and angle-bracket values below
replace local identity, certificate or path metadata. Redacted command excerpts
are historical records, not literal output from the current scripts.

## Status

Accepted

## Context

ADR-003 commits V1 to direct distribution as a signed, notarized DMG, with code signing performed by "the user's Developer ID Application certificate". Phase 4's spec (§4.2) treats the Developer ID Application certificate as the assumed input, with `[ESCALATION: signing-identity-missing]` as the fallback when it's absent.

`security find-identity -v -p codesigning` on the build machine at the start of Phase 4 shows only one identity:

```
1) <local certificate fingerprint> "LOCAL_SIGNING_IDENTITY"
   1 valid identities found
```

`LOCAL_SIGNING_IDENTITY` is a self-signed certificate, not an Apple-issued Developer ID Application certificate. Apple-issued certificates have the form `Developer ID Application: <Name> (<10-char Team ID>)`. Self-signed certificates satisfy `codesign` locally but produce signatures macOS Gatekeeper does not trust for distribution, and `xcrun notarytool` rejects them outright.

The Developer ID Application certificate requires enrollment in the Apple Developer Program ($99 USD/year, 24–48 hour enrollment typical). The user has decided not to enroll for the v0.1.0 release window; enrollment may happen later, in which case v0.1.1+ can re-sign with the real Developer ID.

The v0.1.0 release proceeds with ad-hoc signing under the constraint that distribution requires more explicit user action on first launch (right-click → Open, or System Settings → Privacy & Security → "Open Anyway").

## Decision

**v0.1.0 ships ad-hoc-signed (`codesign --sign -`) and unnotarized.** Hardened runtime is still enabled per ADR-003. The DMG is itself ad-hoc signed.

**Distribution caveat is documented in the README.** First-launch instructions explicitly cover the Gatekeeper interaction: macOS will show "tap-n-filter can't be opened because Apple cannot check it for malicious software", and the install instructions tell the user to right-click → Open (or open System Settings → Privacy & Security → click "Open Anyway").

**Developer ID upgrade path is explicit.** When the user enrolls in the Apple Developer Program, v0.1.1 (or whichever next release) re-signs with the real Developer ID Application certificate, submits to notarytool, and staples. The `Build/sign.sh` script ships with a clearly-marked TODO at the signing-identity line; flipping it is a one-line change.

## Alternatives considered

### Enroll in Apple Developer Program before shipping v0.1.0

The straightforward path. $99 USD/year, 24–48 hour enrollment. Produces a Gatekeeper-clean install experience. Rejected because the user explicitly chose to defer enrollment; the decision is theirs and the deferral is reversible.

### Sign with the existing self-signed certificate

Produces a signature that says "LOCAL_SIGNING_IDENTITY" — looks like an obscure organization rather than an obviously-unsigned binary. Some users might find this more confusing than a clean ad-hoc signature, because they'd see a real-looking identity and assume it should be trusted. Ad-hoc signing (`--sign -`) is the more honest signal: "this is not signed by a recognized authority; treat with appropriate caution."

### Skip signing entirely

`codesign` is still run with `--sign -` because:
1. Hardened runtime requires a signature (even ad-hoc) to take effect.
2. Some macOS subsystems behave differently for entirely-unsigned binaries vs ad-hoc-signed ones; ad-hoc is the better-defined unsigned case.
3. The downstream codesign-verify step in CI / verification needs *some* signature to verify against.

### Block the v0.1.0 release until enrollment lands

Phase 4 would stay at `awaiting acceptance` indefinitely. Rejected because the user can iterate on the release (v0.1.0 → v0.1.1 with the Developer ID upgrade) without holding everything else.

### Distribute via Homebrew tap instead of DMG

Homebrew handles signing requirements differently (it can install unsigned binaries with user opt-in). Rejected because the V1 release plan in ADR-003 commits to DMG distribution; switching distribution model is a larger change than just deferring signing.

## Consequences

**Enabled:**

- v0.1.0 ships without the cost / time of Developer Program enrollment.
- The decision is reversible; v0.1.1 can upgrade with no architectural change.

**Precluded or constrained:**

- First-launch UX is worse than the ADR-003 target. Users see a Gatekeeper warning and must take explicit action to allow the app.
- Some users with strict security postures (managed devices, enterprise environments with notarization-required policies) cannot install v0.1.0 at all. They are not the V1 audience.
- The v0.1.0 GitHub release notes must call out the ad-hoc signing caveat so users understand the install workflow before downloading.

**Risks:**

- A future macOS version may further restrict ad-hoc-signed binaries; the v0.1.0 install workflow might break before v0.1.1 ships. Mitigation: enroll before this becomes a real problem; the upgrade path is already in place.
- Users who refuse to bypass Gatekeeper for unsigned apps will report v0.1.0 as "broken". Mitigation: README install instructions explicitly explain the workflow; the limitation is documented.

## Build script implications (Phase 4 §4.3)

`Build/sign.sh` reads roughly:

```sh
#!/usr/bin/env bash
set -euo pipefail
APP="${1:?usage: sign.sh <path-to-app>}"

# v0.1.0: ad-hoc signing per ADR-017.
# To upgrade to Developer ID: replace SIGNING_IDENTITY with
# "Developer ID Application: <Your Name> (<TEAMID>)" and re-run.
SIGNING_IDENTITY="-"

codesign --deep --force --options=runtime \
  --sign "$SIGNING_IDENTITY" \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
```

Phase 4 §4.4 (notarization) is **skipped** for v0.1.0. `Build/sign.sh` does not invoke `notarytool` or `stapler`. The DMG packaging step (§4.5) builds the DMG and ad-hoc-signs it; no stapling.

## V0.1.0 → V0.1.1 upgrade procedure

When the Apple Developer Program enrollment completes:

1. `security find-identity -v -p codesigning` confirms `Developer ID Application: <Name> (<TEAMID>)` is present.
2. Edit `Build/sign.sh`: replace `SIGNING_IDENTITY="-"` with the real identity string.
3. Add the notarization step: `xcrun notarytool submit "$DMG" --keychain-profile TNF-Notary --wait` followed by `xcrun stapler staple "$DMG"`. Set up the keychain profile via `xcrun notarytool store-credentials` first.
4. Re-build the DMG, re-sign, notarize, staple.
5. Cut v0.1.1 release; update README install instructions to remove the right-click-Open caveat.
6. Supersede this ADR with one noting the upgrade landed.

The v0.1.0 DMG remains in the GitHub release archive as the original signed-and-distributed artifact, with its README pointing forward to v0.1.1 for the cleaner install experience.

## References

- ADR-003 — direct distribution + Developer ID assumption. This ADR partially defers ADR-003's signing requirement for v0.1.0 only.
- `docs/orchestration/phases/04-polish-release.md` §4.2–§4.4 — Phase 4 signing / notarization tasks; §4.4 is skipped for v0.1.0.
- Apple's notarization documentation: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- `Build/sign.sh` — the script's `SIGNING_IDENTITY="-"` line is the upgrade seam.

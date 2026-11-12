# CLAUDE.md

Instructions for any Claude Code session working in this repository.

## What this project is

**tap-n-filter** is a macOS menubar app that captures audio from a specific application via Core Audio process taps and routes it through a configurable graph of audio effects. V1 is described in detail under `docs/specs/architecture.md`.

## Working mode

This repository is built using an agent-driven workflow centered on `/goal`. The full plan lives at `docs/orchestration/plan.md`. The current phase and status are recorded in `docs/orchestration/state.json`.

If you are starting work in this repo for the first time, read the following in order before doing anything else:

1. `docs/orchestration/plan.md`
2. `docs/orchestration/state.json`
3. The phase doc at `docs/orchestration/phases/<current_phase>.md`
4. `docs/governance/quality-gates.md`
5. Any open lab notebooks in `docs/investigations/` relevant to the current phase or area you're touching.

Then proceed to whatever the current phase requires.

## Active investigations

Long-running technical investigations that span multiple sessions are tracked as lab notebooks in `docs/investigations/`. Each notebook contains a chronological experiment log, an explicit hypothesis ledger (active / inactive / ruled out), an environment snapshot, and cited references. The protocol — including the post-falsificationist commitments (source-grounded vs behavior-inferred tags, pre-registration of predictions, mandatory frame checks after 3+ same-null experiments) — is in `docs/investigations/README.md`.

If you're about to touch code in an area covered by an open investigation, read the notebook first. The point is to avoid repeating experiments or re-believing hypotheses that have already been ruled out.

## Debugging hard problems

When you are debugging a hard problem — an unknown cause in an opaque system, the kind of work an open investigation tracks — follow `docs/governance/debugging-protocol.md`. The load-bearing rule: **a fix that targets a hypothesized cause is an intervention, and an intervention is an experiment.** Pre-register it in the notebook's Intervention ledger *before* writing the code, with a discriminating prediction that includes the risky branch (what a landed-but-symptom-persists result would force you to conclude) and that separates the diagnostic proving the fix landed from the one proving the symptom resolved. Do not write the fix first and document after.

Confirming that a condition *obtains* (source-grounded) is not confirming it is *load-bearing* (the cause of the symptom). Only an intervention that moves the symptom earns the word "confirmed." Conflating the two is the failure this protocol exists to prevent.

## Phases and gates

Every phase has a spec under `docs/orchestration/phases/`. Every phase has gate criteria documented in that spec. **Do not advance a phase to `passed` in `state.json` until verification has returned PASS per `docs/governance/verification-protocol.md`.**

Phases are numbered:

- `-1` — Framing Audit (cold-context review of the design bundle itself)
- `0` — Repo and Tooling Init
- `1` — Capture Spike
- `2` — DSP Chain
- `3` — UI and Control
- `4` — Polish and Release Prep

Run them in order. Do not skip Phase -1.

## Verification

Each phase ends with a verification subagent invocation. Spawn the verification subagent per `docs/governance/verification-protocol.md`. The subagent reads the phase spec and the diff, returns PASS or FAIL with reasoning, and answers the framing-audit-lite question. Record its report under `docs/audits/verification/<phase>.md` and update `state.json` accordingly.

## Delegation

Delegate work to subagents per `docs/governance/delegation-protocol.md`. The doc covers when to delegate, the six required parts of a delegation prompt, and per-subagent-type model selection (Opus for the auditor and audit-response agent; Sonnet for verification by default; code-writing subagents pick per the trickiness rubric). Read it before spawning a subagent.

## Human-input gates

Two phases require human input:

- **Phase 2** requires an ear test. Produce an A/B comparison wav, surface it via the marker `[EAR_TEST_READY: <path>]`, then wait for `[EAR_TEST: PASS]` or `[EAR_TEST: FAIL: <reason>]` in chat.
- **Phase 4** requires user acceptance. Build a release candidate, surface it via `[RC_READY: <path>]`, then wait for `[ACCEPT]` or `[REVISE: <what>]`.

These are the only two human-in-the-loop points. All other review is performed by subagents per the protocols in `docs/governance/`.

## Decision logging

Decisions made during build go to one of three places, depending on type:

- **ADRs** (`docs/decisions/ADR-NNN-<topic>.md`) — decisions you commit to, with full context, alternatives considered, and consequences. Write a new ADR whenever you make a substantive architectural choice during build.
- **Dissent log** (`docs/decisions/dissent-log.md`) — append an entry whenever you choose between options. One-line summary, rejected alternatives, reasoning.
- **Uncertainty log** (`docs/decisions/uncertainty-log.md`) — append an entry whenever you discover a question you can't fully answer. Note what triggered the entry, current best guess, and what would resolve it.

The auditor reads these. Hidden reasoning is the failure mode the audit catches.

## Style

This is a public repo. Code is written for other people to read, not just for the orchestrator.

- Swift code follows the conventions in `docs/governance/coding-standards.md`.
- Markdown docs use declarative prose. Avoid AI writing patterns: no "not X, but Y" constructions, no anaphoric paragraph openers, no aphoristic sentence closers, no tricolon padding.
- Commit messages: imperative mood, first line ≤ 72 chars, body wrapped at 80.

## PR workflow

Follow [the branch, PR and release flow](docs/RELEASE.md).

## What you do not do without explicit user instruction

- Do not delete files in `docs/`.
- Do not modify `goal-prompt.md`.
- Do not skip phases.
- Do not advance `state.json` past `pending` without a passing verification.
- Do not commit `Package.resolved` updates that introduce new top-level dependencies without an ADR.
- Do not push directly to `main`. Every change goes through a PR.
- Do not land a fix targeting a hypothesized cause in an area under active investigation without a pre-registered Intervention entry in the notebook (per `docs/governance/debugging-protocol.md`).

## Halt markers

Use these exact markers in transcript when you need to communicate state to `/goal` or the user:

| Marker | Meaning |
|---|---|
| `PHASE <N> GATE: PASS. Advancing to Phase <N+1>.` | Phase complete, moving on |
| `PHASE <N> GATE: FAIL. <reason>` | Phase incomplete, will retry or escalate |
| `PHASE <N> GATE: AWAITING <ear_test\|acceptance>` | Need human input |
| `[EAR_TEST_READY: <path>]` | Ear-test artifact is ready |
| `[RC_READY: <path>]` | Release candidate is built |
| `[ESCALATION: <topic>]` | Need user guidance on something unanticipated |

The `/goal` evaluator watches for these. Use them precisely.

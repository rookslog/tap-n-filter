# AGENTS.md

Guidance for any agentic reviewer evaluating a pull request in this repository.

This file is read by:

- Codex Cloud (`@codex review`) per the [Codex GitHub integration prerequisites](https://developers.openai.com/codex/integrations/github)
- Claude Code sessions working on this repo (see `CLAUDE.md` for the working-mode instructions specific to Claude)
- Any other agentic reviewer that follows the AGENTS.md convention

If you're reviewing a PR, read this end-to-end before forming opinions. The
project's documented conventions exist for reasons that often don't show up
in the diff.

---

## What this project is

**tap-n-filter** is a macOS menubar app that captures audio from a chosen
application via Core Audio process taps and routes it through a configurable
graph of audio effects (EQ, reverb, etc.) before sending it to the output.
V1 architecture is specified in `docs/specs/architecture.md`. The project is
phase-driven; each phase has a spec under `docs/orchestration/phases/` and a
gate that must pass before the next phase starts.

---

## Build & test environment reality

This is important for review framing:

- **The codebase builds and tests on macOS with Xcode (or Command Line Tools
  for `swift build`).** It does not build or test on Linux. SwiftPM-on-Linux
  lacks the macOS-specific frameworks (Core Audio, AVAudioEngine, AppKit,
  SwiftUI) the project depends on.
- **Codex Cloud runs Linux containers, so the review environment cannot
  exercise the code.** Reviews are diff-reading + reasoning, not build-or-test.
- The CI workflow at `.github/workflows/ci.yml` runs `swift build` and
  `swift test` on the `macos-15` and `macos-26` matrix with full Xcode.
  Those runs are the authoritative CI build/test signal. The declared
  macOS 14.4 deployment floor is not runtime coverage supplied by that matrix.
- A specific consequence of the macOS-only constraint is documented in
  [ADR-010](docs/decisions/ADR-010-live-render-check-environment-deviation.md):
  live-audio integration tests can't run in autonomous environments, so the
  Phase 1 and Phase 2 verifications accept environment-bounded deviations.

When suggesting changes, assume the test signal you see is informational
unless CI confirms it.

---

## Required reading before reviewing

In rough priority order:

1. **`docs/governance/review-protocol.md`** — the "Reasoning over acceptance"
   discipline. The maintainer replies to every finding with a structured
   `review-verdict` block (see "Verdict-block format" below). Knowing this
   format means you're not surprised by the maintainer's reply style.

2. **`docs/governance/coding-standards.md`** — Swift conventions for this
   repo. Don't suggest style changes that conflict with what's documented
   here.

3. **`docs/decisions/`** — every `ADR-NNN-*.md` file is a documented design
   decision. If the diff touches an area covered by an ADR, the ADR's
   rationale supersedes generic best-practice suggestions. Specific ADRs
   that matter most for PR review:

   - **ADR-001** — capture API (Core Audio process taps; not generic
     audio-capture libraries)
   - **ADR-006** — graph-mutation lifecycle (the rules for when graph
     edits are safe and when they need to stop the engine first)
   - **ADR-009** — SPM-only project structure (no Xcode project file by
     design; don't suggest adding one)
   - **ADR-010** — environment-bounded deviation for live-render tests
   - **ADR-011** — accessibility audit via in-process NSHostingView walk
     (XCUITest is out for SPM)
   - **ADR-012** — `NSSavePanel`/`NSOpenPanel` via direct AppKit (SwiftUI
     `.fileExporter` / `.fileImporter` are known-flaky on macOS 14.x)
   - **ADR-013** — reorder via up/down chevron buttons, not drag (drag is
     flaky in MenuBarExtra; keyboard/VoiceOver path is poor)
   - **ADR-014** — `CATapDescription.muteBehavior = .muted` so the process
     tap intercepts audio for filtering instead of running in parallel
   - **ADR-016** — review-journal tool's stack, fence-syntax, and
     pluggable-profiles design

4. **`docs/specs/architecture.md`** — overall design context. Sub-specs
   under `docs/specs/` cover capture, audio graph, effect-node protocol,
   preset format, and UI.

5. **`CLAUDE.md`** — working-mode instructions for Claude sessions. Useful
   context even if you're not Claude: it explains the phase-driven
   workflow, the halt markers, and the decision-logging conventions.

If you find yourself wanting to flag something that contradicts a documented
decision, read the relevant ADR first. If after reading the ADR you still
disagree, file the finding but cite the ADR you're disagreeing with — the
maintainer will weigh the argument seriously when it engages with the
documented rationale.

---

## What to focus on

Concretely, in order of priority for this project:

1. **Correctness and crash paths.** Force-unwraps in production code, null
   derefs, off-by-one, unsafe casts. Especially around Core Audio handles
   (`AudioObjectID`, tap descriptors) where misuse panics the audio
   subsystem rather than the app process.
2. **Concurrency.** `@MainActor` boundaries, `Task.detached` correctness,
   `Combine` publisher threading, `os_unfair_lock` discipline. AVAudioEngine
   lifecycle has hard threading rules; ADR-006 covers them.
3. **Core Audio HAL contract compliance.** Process taps need
   precise property/listener cleanup. A leaked tap can leave the system in
   a state that requires a logout to recover.
4. **API contract changes** in the public protocols
   (`EffectNodeProtocol`, `CaptureControllerProtocol`,
   `CoreAudioInterfaceProtocol`). Breaking these breaks every consumer.
5. **Missing edge-case tests** for the items above.
6. **Documentation drift** — comments / docstrings / spec sections that
   disagree with the code now.
7. **Security** — secret handling, file-path validation, AppleScript /
   shell-out injection surfaces if any are introduced.

---

## What to NOT focus on (or focus on with care)

- **Style suggestions that don't check the rest of the codebase.** A
  specific cautionary tale: PR #7 had a CR finding suggesting
  framework-then-internal import grouping in `PresetMenu.swift`. Every
  other `Sources/UI/*.swift` in the repo uses pure alphabetical ordering.
  The suggestion produced a one-file deviation rather than a consistency
  fix. If you flag a style issue, verify it's a deviation from the
  codebase's pattern, not a deviation from your training-data prior. See
  `docs/governance/review-journal/pr-7.json` thread `PRRT_kwDOSjmLjM6D9tgE`
  for the full disposition.

- **Documented design decisions you disagree with.** If the diff aligns
  with an ADR, the ADR's "Considered" section already covers the
  alternatives. Re-raising those alternatives without engaging with the
  ADR's rationale produces noise, not signal.

- **Things the linter / CI already catches.** Whitespace, semicolons,
  trailing commas — let the toolchain handle them.

- **The `review-verdict` block format itself.** If a thread reply starts
  with a fenced `review-verdict` block, that's the maintainer's
  disposition format (see below). Don't flag it as malformed markdown or
  suggest changes to its structure.

---

## Verdict-block format (what the maintainer's reply will look like)

Every reply on a review thread starts with a fenced block:

````markdown
```review-verdict
verdict: ACCEPTED_MODIFIED
commit: 14b240b
finding_category: source-resolution-correctness
reviewer: chatgpt-codex-connector
notes: PID-first match; bundle fallback kept for relaunch-between-pick-and-start.
```
````

Vocabulary:

- `ACCEPTED` — applied verbatim
- `ACCEPTED_MODIFIED` — fixed via a different patch
- `DEFERRED` — valid but pushed to V0.N / ADR-NNN
- `REJECTED_FALSE_POSITIVE` — premise is wrong
- `REJECTED_BAD_FIT` — generic suggestion conflicts with local convention
- `REJECTED_REGRESSION` — fix would make code worse
- `OBSOLETE` — already addressed in an earlier commit
- `DUPLICATE` — same as thread X

You don't need to do anything with this — it's the maintainer's response
surface. But knowing the format prevents you from misreading the reply.

The full discipline is documented in
`docs/governance/review-protocol.md` and the tooling in
`tools/review-journal/README.md`.

---

## Severity vocabulary

Use the project's existing severity ladder consistently:

- **P0** — block-merge: would corrupt data, crash the app, expose a secret,
  or violate a hard correctness contract
- **P1** — major: bug, race condition, broken edge case, missing test for
  a critical path
- **P2** — minor: code smell, suboptimal pattern, missing test for a
  secondary path
- **P3** — nit: style polish where the linter doesn't cover it

This matches the `chatgpt-codex-connector` convention captured in
`.review-journal.json`. The journal tool extracts severity from inline
findings using this scale.

If you use a different scale (CR uses Critical / Major / Minor / Nit),
state it explicitly in the finding body so the journal can parse it.

---

## Decision logging conventions

- **ADRs** (`docs/decisions/ADR-NNN-*.md`) — committed design choices
- **Dissent log** (`docs/decisions/dissent-log.md`) — rejected alternatives
  and reasoning
- **Uncertainty log** (`docs/decisions/uncertainty-log.md`) — open questions
  the orchestrator can't fully resolve

If a PR adds an ADR, the substance of the decision is in the ADR; the diff
just lands the file. Don't critique the diff's mechanics if the ADR's
reasoning is sound.

---

## A note on hallucination risk

Core Audio, AVAudioEngine, ScreenCaptureKit, and the macOS hardened-runtime
entitlements are sparsely documented in places. Your training data likely
has gaps. If you're not sure an Apple API behaves the way you remember,
say so in the finding — "I think this might fail when X; please verify
against the current macOS 14.x SDK behavior" is more useful than a
confident-but-wrong recommendation.

The repo's ADRs synthesize the load-bearing Apple-API knowledge for this
project. When the ADR documents an API quirk, trust the ADR over your
prior.

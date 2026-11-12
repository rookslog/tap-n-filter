# Decisions

This directory contains the project's decision record. Three kinds of documents live here:

1. **ADRs** (Architecture Decision Records) — discrete decision documents, one file per substantive choice. ADRs are written when a decision is committed and the reasoning matters for future readers.

2. **The dissent log** (`dissent-log.md`) — append-only record of option-between-options choices made during build. Smaller than ADRs; one entry per choice.

3. **The uncertainty log** (`uncertainty-log.md`) — append-only record of open questions. Tracks what isn't decided yet and what would resolve it.

The three kinds of documents serve different purposes. ADRs are commitments. The dissent log is a trail of "we considered X but went with Y." The uncertainty log is a list of "we don't yet know about Z."

## ADR format

Each ADR is a Markdown file at `ADR-NNN-<short-name>.md`. NNN is the next available three-digit number. Once assigned, the number is permanent; ADRs are not renumbered.

ADRs follow this structure:

```markdown
# ADR-NNN: <Title>

## Status

Accepted | Proposed | Superseded by ADR-MMM | Deprecated

## Context

What's the situation that requires a decision? Why is this question being raised now? What are the constraints?

## Decision

What did we decide? Be specific. The decision should be a sentence or two, possibly followed by elaboration.

## Alternatives considered

What other options did we consider? For each, briefly: what is it, why we didn't pick it.

## Consequences

What follows from this decision? What does it preclude? What does it enable? What new risks does it create?

## References

External links, other ADRs, conversation references that informed the decision.
```

## When to write an ADR vs a dissent log entry

- **ADR**: substantive architectural decisions. Things that shape the system. Examples: capture API choice, plugin architecture, sandbox decision, file format choice. Things that another developer reading the code would want to know the reasoning for.

- **Dissent log entry**: option-between-options choices made during build that aren't substantial enough to warrant an ADR. Examples: which library to use for DMG creation, what factory reverb preset to default to, which folder to put preset files in.

Threshold heuristic: if the decision required more than 10 minutes of thought, or commits the project to a path that affects multiple files, it's likely an ADR. Smaller decisions go to the dissent log.

## When to add an uncertainty log entry

Add an entry when you discover a question whose answer would change behavior but isn't currently determined. Examples:

- "Does AVAudioUnitReverb's largeHall preset give the right aesthetic at 70% wet, or do we need custom IRs?" (resolved by Phase 2 ear test)
- "Will MenuBarExtra host modal dialogs correctly in the current macOS version, or do we need an AppKit fallback?" (resolved by Phase 3 implementation)
- "What's the right level-compensation factor for multi-pair output devices?" (deferred to V0.2)

Each uncertainty entry has:
- A trigger condition: what would prompt revisiting it.
- A best guess: what the project is doing in the meantime.
- A resolution path: how the question would be answered.

## Lifecycle

- An ADR starts as `Proposed`. Once committed and acted on, status becomes `Accepted`.
- An ADR that's later replaced becomes `Superseded by ADR-MMM`. The new ADR references the old one.
- An ADR that's no longer relevant (the system no longer does what it described) becomes `Deprecated` with a note about when and why.

The dissent and uncertainty logs are append-only. Entries are never deleted. When an uncertainty is resolved, the entry is updated with a note pointing to the resolving ADR; the entry itself remains.

## Currently committed ADRs

- `ADR-001-capture-api.md` — Core Audio Process Taps for capture.
- `ADR-002-plugin-architecture.md` — EffectNode protocol, V1 closed set, V2 AUv3.
- `ADR-003-no-sandbox-v1.md` — V1 is unsandboxed; distribution via signed DMG.
- `ADR-004-name.md` — Why "tap-n-filter."
- `ADR-005-min-macos-version.md` — macOS 14.4 minimum.

Additional ADRs are written during build as decisions surface. They use ADR-006 onward.

## Proposed on the block-runtime branch

- [ADR-023](ADR-023-apple-silicon-audio-execution.md) records the Apple Silicon
  scheduling, DSP, native-build and live-analysis direction and its measurement
  gates. It is not a completed runtime optimization or a change to ADR-006.

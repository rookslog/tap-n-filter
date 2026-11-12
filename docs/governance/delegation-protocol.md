# Delegation Protocol

When the orchestrator delegates work to a subagent, the delegation has to carry its own context. The subagent does not see the orchestrator's conversation. A vague prompt produces vague work. A concrete prompt with the right inputs, the right scope, and the right output contract produces work the orchestrator can use without re-doing it.

This document specifies when to delegate, how to write a delegation prompt, which model to pick, and what to do with the result.

## When to delegate

Delegate when **all** of these are true:

1. **The work has a concrete enough plan.** The orchestrator can describe what the subagent should do in finite steps, with a defined output. If the orchestrator is still figuring out the approach, the orchestrator does the work — figuring it out is the work.

2. **The work doesn't need the orchestrator's full conversation history.** The subagent can succeed with the files it reads, the prompt it gets, and what it can run. If the work depends on judgment built up over a long conversation, that judgment is harder to transfer than to use directly.

3. **The orchestrator materially benefits.** Either (a) the work would consume a lot of the main session's context window with intermediate output that doesn't need to be there (e.g., long code generation, file enumeration, search results), or (b) the work benefits from context isolation (e.g., a verification step that should evaluate the diff fresh without seeing the orchestrator's reasoning), or (c) the work parallelizes with other work the orchestrator is doing.

Do **not** delegate when:

- The plan is half-formed. Delegating "go figure out X" produces shallow work.
- The work is one short step. The round-trip overhead exceeds the savings.
- The work requires negotiating with the user or applying judgment built up in this conversation. The subagent can't see that conversation.

## Subagent types in this project

Five subagent categories appear in the tap-n-filter build:

| Type | Purpose | Lives where | Model |
|---|---|---|---|
| Framing auditor | Cold-context full-bundle review (Phase -1) | `docs/governance/audit-protocol.md` | Opus |
| Audit-response | Per-finding triage of the auditor's report | `docs/governance/audit-response-protocol.md` | Opus |
| Verification | Per-criterion check + audit-lite at each phase gate | `docs/governance/verification-protocol.md` | Sonnet (default); Opus for human-input phases when the orchestrator wants stronger audit-lite reasoning |
| Code-writing | Implement a phase's source per the corrected specs | This doc + the phase spec | Sonnet for mechanical translation; Opus for API surfaces that need careful reasoning (Core Audio HAL, AVAudioEngine lifecycle, AUv3 hosting, signing) |
| Ad-hoc research | Code search, "where is X defined", multi-file scan | Inline (Explore agent) | Inherits orchestrator's model unless specified |

### Why these model choices

**Opus** is the right pick when the subagent has to:

- Make judgment calls the orchestrator can't itemize in advance (auditor: "what's load-bearing here?"; audit-response: "is this finding genuinely escalation-worthy?").
- Reason about implications that aren't on the surface (auditor's three-persona pass — same bundle read three different ways).
- Push back on stronger-stated positions (audit-response disagreeing with the auditor; verification flagging an unsound addition that wasn't in the diff).
- Implement against APIs where the docs are sparse and the orchestrator's spec snippets may be subtly wrong (Core Audio Process Taps, hardened-runtime entitlement edges).

Opus is more expensive per token, so the cost-bound criterion is "this runs once per phase or twice per project, not on every diff."

**Sonnet** is the right pick when the subagent has to:

- Apply explicit criteria mechanically (verification: "does the diff contain X? if yes, Met; if no, Not met").
- Translate well-specified intent into code (a corrected spec snippet into a Swift file).
- Run a tool and report the output (`swift build`, `gh pr checks`).

Sonnet is cheaper and faster. When the spec is corrected (post-framing-audit) and the orchestrator just needs the spec applied, Sonnet is the default.

Model selection lives on the delegation, not on the subagent type. A code-writing subagent for boilerplate test scaffolding is Sonnet; the same subagent type asked to implement a tricky AVAudioEngine lifecycle is Opus. The orchestrator picks at call time based on what the work actually requires.

### Code-writing model decision rubric

| Trait | Sonnet | Opus |
|---|---|---|
| Spec is concrete and the code is mechanical (CRUD, glue, tests for already-spec'd surfaces) | ✓ | |
| Spec involves a sparsely-documented Apple API (Core Audio HAL, ScreenCaptureKit, hardened runtime entitlements, notarytool flags) | | ✓ |
| Spec involves cross-cutting concerns (AVAudioEngine lifecycle invariants, threading, real-time constraints) | | ✓ |
| Spec involves UI work where SwiftUI has known sharp edges (MenuBarExtra + modal panels, accessibility-tree dump) | | ✓ |
| Spec is "implement what `docs/specs/X.md` says" and the spec was post-audit corrected | ✓ | |
| Output volume is large (multi-thousand-line module across many files) | ✓ (Sonnet handles bulk efficiently) | |

If the rubric pulls both ways, default to Opus — the orchestrator can re-delegate to Sonnet if Opus over-engineers, but rescuing under-engineered Sonnet output costs more.

## Writing a delegation prompt

A good delegation prompt has six parts. Skip any and the result degrades.

### 1. Role and posture (1–3 sentences)

What kind of work the subagent is doing. "You are implementing Phase 2…" or "You are the verification subagent for Phase 1…". This is also where you set tone: rigorous, mechanical, judgment-heavy, etc.

### 2. Working directory and branch

Absolute path. Branch the subagent should treat as base (the subagent does not switch branches without explicit instruction). For verification subagents, also specify what diff to read (`git diff main...HEAD`).

### 3. Required reading FIRST

A numbered list of files to read before doing anything else. The subagent reads in order. For a code-writing task, this is the spec, the relevant ADRs, the coding standards. For a verification task, this is the phase spec, the verification protocol, the diff. Do not assume the subagent will search for these; list them.

### 4. What to build / evaluate

The concrete plan. For code: which files to write, which functions to implement, what the public surface should look like (in many cases, paste the surface from the spec). For verification: which gate criteria, what evidence to look for. For research: what question to answer, what counts as sufficient evidence.

Be precise about the public surface. "Implement `EQNode` per the spec" leaves more room for drift than pasting the protocol the type must conform to. The subagent doesn't have the orchestrator's intuition about which details matter.

### 5. Constraints

What the subagent must not do. "Don't update state.json." "Don't commit." "Don't add dependencies." "Don't write code for the next phase." "Use only Apple frameworks." Constraints prevent drift that would force the orchestrator to undo work.

### 6. Output contract

What the subagent returns when it's done. For code: the list of files created/modified, the build status, any deviations from spec the subagent had to make to compile, any limitations needing real-system validation. For verification: the verdict (PASS/FAIL) plus the report path. For research: a short summary + the file path of any longer artifact.

The output contract is the boundary the orchestrator uses to validate the subagent's work without re-doing it. A vague "report back" produces vague reports the orchestrator has to chase.

## Worked example (code-writing, Sonnet)

```
You are implementing Phase 1 (Capture Spike) for tap-n-filter. Write the
Swift code that captures audio from a chosen application via Core Audio
process taps and routes it through AVAudioEngine.

## Working directory
<checkout>
Branch: phase-1-capture (already checked out)

## Required reading FIRST
1. docs/orchestration/phases/01-capture-spike.md
2. docs/specs/capture.md
3. docs/decisions/ADR-001-capture-api.md
4. docs/governance/coding-standards.md

## What to build
Replace the placeholder Sources/Capture/Capture.swift with:
- CaptureControllerProtocol.swift — exact protocol from the spec.
- CaptureSource.swift — struct with pid, audioProcessID, bundleIdentifier, displayName.
- CaptureState.swift — enum: idle | starting | running(source) | stopping | failed(CaptureError).
- CaptureError.swift — typed error enum.
- CoreAudioInterface.swift — protocol seam + RealCoreAudioInterface implementing
  the HAL calls per the corrected spec (pid translation via
  kAudioHardwarePropertyTranslatePIDToProcessObject; tap UID via kAudioTapPropertyUID).
- CaptureController.swift — final class state machine using CurrentValueSubject.

Tests under Tests/CaptureTests/: FakeCoreAudioInterface + 10 named state-machine tests.

## Constraints
- macOS 14.4 SDK only. Use only Apple frameworks.
- Build target is `swift build` against the existing Package.swift.
- Don't update state.json. Don't commit. Don't write Phase 2 code.

## Output
1. Run `swift build` and confirm clean. If it fails, fix and re-run until clean.
2. Report files created/modified, build status, any spec snippets that needed
   minor correction to compile, and any unverified-without-real-audio claims.
```

That prompt produces a single round-trip and gives the orchestrator a self-contained report. Compare to "implement the capture module per the spec" — same intent, an order of magnitude less precise.

## Worked example (verification, Sonnet)

```
You are the verification subagent for tap-n-filter Phase 1. Evaluate
whether the orchestrator's work meets the gate criteria in the phase spec.

## Working directory
<checkout>
Branch: phase-1-capture

## Required reading FIRST
1. docs/orchestration/phases/01-capture-spike.md (gate criteria)
2. docs/governance/verification-protocol.md (report schema)
3. The diff for this phase: `git diff phase-0-init..HEAD`
4. Sources/Capture/ in its current state
5. Tests/CaptureTests/ in its current state

## What to evaluate
For each numbered gate criterion in the phase spec, mark Met / Not met / Unable
to evaluate with the evidence you saw in the diff or the file tree. Apply the
criteria literally — do not infer compliance from absence of contradicting evidence.

Also answer the framing-audit-lite question per verification-protocol.md.

## Output
Write the report to docs/audits/verification/phase-1.md per the schema in
verification-protocol.md. Return PASS or FAIL with one sentence on why.
```

Note the verification prompt is shorter than the code-writing prompt. The subagent's job is mechanical (read spec, read diff, mark criteria), not generative.

## Worked example (audit, Opus)

The full template is in `audit-protocol.md`. The orchestrator does not rewrite it per phase — it pastes the canonical prompt and attaches the inputs. The auditor's job is judgment, not template-following, so the prompt is longer and the input list is exhaustive.

## What the orchestrator does with the result

For every delegation:

1. **Read the subagent's report carefully.** The report describes what the subagent intended to do, not necessarily what landed. Spot-check.

2. **Verify the deliverable independently.** For code: read at least the touched files' new public surface and run `swift build` / `swift test` yourself. For verification: confirm the report file landed at the expected path and the verdict matches the report body. For research: confirm the cited evidence actually says what the summary says.

3. **Commit the subagent's output, not the orchestrator's interpretation.** If the auditor wrote findings the orchestrator disagrees with, the disagreement goes in the audit-response, not in an edit to the audit. If the verifier returned FAIL with a gap the orchestrator can close, close the gap and re-run a fresh verification; don't edit the report.

4. **Capture lessons.** If the subagent produced something the orchestrator had to substantially rework, that's signal: the prompt was under-specified, the model was wrong for the task, or the work was a bad delegation candidate. Note this in the dissent log (`docs/decisions/dissent-log.md`) so the next phase's orchestrator can adjust.

## Anti-patterns

- **Re-delegating after a bad result without diagnosing why.** If a subagent produced shallow work, ask what was missing: the spec, the constraints, the model? Re-spawning with the same prompt produces the same result.
- **Delegating because the orchestrator is bored.** If the work is small and the orchestrator already has the context, just do it.
- **Stacking delegations.** If a subagent's output requires another delegation to process, that's two round-trips' worth of latency for what may be one piece of work the orchestrator should have kept.
- **Trusting the subagent's "I'm done" without checking.** Always validate independently before marking the work as complete. See "What the orchestrator does with the result."
- **Letting model choice drift upward by default.** "Opus is safer" is true and also expensive. The default for mechanical work is Sonnet; Opus is for the cases the rubric says need it.

## References

- `docs/governance/audit-protocol.md` — the framing auditor's canonical prompt (Opus).
- `docs/governance/audit-response-protocol.md` — the audit-response agent's protocol (Opus).
- `docs/governance/verification-protocol.md` — the verification subagent's prompt and schema (Sonnet default).
- `docs/governance/quality-gates.md` — when each subagent runs.
- `docs/decisions/dissent-log.md` — record poorly-fitting delegations here so future orchestrators learn.

# ADR-023: Apple Silicon audio execution and analysis

## Status

Proposed, 2026-10-28. Engineering implementation direction for the new block
runtime, subject to the measurements below. This does not claim a completed
renderer, a speedup, a measured deadline result or release acceptance. The
existing Graph and ADR-006 remain unchanged.

## Context

The new block runtime targets native Apple Silicon. Hardware-specific core
counts do not determine a hard-coded thread count; actual deadline measurements
must inform scheduling choices.

The product needs simultaneous per-app chains and click-free changes. Analysis
is visible-editor-only and idle in silence (A21). About 30 ms added delay is the
v1 experience target, not a substitute for meeting each render deadline. Existing
spikes did not establish these scheduling or acceleration comparisons.

## Decision

### 1. Audio workgroups follow the deadline, not a CPU-count heuristic

Keep framework-owned rendering on its managed audio threads. Apple says those
threads already participate in workgroups. Do not join the same thread twice or
put authoring/analysis tasks into an audio workgroup. [Meet Audio Workgroups](https://developer.apple.com/videos/play/wwdc2020/10224/)

If measurement justifies custom auxiliary real-time processing threads, join
them to the group for the output deadline they actually help meet. Obtain the
device group using the documented HAL/Audio Unit property, and respect a changed
group after output/format replacement. Independent-deadline workers need their
own interval group, not an arbitrary app capture device's group. This is an
implementation obligation, not an immediate decision to add workers.
[Workgroup Management](https://developer.apple.com/documentation/audiotoolbox/workgroup-management)

Workgroups inform scheduling. They are not a contractual pin to performance
cores. Apple describes the performance controller choosing resource placement;
we will observe deadline performance instead of inferring it from membership.
[Meet Audio Workgroups](https://developer.apple.com/videos/play/wwdc2020/10224/)

Join/leave on the participating thread, retain the actual join token, handle
errors, and leave before thread exit or group replacement. The selected SDK's
`os/workgroup_object.h`, os_workgroup_join/os_workgroup_leave, documents these
requirements and real-time-safe calls. Native ownership belongs in the bounded
runtime layer, not in a Swift actor or an arbitrary Task. Joining is not itself
a replacement for a real-time scheduling policy or a bounded callback.

### 2. Accelerate first for bulk DSP; scalar/SIMD where it wins

Use Accelerate/vDSP as the first candidate for vector gain, branch sums, meters,
biquad processing where appropriate, and FFT. Apple supplies optimized CPU
implementations. Do not replace an existing Audio Unit's internal DSP with a
home-grown filter merely to add a vDSP call. Keep setup, buffer allocation and
FFT plan creation outside the callback. [Accelerate](https://developer.apple.com/documentation/accelerate)

Compare scalar, small SIMD and vDSP at the actual block/channel sizes. Library
call overhead can matter for tiny vectors; that is a measurement question, not
an asserted winner. Use contiguous preallocated storage and inspect denormals,
aliasing and tails. Keep a numerical reference and tolerances alongside timing.
There is no handwritten NEON or CPU-model dispatch in the first implementation.

### 3. Separate UI, preparation and analysis priorities

The audio callback never waits for UI, analysis, persistence or compilation.
Use bounded handoff to preparation; coalesce superseded intent. User-visible
plan preparation starts at user-initiated priority; background preparation,
autosave and visible-but-discretionary analysis use utility where appropriate.
Do not lower the UI main thread or pretend it belongs on efficiency cores.
QoS communicates importance; it is not core affinity. Apple's QoS categories
and priority-inversion guidance support this split.
[Energy Efficiency Guide, task-level priority](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheTaskLevel.html)

Pause analysis when the editor is hidden and skip idle-silence work. Send a
throttled/downsampled display snapshot, not per-sample UI notifications. The
callback must remain independent if the analysis consumer falls behind.

### 4. Native arm64 only for the new implementation

Build and profile the new runtime natively on Apple Silicon, with no Intel app
slice planned for this implementation. No Rosetta launch,
x86 helper or plug-in bridge is part of this slice. Check produced Mach-O files
and loaded code in native runtime acceptance. A future plug-in-hosting feature
must explicitly preserve that native boundary; no plug-in loader exists in this
unit. This is not an Apple claim that translated code cannot work.
[Port your Mac app to Apple silicon](https://developer.apple.com/videos/play/wwdc2020/10214/)

Apple's current macOS 27 compatibility list contains Apple Silicon Macs. That
supports the chosen target; it does not itself enforce a native app binary.
[macOS 27 compatibility](https://www.apple.com/os/macos/)

No Intel-only dependency, universal-binary distribution promise or minimum-OS
change is introduced by this first model unit. The existing Package.swift floor
remains 14.4. Release packaging must enforce the selected arm64-only target when
there is a release artifact; no machine/global build settings are changed here.

### 5. CPU FFT first; no Metal compute in the audio dependency path

Start waveform envelopes and modest spectrum analysis on the CPU. vDSP supplies
FFT support. That establishes an available tool, not sufficient performance for
our as-yet-unbuilt live views. [Accelerate](https://developer.apple.com/documentation/accelerate)

Use the designer's native rendering brief for drawing. Metal is deferred unless
the real view's CPU, energy or frame-time measurements justify it. If adopted,
it consumes asynchronous analysis snapshots; the render callback never waits
for a GPU command or readback. This choice avoids an unmeasured second compute
pipeline while keeping GPU drawing available if the visual design needs it.

### Disposition of the designer's parallel proposal

The design lane supplied APPLE-SILICON.md after this ADR was first written.
Agreement is independent design input, not a performance result.

| Point | Disposition and reason | Observation that would change it |
|---|---|---|
| (a) Process every chain inside its tap IOProc; output only mixes/limits | **Reject as the unconditional/default placement.** First measure an output-driven fixed renderer with independent chain instances, keeping tap callbacks at bounded capture/de-interleave/ring writes. This matches the existing source/output handoff and puts all chains on the output clock. A separate capture-side-DSP variant remains a valid contender, not an implemented rejection of it. Distinct taps do not establish separate-core parallelism; their rates, buffers and clocks still need reconciliation. Running manual/native processors in capture callbacks also needs the exact backend contract checked. | A controlled native comparison showing deadline/energy benefits for capture-side processing without worse alignment, drift, latency or replacement behavior would select it. Neither placement has that evidence yet. |
| (b) arm64 only | **Accept for the new app implementation.** Native app/runtime/helper dependencies are the target, with no Rosetta route. The current Apple compatibility list corroborates the macOS 27 hardware premise. No new minimum-OS rule is silently added to Package.swift by this decision. | An explicit operator requirement to support Intel or a discovered required non-native dependency would reopen the architecture/product boundary, not trigger an automatic translation fallback. |
| (c) Skip silent processing; off pieces leave; lower live-view rate in Low Power Mode | **Accept with state-aware silence eligibility.** Off pieces leave the prepared plan after their click-free transition. A chain can sleep only when input is quiet and there is no active tail/history, generator, transition or smoothing work that can still change output. Advance required state before sleeping; wake before a newly nonzero block is processed. Low Power Mode reduces discretionary analysis/display update rates, never audio rate or control responsiveness. A callback still has a scheduling/handoff cost, so “silence costs nothing” is not a literal CPU claim. | Missed onset samples, lost tails, a generator wrongly silenced or a measured battery/frame-time problem requires changing the eligibility/rate policy before acceptance. Numeric silence thresholds, tail caps, hold times and frame rates remain measured backend/view settings, not invented product constants here. |

The placement comparison must include single and four-source work, parameter
changes while a plan prepares, mixed input rates, source loss/re-prime and
branch alignment. Any choice of custom worker workgroup follows its actual
deadline: an auxiliary worker helping a capture-side cycle does not blindly
join the unrelated output device group. No part of this disposition rewires
the running app or asserts workgroup membership of the current tap callbacks.

## Alternatives considered

- A real-time worker per app or per performance core. Deferred. It can add
  synchronization and oversubscription before the actual bottleneck is known.
- Raise every queue to the highest QoS. Rejected. It competes with audio and
  wastes energy without expressing which tasks can be deferred.
- Force efficiency-core placement for all non-audio work. Rejected as a contract.
  We set appropriate priorities and measure the system's choices.
- Metal-first FFT/DSP. Deferred. No result establishes a benefit for this
  workload; GPU synchronization must not become part of an audio deadline.
- Optimize the pure authoring evaluator with vDSP now. Deferred. It is not in
  the callback and has no measured bottleneck. Correctness comes first.

## Consequences and measurement gates

The first model unit adds no real-time threads or Accelerate dependency. Apply
this ADR to the renderer, analysis and per-app slices before those are accepted.
The following tests remain **not run** until a real native backend exists.

| Question | Controlled comparison and recorded evidence |
|---|---|
| Does custom workgroup membership help? | Same native binary and four independent app chains, fixed effects, buffer size, sample rate and output route. If custom auxiliary workers exist, alternate their valid membership on/off in at least five paired runs after warm-up. Framework workgroup membership remains untouched. With no custom workers, report this comparison not applicable instead of creating threads to manufacture an experiment. |
| What deadline is missed? | Timestamp callback entry, completion, expected cycle and source underruns in bounded preallocated records. Report per-run denominators, p50/p95/p99/max execution and wake lateness, overload/deadline counts, dropped trace records and route changes. Use Audio System Trace to corroborate scheduling where available. A duration below one period alone is not evidence the callback met its deadline. |
| Under which interference? | Compare editor hidden, visible with deterministic slider/reorder load, and analysis enabled/disabled. Match thermal/power state and record competing load. Never attribute a memory-pressure run solely to the workgroup setting. |
| Does placement or power state change the result? | Compare capture-side versus output-driven processing with 1, 2 and 4 independent sources at the same DSP workload, including mixed source rates. Repeat on battery and in Low Power Mode; record output/input buffer schedules, drift correction, wake behavior, tails and onset preservation. Do not infer parallel core use from the number of callbacks. |
| Which arithmetic kernel? | At the real 1/2-channel buffer lengths and branch counts, compare scalar/SIMD/vDSP with preallocation and setup excluded. Check numerical equivalence, peak CPU, tails and sustained energy. No dummy loop or FFT-only number substitutes for chain deadlines. |
| Does the live view need Metal? | Use the actual screen brief and data rate. Record frame-time distribution, skipped updates, analysis CPU and energy with CPU FFT. Evaluate a GPU alternative only after a concrete bottleneck appears. |
| Is the executable native? | Inspect Mach-O architecture and runtime translation status. Record any loaded native plug-in/helper when such a feature exists. |

All live output is announced with duration beforehand. Keep the Bluetooth
microphone closed and acquire/restore DefaultInputGuard through its owning
runtime lease. Headless model measurements neither exercise nor certify HFP,
physical delay, four real captures, listening quality or real-time safety.

## References

- ADR-006, existing graph lifecycle; ADR-018, IOProc capture; ADR-019, HFP;
  ADR-021, output limiter. None is silently superseded here.
- Apple primary sources linked beside the claims above, consulted 2026-10-28.
- Local SDK, `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/os/workgroup_object.h`.

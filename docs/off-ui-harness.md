# Silent OFF UI harness

This developer-only surrogate is **off by default**. It opens the actual menu
and uses the real gesture, model, coordinator and owned-file persistence paths.
It never selects the normal delegate or constructs playback, capture, input-guard
or audio-engine objects. It refuses power/compare ON actions. It is not physical
input, sound-playing, audio-thread, native restore or whole-app qualification.

Run only when native UI execution is explicitly authorized. Use a separately
prepared development bundle from this source checkout, including its resource
bundles, at `Build/tap-n-filter.app`. Do not substitute an installed working copy,
old binary, or existing library. Bundle preparation/signing is a separate step;
these instructions do not change signing credentials or build settings.

## Prepare fresh owned data

From the repository root, prepare a new UUID directory outside the checkout.
The program accepts only the exact three flags below. It validates canonical
paths, ownership, private directory permissions and the marker, refuses existing
library files, then exclusively claims `started.lock` **before** AppKit startup.
Mixed probe/smoke flags and duplicate perf flags refuse without normal fallback.

```sh
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
RUN_DIR="$(python3 - "$RUN_ID" <<'PY'
import json
import os
from pathlib import Path
import sys
import tempfile

run_id = sys.argv[1]
directory = Path(tempfile.gettempdir()).resolve() / ("tnf-perf-" + run_id)
directory.mkdir(mode=0o700)
marker = directory / "owner.json"
fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as stream:
    json.dump({"runID": run_id, "uid": os.getuid()}, stream)
print(directory)
PY
)"
```

Do not reuse a run directory or create the library yourself. The resulting
`owner.json`, `library-v5.json`, phase records and logs are local measurement
artifacts, not source fixtures to publish.

## Explicit OFF launch and handshake

```sh
APP="$PWD/Build/tap-n-filter.app"
"$APP/Contents/MacOS/tap-n-filter" \
  --perf-scenario drag \
  --perf-run-id "$RUN_ID" \
  --library-session-file "$RUN_DIR/library-v5.json" \
  >"$RUN_DIR/app.log" 2>&1 &
PID=$!
```

Other scenario values are `switch`, `menu-open` and `idle`. Drag requests 900
Softer positions over 15 seconds at 60 Hz; switch requests 15 Place changes at
1 Hz. Direct scalar moves, including option children, are latest-wins within an
exact control/context segment. Driven and unknown controls remain ordered with
their existing semantics. No saved-sound format or driven-hand semantics change.

1. Read `phase.json` in the run directory. Continue only after `phase` is `ready`,
   its `runID` matches, `soundOff` is true and `audioObjectsConstructed` is false.
2. Create the `go` marker. Non-idle scenarios open the menu internally. Do not
   use a screen-driving or accessibility workaround.
3. Wait for `phase` to become `settled`. Then create `collector-done` to request
   final drain, owned save/reopen and normal self-exit. The name is the existing
   handshake protocol; this manual entry does not run an external collector.

```sh
# Only after the ready record has been checked:
touch "$RUN_DIR/go"
# Only after the settled record has been checked:
touch "$RUN_DIR/collector-done"
wait "$PID"
```

The delegate bounds missing handshakes and records failures. Do not force-kill it
or treat exit status alone as success. Inspect the final `finished` record:
`failures` must be empty, sound must remain OFF, `drainedMutations`,
`finalDrainSaved` and `saveReadbackChecked` must be true, and requested/observed/
reopened values must agree when events were requested. Accounting version 3 separates `liveEvaluations`/`liveDeliveries` and
`liveEvaluationSeconds` from actual `documentCommands`, `documentCommandSeconds`
and their outcomes. `executed` and `ownerMoveSeconds` retain document-command
meaning; live ticks are not document moves. Qualified direct scalar drags use
load-prepared complete mappings and explicit transient row/native state, then
flush the final value through a real document command at release or an ordered
boundary. Driven, custom and unknown controls keep their ordered full path.
Successful committed writes and identical commit calls are distinct.

For the uninterrupted direct drag, require positive accounted live work, equal
live evaluations and deliveries, one final document command, zero full reads or
saves during dragging, one release full read and one committed release save.
Check the final document value and fresh reopen, not just the transient row.
Release-to-settled must be at most 100 ms; an interrupted or incomplete workload
is not a successful sample.

No handshake polling runs during the active workload. Document-command elapsed
durations exclude actor-queue wait and UI publication. Live-evaluation elapsed
durations include complete-part evaluation, admission and synchronous UI/delivery.
Both can include OS descheduling and are not pure CPU or audio-thread measurements. This entry provides no CPU/RSS collector,
matched baseline or performance-budget acceptance. Keep counters and profiler
diagnostics separate and retain artifacts outside the public tree.

Without perf flags, ordinary packages continue normal startup without a perf
delegate or harness timers. A package marked `TNFPerfOnly` instead refuses an
ordinary launch. Deterministic ownership, accounting and coalescer checks run in
default SwiftPM tests; they do not launch this menu or establish native timing.

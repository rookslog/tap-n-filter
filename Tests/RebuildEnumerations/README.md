# Menu enumerations

These checks enumerate every event sequence of a given length that a reference model allows, run each
sequence against the real menu session, coordinator and playback controller, and compare the two event
by event. Capture and output are fakes, so nothing plays sound or needs a window. The reference model
is `ReferenceModel.swift`; it imports nothing from the app.

They are long, so `swift test` skips them unless `TNF_ENUM` is set.

## Suites

| Suite | What it enumerates | Length | Sequences |
|---|---|---|---|
| S1 | Live-value admission: two drags, drag samples, drag end, a choice click, a keyboard slider step, a held and released save | 5 | 1,997 |
| S2 | Admission with editor reads that succeed or fail, a refresh, and a held save | 4 | 1,685 |
| S3 | Admission with stale and current cards, an editor read, source or format changes, a structural command, a lane publication, a refresh and a menu open | 4 | 10,170 |
| S4 | Lane life on the real playback controller: power ON and OFF by activation and by positions, parameter changes, start and stop completions, a lost source, retry. Run at hold points 0, 1 and 2 (capture prepare, output prepare, capture start) | 5 | 6,763 per hold point |
| S5 | Lane life through the real coordinator: power, slider steps, start and stop completions, retry, and a return to an earlier value delivered through the other delivery mode | 5 | 2,218 per hold point |

A sequence is green when the real outcomes, the settled saved, live and shown values, and the
invariants all match the model, and no wait timed out. A sequence the build cannot drive, or an order
the real runtime cannot produce, counts as unsupported. A shard passes only when the enumeration has
the pinned size, every sequence in its range ran, and all of them are green.

## Running a shard

A spec is `SUITE LENGTH HOLD FROM COUNT`. S1, S2 and S3 take `x` as the hold; S4 and S5 take 0, 1 or 2.
Several specs can be joined with `;`.

```sh
TNF_ENUM="S3 4 x 0 3390" swift test -c debug --filter RebuildEnumerationTests
TNF_ENUM="S1 5 x 0 1997;S4 5 1 0 6763" swift test -c debug --filter RebuildEnumerationTests
```

Each spec prints one line such as:

```
ENUM-SUMMARY suite=S3 level=4 hold=x from=0 count=3390 total=10170 green=3390 red=0 unsupported=0 result=clean seconds=1450.2
```

## Running one sequence

The enumeration order is deterministic. A red sequence is printed with its index, for example
`RED S3 L4 #4711 [...]`, and runs alone as a one-sequence shard:

```sh
TNF_ENUM="S3 4 x 4711 1" swift test -c debug --filter RebuildEnumerationTests
TNF_ENUM="S5 5 2 812 1" S5_VERBOSE=1 swift test -c debug --filter RebuildEnumerationTests
```

## Other switches

- `MODE=send` sends admission menu actions back to back instead of waiting for each outcome.
- `LANE_MODEL_MUTANT=<name>` compares S4 and S5 with a deliberately wrong lane model (`BMutant` in
  `ReferenceModel.swift`), to show the comparison can go red.
- `SETTLE=heuristic` settles S4 by yields only, without controller quiescence, and reports late results.
- `S5_VERBOSE=1` prints every delivery and every S5 run.

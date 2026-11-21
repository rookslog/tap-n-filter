#!/usr/bin/env python3
"""Layout checks C1 and C2 over the card renderer's render-index.json files.

    render-index-checks.py --sounds NEW_INDEX --baseline BASELINE_INDEX --after AFTER_INDEX

NEW_INDEX       the three new sounds' cards (renders/render-index.json)
BASELINE_INDEX  Everyday and Filters rendered before the layout change (renders/baseline/)
AFTER_INDEX     Everyday and Filters rendered after it (renders/after/)

Reads JSON (and, with --pngs, hashes the PNGs beside the indexes). No build, no app, no window.

C1  literal   no card's content is wider than the fixed card width (cardWidth <= fixedCardWidth).
C1  padding   no card's content leaves the padded area the baseline cards use: left edge no further
              left than the leftmost baseline content, right edge no further right than the
              rightmost baseline content. cardWidth is the width of the content's union, so it
              cannot see content that has moved sideways past the padding; this check can.
C1  column    every option control spans exactly the control column of Everyday's baseline rows,
              and every main-row slider track starts at that column.
C2  tracks    no tray slider track is narrower than 80 pt.
C2  baseline  Everyday's and Filters' frames are the same set as the baseline, with equal tray
              tracks (row and width) and card heights.
    frames    (extra) every Everyday and Filters index record equals the baseline's.
    pngs      (extra, --pngs) every Everyday and Filters PNG is byte-identical to the baseline's.

Coverage guard: the new index must hold the open cards the two faults appeared on, and at least
one tray track and one option control, so a renderer that drops them cannot pass.

Prints one PASS/FAIL line per check, with each offending frame, and exits 1 on any FAIL.
"""
import argparse
import hashlib
import json
import os
import sys

MIN_TRAY_TRACK = 80
REQUIRED_NEW_FRAMES = [
    f"{card}-open-{theme}.png"
    for card in ("big-space-hall", "big-space-church", "old-recording-vinyl", "old-recording-tape")
    for theme in ("light", "dark")
]


def load(path):
    with open(path) as handle:
        return json.load(handle)["frames"]


class Report:
    def __init__(self):
        self.failed = 0

    def check(self, name, scope, problems):
        if problems:
            self.failed += 1
            print(f"FAIL {name} ({len(problems)} problems, {scope})")
            for problem in problems:
                print(f"     {problem}")
        else:
            print(f"PASS {name} ({scope})")


def trays(frame):
    return [(t["row"], t["trackWidth"]) for t in frame.get("sliderTracks", []) if t["place"] == "tray"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sounds", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--pngs", action="store_true", help="also compare the PNGs beside BASELINE and AFTER")
    args = parser.parse_args()

    new, base, after = load(args.sounds), load(args.baseline), load(args.after)
    every = new + after
    report = Report()

    names = {f["file"] for f in new}
    report.check("coverage: the new index holds the open cards, tray tracks and option controls",
                 f"{len(new)} new-sound frames",
                 [f"missing {name}" for name in REQUIRED_NEW_FRAMES if name not in names]
                 + ([] if any(trays(f) for f in new) else ["no tray slider track"])
                 + ([] if any(f.get("segmentedControls") for f in new) else ["no option control"]))

    report.check("C1 literal: content no wider than the fixed card width",
                 f"{len(every)} frames",
                 [f"{f['file']}: content {f['cardWidth']} pt > card {f['fixedCardWidth']} pt"
                  for f in every if f["cardWidth"] > f["fixedCardWidth"]])

    left = min(f["contentMinX"] for f in base)
    right = max(f["contentMaxX"] for f in base)
    report.check(f"C1 padding: content within {left}-{right} pt, the baseline cards' content extent",
                 f"{len(every)} frames",
                 [f"{f['file']}: content {f['contentMinX']}-{f['contentMaxX']} pt"
                  for f in every if f["contentMinX"] < left or f["contentMaxX"] > right])

    everyday = [f for f in base if f["file"].startswith("everyday-")]
    columns = {(s["x"], s["maxX"]) for f in everyday for s in f.get("segmentedControls", [])}
    track_starts = {t["x"] for f in base for t in f.get("sliderTracks", []) if t["place"] == "main"}
    if len(columns) != 1 or len(track_starts) != 1:
        report.check("C1 column: the baseline has one control column",
                     "baseline", [f"option controls {sorted(columns)}, main tracks start at {sorted(track_starts)}"])
    else:
        (start, end), = columns
        controls = sum(len(f.get("segmentedControls", [])) for f in every)
        problems = [f"{f['file']}: option control {s['x']}-{s['maxX']} pt"
                    for f in every for s in f.get("segmentedControls", []) if (s["x"], s["maxX"]) != (start, end)]
        problems += [f"{f['file']}: main row {t['row']} track starts at {t['x']} pt"
                     for f in every for t in f.get("sliderTracks", []) if t["place"] == "main" and t["x"] != start]
        report.check(f"C1 column: option controls span {start}-{end} pt and main tracks start at {start} pt",
                     f"{controls} option controls", problems)

    tray_count = sum(len(trays(f)) for f in every)
    report.check(f"C2 tracks: no tray slider track narrower than {MIN_TRAY_TRACK} pt",
                 f"{tray_count} tray tracks",
                 [f"{f['file']}: {row} track {width} pt" for f in every for row, width in trays(f) if width < MIN_TRAY_TRACK])

    before = {f["file"]: f for f in base}
    later = {f["file"]: f for f in after}
    problems = [f"{name}: missing from the after index" for name in sorted(set(before) - set(later))]
    problems += [f"{name}: not in the baseline" for name in sorted(set(later) - set(before))]
    shared = sorted(set(before) & set(later))
    for name in shared:
        if trays(before[name]) != trays(later[name]):
            problems.append(f"{name}: tray tracks {trays(before[name])} -> {trays(later[name])}")
        if before[name]["cardHeight"] != later[name]["cardHeight"]:
            problems.append(f"{name}: card height {before[name]['cardHeight']} -> {later[name]['cardHeight']}")
    report.check("C2 baseline: Everyday and Filters tray tracks and card heights equal the baseline",
                 f"{len(before)} baseline frames", problems)

    def projected(frame, like):
        # The after index may carry fields the baseline renderer did not write; compare only the
        # baseline's own fields, track by track.
        out = {k: frame.get(k) for k in like if k != "sliderTracks"}
        out["sliderTracks"] = [{k: t.get(k) for k in b} for t, b in zip(frame.get("sliderTracks", []), like.get("sliderTracks", []))]
        out["trackCount"] = len(frame.get("sliderTracks", []))
        return out
    differing = []
    for name in shared:
        a, b = projected(later[name], before[name]), projected(before[name], before[name])
        if a != b:
            differing.append(f"{name}: " + ", ".join(sorted(k for k in b if a.get(k) != b.get(k))))
    report.check("frames: every Everyday and Filters index record equals the baseline on the baseline's fields",
                 f"{len(shared)} frames", differing)
    added = sorted({k for name in shared for t in later[name].get("sliderTracks", []) for k in t}
                   - {k for name in shared for t in before[name].get("sliderTracks", []) for k in t})
    if added:
        print(f"NOTE slider-track fields in the after index that the baseline lacks: {', '.join(added)}")

    if args.pngs:
        def digest(directory, name):
            path = os.path.join(directory, name)
            if not os.path.exists(path):
                return None
            with open(path, "rb") as handle:
                return hashlib.sha256(handle.read()).hexdigest()
        base_dir, after_dir = os.path.dirname(os.path.abspath(args.baseline)), os.path.dirname(os.path.abspath(args.after))
        report.check("pngs: every Everyday and Filters PNG is byte-identical to the baseline",
                     f"{len(shared)} PNG pairs",
                     [f"{name}: differs or missing" for name in shared
                      if digest(base_dir, name) is None or digest(base_dir, name) != digest(after_dir, name)])

    print(f"{'FAIL' if report.failed else 'PASS'} render-index checks: {report.failed} failed")
    sys.exit(1 if report.failed else 0)


if __name__ == "__main__":
    main()

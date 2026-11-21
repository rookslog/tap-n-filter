#!/usr/bin/env python3
"""Apply one mutant from mutants.json to the working tree.

    python3 Tests/Mutants/apply.py NAME     apply mutant NAME
    python3 Tests/Mutants/apply.py --check  check that every mutant's old text occurs exactly once

Exits non-zero unless the old text occurs exactly once in its file. Standard library only.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def load():
    with open(HERE / "mutants.json", encoding="utf-8") as handle:
        return json.load(handle)["mutants"]


def source(entry):
    return (ROOT / entry["file"]).read_text(encoding="utf-8")


def check(mutants):
    problems = []
    seen = set()
    for entry in mutants:
        name = entry["name"]
        if name in seen or name == "control":
            problems.append(f"{name}: duplicate or reserved name")
        seen.add(name)
        if not entry.get("red"):
            problems.append(f"{name}: no expected red case ids")
        count = source(entry).count(entry["old"])
        if count != 1:
            problems.append(f"{name}: old text occurs {count} times in {entry['file']}")
        if entry["old"] == entry["new"]:
            problems.append(f"{name}: new text equals old text")
    for line in problems:
        print(line)
    print(f"checked {len(mutants)} mutants, {len(problems)} problems")
    return 1 if problems else 0


def apply(mutants, name):
    entry = next((m for m in mutants if m["name"] == name), None)
    if entry is None:
        print(f"unknown mutant: {name}")
        return 2
    text = source(entry)
    count = text.count(entry["old"])
    if count != 1:
        print(f"{name}: old text occurs {count} times in {entry['file']}; nothing applied")
        return 1
    (ROOT / entry["file"]).write_text(text.replace(entry["old"], entry["new"], 1), encoding="utf-8")
    print(f"applied {name} to {entry['file']}")
    return 0


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    mutants = load()
    if argv[1] == "--check":
        return check(mutants)
    return apply(mutants, argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Run the problem-clearing cases against one mutant, or against the unchanged tree.

    python3 Tests/Mutants/run.py NAME      apply mutant NAME, build, run the cases, print the verdict
    python3 Tests/Mutants/run.py control   the same with no mutant
    python3 Tests/Mutants/run.py --list    print the job matrix as a JSON array

Prints exactly one line
    MUTANT name=... expected=[...] red=[...] verdict=killed|survived|no-compile|hang|control-clean|control-red
and appends it to the GitHub step summary. Exits 0 only for killed and control-clean.
A mutant that does not apply or does not compile is not a kill. Standard library only.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RUNNER = "ProblemClearMutantRun"
BUILD_TIMEOUT = 30 * 60
TEST_TIMEOUT = 15 * 60
FAIL_LINE = re.compile(r"UNIT-A FAIL (\S+)")


def load():
    with open(HERE / "mutants.json", encoding="utf-8") as handle:
        return json.load(handle)["mutants"]


def run(command, timeout):
    """Returns (exit code or None on timeout, combined output)."""
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        return None, output


def report(name, expected, red, verdict):
    line = f"MUTANT name={name} expected=[{','.join(expected)}] red=[{','.join(red)}] verdict={verdict}"
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    return 0 if verdict in ("killed", "control-clean") else 1


def main(argv):
    mutants = load()
    if argv[1:] == ["--list"]:
        print(json.dumps(["control"] + [entry["name"] for entry in mutants]))
        return 0
    if len(argv) != 2:
        print(__doc__)
        return 2
    name = argv[1]
    expected = []
    if name != "control":
        entry = next((m for m in mutants if m["name"] == name), None)
        if entry is None:
            print(f"::error::unknown mutant {name}")
            return report(name, [], [], "no-compile")
        expected = list(entry["red"])
        applied = subprocess.run([sys.executable, str(HERE / "apply.py"), name], cwd=ROOT)
        if applied.returncode != 0:
            print("::error::the mutant did not apply: its old text must occur exactly once")
            return report(name, expected, [], "no-compile")

    shutil.copyfile(HERE / "ProblemClearMutantRun.swift.template",
                    ROOT / "Tests" / "DirectDragAppChecks" / "ProblemClearMutantRun.swift")

    code, output = run(["swift", "build", "--build-tests", "-c", "debug"], BUILD_TIMEOUT)
    if code != 0:
        print(output[-30000:])
        if code is None:
            print("::error::the build did not finish in time")
        return report(name, expected, [], "no-compile")

    code, output = run(["swift", "test", "-c", "debug", "--skip-build", "--filter", RUNNER], TEST_TIMEOUT)
    print(output)
    red = list(dict.fromkeys(FAIL_LINE.findall(output)))
    if code is None:
        verdict = "hang"
    elif name == "control":
        clean = code == 0 and not red and "PASS Unit A" in output
        verdict = "control-clean" if clean else "control-red"
    else:
        verdict = "killed" if expected and set(expected) <= set(red) else "survived"
    return report(name, expected, red, verdict)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

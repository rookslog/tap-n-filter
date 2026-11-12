"""Run the same model contracts as XCTest without needing the XCTest framework."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--build-dir", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
build = (args.build_dir or root / ".build/sound-model-contracts").resolve()
build.mkdir(parents=True, exist_ok=True)
tests = root / "Tests/SoundModelTests"
sources = sorted((root / "Sources/SoundModel").glob("*.swift"))
sources += sorted(tests.glob("*Cases.swift"))
sources += [tests / "ContractSupport.swift", tests / "ContractMain.swift"]
output = build / "SoundModelContracts"
env = os.environ.copy()
env["CLANG_MODULE_CACHE_PATH"] = str(build / "module-cache")
command = [
    "swiftc", "-parse-as-library", "-O", "-swift-version", "6",
    "-module-cache-path", env["CLANG_MODULE_CACHE_PATH"],
    *[str(source) for source in sources], "-o", str(output),
]
print(json.dumps({"compile": command, "run": [str(output)]}), flush=True)
compile_result = subprocess.run(command, cwd=root, env=env)
print(f"compile_exit={compile_result.returncode}", flush=True)
if compile_result.returncode:
    raise SystemExit(compile_result.returncode)
result = subprocess.run([str(output)], cwd=root, env=env)
raise SystemExit(result.returncode)

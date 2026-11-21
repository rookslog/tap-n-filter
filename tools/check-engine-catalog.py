#!/usr/bin/env python3
"""Run catalog/model/mapper/store contracts without native App/device/audio tests.

Wrap this command in the project's storage guard. Compilers run serially, with
Swift limited to two jobs. All generated compiler output belongs to --scratch-path.
"""
import argparse
import os
import json
import tempfile
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scratch-path', type=Path, required=True)
    args = parser.parse_args()
    out = args.scratch_path.resolve()
    out.mkdir(parents=True, exist_ok=True)
    temporary = out / "temporary"
    temporary.mkdir(exist_ok=True)
    os.environ["TMPDIR"] = str(temporary) + "/"
    stores = out / "owned-store"
    stores.mkdir(exist_ok=True)
    run_root = Path(tempfile.mkdtemp(prefix="run-", dir=stores))
    print("OWNED_STORE_RUN " + str(run_root), flush=True)
    (out / "CHECK-RUN.json").write_text(json.dumps({"generatedStoreRoot": str(run_root), "status": "running"}, indent=2) + "\n")
    def run(command):
        subprocess.run(list(map(str, command)), cwd=ROOT, check=True)
    run([sys.executable, ROOT / 'tools/generate-effect-catalog.py', '--check'])
    run([sys.executable, ROOT / 'Tests/EffectCatalogChecks/test_generator.py'])
    common = ['swiftc', '-j2', '-parse-as-library', '-enable-testing', '-I', out,
              '-I', ROOT / 'Sources/PlaybackDSP/include', '-I', ROOT / 'Sources/FixedRender/include',
              '-I', ROOT / 'Tests/EngineCatalogCore/include', '-module-cache-path', out / 'swift-cache',
              '-L', out, '-Xlinker', '-rpath', '-Xlinker', out]
    for module in ['EffectCatalog', 'SoundModel', 'SessionStore', 'EverydayMenu']:
        dependencies = [] if module == 'EffectCatalog' else ['-lEffectCatalog'] if module == 'SoundModel' else ['-lSoundModel', '-lEffectCatalog']
        run(common + ['-emit-library', '-emit-module', '-module-name', module, '-o', out / ('lib' + module + '.dylib')] + dependencies + sorted((ROOT / 'Sources' / module).glob('*.swift')))
    for module, header in [('EngineCatalogCore', ROOT / 'Tests/EngineCatalogCore/include/EngineCatalogCore.h')]:
        folder = out / module
        folder.mkdir(exist_ok=True)
        (folder / 'module.modulemap').write_text('module ' + module + ' { header "' + str(header) + '" export * }\n')
        common += ['-I', folder]
    run(['clang++', '-std=c++20', '-fno-objc-arc', '-c', ROOT / 'Sources/FixedRender/FixedRender.mm', '-o', out / 'FixedRender.o'])
    run(['clang++', '-std=c++20', '-I', ROOT / 'Sources/FixedRender/include', '-c', ROOT / 'Sources/PlaybackDSP/PlaybackDSP.cpp', '-o', out / 'PlaybackDSP.o'])
    run(common + ['-swift-version', '6', '-emit-library', '-emit-module', '-module-name', 'PlaybackRenderBridge', '-lSoundModel', '-lEffectCatalog', out / 'FixedRender.o', out / 'PlaybackDSP.o', '-framework', 'AVFAudio', '-framework', 'AudioToolbox', '-framework', 'Foundation', '-lc++', '-o', out / 'libPlaybackRenderBridge.dylib'] + sorted((ROOT / 'Sources/PlaybackRenderBridge').glob('*.swift')))
    run(['clang++', '-std=c++20', '-c', ROOT / 'Tests/EngineCatalogCore/Checks.cpp', '-o', out / 'EngineCatalogCore.o'])
    link = ['-lSoundModel', '-lSessionStore', '-lEverydayMenu', '-lEffectCatalog', '-lPlaybackRenderBridge', '-lc++']
    suites = [
        ('EngineCatalogChecks', [ROOT / 'Tests/EngineCatalogChecks/Checks.swift', ROOT / 'Tests/EngineCatalogChecks/Main.swift'], [out / 'EngineCatalogCore.o']),
        ('SoundModelTests', [p for p in sorted((ROOT / 'Tests/SoundModelTests').glob('*.swift')) if p.name != 'SoundModelTests.swift'], []),
        ('CompatibilityWitnessChecks', [ROOT / 'Tests/CompatibilityWitnessChecks/Checks.swift', ROOT / 'Tests/CompatibilityWitnessChecks/Main.swift'], []),
        ('SessionStoreChecks', sorted((ROOT / 'Tests/SessionStoreChecks').glob('*.swift')), []),
        ('OptionControlChecks', [p for p in sorted((ROOT / 'Tests/OptionControlChecks').glob('*.swift')) if p.name != 'SwiftPMTests.swift'], []),
        ('MappingOwnerChecks', [p for p in sorted((ROOT / 'Tests/MappingOwnerChecks').glob('*.swift')) if p.name != 'SwiftPMTests.swift'], []),
        ('ChoiceOptionChecks', [p for p in sorted((ROOT / 'Tests/ChoiceOptionChecks').glob('*.swift')) if p.name not in ['SwiftPMTests.swift', 'SliderCoalescing.swift']], []),
    ]
    print('SCOPE ChoiceOptionChecks public owner/store driver only; App-dependent SliderCoalescing stays in default ChoiceOptionTests', flush=True)
    for name, source, entry in [
        ('DirectDragModelChecks', 'Tests/DirectDragModelChecks/Main.swift', 'DirectDragModelChecks'),
        ('ParameterModelChecks', 'Tests/ParameterChecks/ModelMain.swift', 'ParameterModelChecks'),
    ]:
        driver = out / (name + 'Driver.swift')
        driver.write_text('import Foundation\n@main struct Driver { static func main() async { do { try await ' + entry + '.run() } catch { print("FAIL \\(error)"); exit(1) } } }\n')
        suites.append((name, [ROOT / source, driver], []))
    for name, sources, objects in suites:
        run(common + sources + objects + link + ['-o', out / name])
        print('RUN ' + name, flush=True)
        argument = ROOT / 'Tests/CompatibilityWitnessChecks/Fixtures/canonical-native-v1-v4.json' if name == 'CompatibilityWitnessChecks' else run_root / name
        run([out / name, argument])
    run(['clang++', '-std=c++20', ROOT / 'Tests/ReverbSizeChecks/Main.cpp', '-o', out / 'reverb-size-check'])
    run([out / 'reverb-size-check'])
    (out / 'CHECK-RUN.json').write_text(json.dumps({'generatedStoreRoot': str(run_root), 'status': 'passed', 'suites': [name for name, _, _ in suites]}, indent=2) + '\n')
    print('PASS all catalog, historical, mapper, Core, metadata-fake and owned-store checks', flush=True)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""Build and run the Quick Menu sound checks without XCTest.

Compiles the model, store, menu and render-bridge modules from --root/Sources and
the check sources in this folder (except SwiftPMTests.swift) with swiftc, two jobs,
into --scratch-path. Wrap the command in the project's storage guard. No app, no
audio device, no window: the render group uses the engine's manual rendering mode.

  run-local.py --scratch-path DIR [--root REPO] [--sources a.swift ...] [-- group ...]
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--scratch-path', type=Path, required=True)
    parser.add_argument('--root', type=Path, default=HERE.parents[1])
    parser.add_argument('--sources', nargs='*', help='check sources to compile instead of every file here')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--tests-only', action='store_true', help='reuse modules already built in --scratch-path')
    parser.add_argument('groups', nargs='*')
    args = parser.parse_args()
    root, out = args.root.resolve(), args.scratch_path.resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / 'temporary').mkdir(exist_ok=True)
    os.environ['TMPDIR'] = str(out / 'temporary') + '/'

    def run(command):
        subprocess.run(list(map(str, command)), cwd=root, check=True)

    common = ['swiftc', '-j2', '-parse-as-library', '-enable-testing', '-I', out,
              '-I', root / 'Sources/PlaybackDSP/include', '-I', root / 'Sources/FixedRender/include',
              '-module-cache-path', out / 'swift-cache', '-L', out, '-Xlinker', '-rpath', '-Xlinker', out]
    modules = [] if args.tests_only else ['EffectCatalog', 'SoundModel', 'SessionStore', 'EverydayMenu']
    for module in modules:
        dependencies = [] if module == 'EffectCatalog' else ['-lEffectCatalog'] if module == 'SoundModel' else ['-lSoundModel', '-lEffectCatalog']
        run(common + ['-emit-library', '-emit-module', '-module-name', module, '-o', out / ('lib' + module + '.dylib')]
            + dependencies + sorted((root / 'Sources' / module).glob('*.swift')))
    if not args.tests_only:
        run(['clang++', '-std=c++20', '-fno-objc-arc', '-c', root / 'Sources/FixedRender/FixedRender.mm', '-o', out / 'FixedRender.o'])
        run(['clang++', '-std=c++20', '-I', root / 'Sources/FixedRender/include', '-c', root / 'Sources/PlaybackDSP/PlaybackDSP.cpp', '-o', out / 'PlaybackDSP.o'])
        run(common + ['-swift-version', '6', '-emit-library', '-emit-module', '-module-name', 'PlaybackRenderBridge',
                      '-lSoundModel', '-lEffectCatalog', out / 'FixedRender.o', out / 'PlaybackDSP.o',
                      '-framework', 'AVFAudio', '-framework', 'AudioToolbox', '-framework', 'Foundation', '-lc++',
                      '-o', out / 'libPlaybackRenderBridge.dylib'] + sorted((root / 'Sources/PlaybackRenderBridge').glob('*.swift')))
    sources = [Path(s).resolve() for s in args.sources] if args.sources else \
        [p for p in sorted(HERE.glob('*.swift')) if p.name != 'SwiftPMTests.swift']
    link = ['-lSoundModel', '-lSessionStore', '-lEverydayMenu', '-lEffectCatalog', '-lPlaybackRenderBridge', '-lc++',
            '-framework', 'AVFAudio', '-framework', 'AppKit', '-framework', 'SwiftUI']
    executable = out / 'quick-menu-sounds-checks'
    run(common + sources + link + ['-o', executable])
    if args.build_only:
        return
    print('RUN quick-menu-sounds-checks', flush=True)
    result = subprocess.run([str(executable), str(out / 'run')] + args.groups, cwd=root)
    sys.exit(result.returncode)


if __name__ == '__main__':
    main()

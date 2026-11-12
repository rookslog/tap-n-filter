#!/usr/bin/env python3
"""Tag admission, minimal ad-hoc app packaging and immutable prerelease assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import zipfile


class Refused(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def version(tag):
    match = re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.([1-9][0-9]*))?', tag)
    require(match is not None, 'expected vX.Y.Z or vX.Y.Z-beta.N')
    major, minor, patch, beta = match.groups()
    require(len(major) <= 4 and int(major) < 9999 and len(minor) <= 2 and len(patch) <= 2,
            'version must fit Apple bundle version components')
    require(beta is None or int(beta) <= 255, 'beta build number must be 1 through 255')
    base = '.'.join((major, minor, patch))
    return {'tag': tag, 'version': base, 'bundleVersion': str(int(major) + 1) + '.' + minor + '.' + patch + ('b' + beta if beta else ''), 'prerelease': beta is not None}


def command(argv, cwd=None):
    try:
        result = subprocess.run(list(map(str, argv)), cwd=cwd, capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired as error:
        def text(value):
            return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else value or ''
        raise Refused(json.dumps({'command': list(map(str, argv)), 'exit': None, 'timedOut': True, 'stdout': text(error.stdout), 'stderr': text(error.stderr)})) from error
    if result.returncode:
        raise Refused(json.dumps({'command': list(map(str, argv)), 'exit': result.returncode,
                                  'stdout': result.stdout, 'stderr': result.stderr}))
    return result.stdout.strip()


class API:
    def __init__(self, repo, token):
        require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) is not None, 'invalid repository')
        self.root = 'https://api.github.com/repos/' + repo
        self.token = token

    def request(self, method, suffix, value=None, upload=None):
        url = self.root + suffix
        headers = {'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
                   'X-GitHub-Api-Version': '2026-03-10'}
        data = None if value is None else json.dumps(value).encode()
        if value is not None:
            headers['Content-Type'] = 'application/json'
        if upload is not None:
            url = url.replace('https://api.github.com/', 'https://uploads.github.com/', 1)
            data = upload.read_bytes()
            headers['Content-Type'] = 'application/octet-stream'
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if method == 'GET' and error.code == 404:
                return None
            raise Refused('GitHub API request failed with HTTP ' + str(error.code)) from error


def admit(tag, commit, api, run=command):
    identity = version(tag)
    require(re.fullmatch(r'[0-9a-f]{40}', commit) is not None, 'exact commit required')
    require(run(['git', 'rev-parse', 'HEAD']) == commit, 'checkout differs from event commit')
    require(run(['git', 'rev-parse', 'refs/tags/' + tag + '^{commit}']) == commit, 'tag moved or differs from event')
    run(['git', 'merge-base', '--is-ancestor', commit, 'refs/remotes/origin/main'])
    main = api.request('GET', '/branches/main')
    require(main is not None and main.get('protected') is True, 'main must be protected')
    remote = api.request('GET', '/commits/' + tag)
    require(remote is not None and remote.get('sha') == commit, 'remote tag differs from event')
    comparison = api.request('GET', '/compare/' + commit + '...main')
    require(comparison is not None and comparison.get('status') in ('ahead', 'identical'), 'tag commit is not reachable from current main')
    return dict(identity, commit=commit)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular_files(folder):
    require(folder.is_dir() and not folder.is_symlink(), 'resource bundle missing or aliased')
    files = {}
    for path in sorted(folder.rglob('*')):
        require(not path.is_symlink(), 'resource symlink refused')
        if path.is_file():
            require(path.stat().st_nlink == 1, 'resource hardlink refused')
            files[str(path.relative_to(folder))] = digest(path)
        else:
            require(path.is_dir(), 'unsupported resource entry')
    require(files, 'empty resource bundle')
    return files


def launcher(tag):
    version(tag)
    return r'''#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")" && pwd)"
if ! owners="$(/usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('AppKit');
function run() {
    var apps = $.NSWorkspace.sharedWorkspace.runningApplications;
    if (!apps) throw new Error('Registered TNF ownership unavailable');
    var total = Number(apps.count);
    if (!Number.isInteger(total) || total < 0) throw new Error('Application enumeration unavailable');
    var count = 0;
    for (var i = 0; i < total; i++) {
        var app = apps.objectAtIndex(i);
        var id = ObjC.unwrap(app.bundleIdentifier);
        var executable = ObjC.unwrap(app.executableURL.lastPathComponent);
        var bundle = ObjC.unwrap(app.bundleURL.lastPathComponent);
        if (!id && !executable && !bundle) throw new Error('Application identity unavailable');
        if ((id && /^com\.loganrooks\.tap-n-filter(?:[.-]|$)/.test(id)) ||
            (executable && /^(tap-n-filter|TNF)$/i.test(executable)) ||
            (bundle && /^(TNF(?:[- ].*)?|tap-n-filter(?:[- ].*)?)\.app$/i.test(bundle))) count++;
    }
    return String(count);
}
JXA
)"; then
    printf '%s\n' 'TNF ownership could not be checked; nothing launched.' >&2
    exit 1
fi
if [[ "$owners" != 0 ]]; then
    printf '%s\n' 'TNF is running or ownership is unknown. Nothing was changed or launched.' >&2
    exit 1
fi
umask 077
session_dir="$HOME/Library/Application Support/tap-n-filter/versions/''' + tag + '''"
mkdir -p -m 700 -- "$session_dir"
exec /usr/bin/open -a "$base/tap-n-filter.app" --args --library-session-file "$session_dir/library-v5.json"
'''


def package(product_dir, info_source, destination, identity, runner, run=command):
    require(runner in ('macos-15', 'macos-26'), 'unsupported release runner')
    require(not destination.exists(), 'package destination already exists; never overwrite')
    binary = product_dir / 'tap-n-filter'
    require(binary.is_file() and not binary.is_symlink(), 'App executable missing or aliased')
    require(binary.stat().st_mode & 0o111, 'App executable mode missing')
    require(not any(marker in binary.read_bytes() for marker in (b'/Users/', b'/home/runner/')), 'absolute user/runner path embedded in executable')
    resources = product_dir / 'tap-n-filter_tap-n-filter.bundle'
    inventory = regular_files(resources)
    require(any(name.endswith('/neck1.pdf') or name == 'neck1.pdf' for name in inventory), 'neck1 resource missing')
    info = plistlib.loads(info_source.read_bytes())
    require(info.get('CFBundleExecutable') == 'tap-n-filter' and info.get('CFBundleIdentifier') == 'com.loganrooks.tap-n-filter' and info.get('LSUIElement') is True, 'App identity differs')
    require('TNFLibrarySessionFile' not in info and 'TNFSessionFile' not in info and 'TNFTrialSessionFile' not in info, 'private packaged data path refused')
    arch = run(['/usr/bin/lipo', '-archs', binary])
    require(arch in ('arm64', 'x86_64'), 'expected single native runner architecture')
    destination.mkdir(parents=True)
    app = destination / 'tap-n-filter.app'
    macos = app / 'Contents/MacOS'
    macos.mkdir(parents=True)
    shutil.copy2(binary, macos / binary.name)
    target = app / 'Contents/Resources' / resources.name
    shutil.copytree(resources, target)
    require(regular_files(target) == inventory, 'nested SwiftPM resource copy differs')
    info.update(CFBundleShortVersionString=identity['version'], CFBundleVersion=identity['bundleVersion'])
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', app])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    require(run(['/usr/bin/lipo', '-archs', macos / binary.name]) == arch, 'packaged architecture differs')
    signed = regular_files(target)
    require(all(signed.get(name) == value for name, value in inventory.items()), 'signing changed compiled resource bytes')
    require(set(signed) - set(inventory) <= {'_CodeSignature/CodeResources', 'Contents/_CodeSignature/CodeResources'}, 'unexpected signed resources')
    executable = destination / 'Launch tap-n-filter.command'
    executable.write_text(launcher(identity['tag']))
    executable.chmod(0o755)
    return app, arch, inventory


def archive(folder, output):
    require(not output.exists(), 'archive already exists; never overwrite')
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(folder.rglob('*')):
            require(not path.is_symlink(), 'package symlink refused')
            if path.is_file():
                info = zipfile.ZipInfo(str(path.relative_to(folder)), (2020, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (path.stat().st_mode & 0xffff) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                bundle.writestr(info, path.read_bytes())


def build(identity, runner, output):
    require(not output.exists(), 'release output exists; never overwrite')
    scratch = Path('.build-release')
    command(['swift', 'test', '--build-system', 'native', '--scratch-path', scratch, '-c', 'release', '-j', '2', '-Xswiftc', '-j2'])
    mapping = str(Path.cwd()) + '=.'
    command(['swift', 'build', '--build-system', 'native', '--product', 'tap-n-filter', '--scratch-path', scratch, '-c', 'release', '-j', '2', '-Xswiftc', '-j2', '-Xswiftc', '-file-prefix-map', '-Xswiftc', mapping, '-Xswiftc', '-gnone', '-Xcc', '-ffile-prefix-map=' + mapping])
    product = Path(command(['swift', 'build', '--build-system', 'native', '--scratch-path', scratch, '-c', 'release', '--show-bin-path']))
    command(['/usr/bin/strip', '-S', product / 'tap-n-filter'])
    output.mkdir()
    staging = output / 'staging'
    app, arch, resources = package(product, Path('Sources/tap-n-filter/Resources/Info.plist'), staging, identity, runner)
    name = 'tap-n-filter-' + identity['tag'] + '-' + runner + '-' + arch
    zip_path = output / (name + '.zip')
    archive(staging, zip_path)
    extracted = output / 'archive-check'
    command(['/usr/bin/ditto', '-x', '-k', zip_path, extracted])
    unpacked = extracted / 'tap-n-filter.app'
    command(['/usr/bin/codesign', '--verify', '--deep', '--strict', unpacked])
    require(command(['/usr/bin/lipo', '-archs', unpacked / 'Contents/MacOS/tap-n-filter']) == arch, 'archived architecture differs')
    require(regular_files(unpacked / 'Contents/Resources/tap-n-filter_tap-n-filter.bundle') == regular_files(app / 'Contents/Resources/tap-n-filter_tap-n-filter.bundle'), 'archived resources differ')
    shutil.rmtree(extracted)
    toolchain = {'swift': command(['swift', '--version']), 'xcode': command(['xcodebuild', '-version'])}
    provenance = dict(identity, runner=runner, architecture=arch, toolchain=toolchain, signing='ad-hoc; not Developer ID signed or notarized',
                      asset=zip_path.name, sha256=digest(zip_path), resources=resources, tests='swift test release; native/audio/device/window tests excluded by default',
                      launch='Use adjacent launcher. Raw App Finder launch requires separate source follow-up.')
    (output / (name + '.json')).write_text(json.dumps(provenance, sort_keys=True, indent=2) + '\n')
    shutil.rmtree(staging)


def asset_plan(folder, tag, commit):
    version(tag)
    files = sorted(folder.iterdir())
    require(len(files) == 4 and all(p.is_file() and not p.is_symlink() and p.suffix in ('.json', '.zip') for p in files), 'expected exactly two zip/provenance pairs')
    manifests = [json.loads(p.read_text()) for p in files if p.suffix == '.json']
    require(len(manifests) == 2 and {p.get('runner') for p in manifests} == {'macos-15', 'macos-26'}, 'both runner packages required')
    for row in manifests:
        require(row.get('tag') == tag and row.get('commit') == commit, 'artifact commit/tag differs')
        name = 'tap-n-filter-' + tag + '-' + row['runner'] + '-' + row['architecture']
        require(row['architecture'] in ('arm64', 'x86_64') and row['asset'] == name + '.zip', 'artifact identity differs')
        require((folder / (name + '.json')).is_file() and digest(folder / row['asset']) == row['sha256'], 'artifact digest differs')
    return {p.name: {'path': p, 'sha256': digest(p), 'size': p.stat().st_size} for p in files}


def publish(api, tag, commit, assets):
    require(version(tag)['prerelease'], 'stable publishing requires separate deliberate owner action')
    body = 'Source commit `' + commit + '`.\n\nAd-hoc signed. Not Developer ID signed or notarized.\n\nSHA256\n' + '\n'.join(name + '  ' + row['sha256'] for name, row in sorted(assets.items()))
    release = api.request('GET', '/releases/tags/' + tag)
    if release is None:
        release = api.request('POST', '/releases', {'tag_name': tag, 'target_commitish': commit, 'name': tag, 'body': body, 'draft': True, 'prerelease': True, 'make_latest': 'false'})
    require(release['tag_name'] == tag and release['prerelease'] is True and release['body'] == body, 'existing release identity differs; no replacement')
    release_id = str(release['id'])
    existing = api.request('GET', '/releases/' + release_id + '/assets?per_page=100')
    require(len(existing) < 100, 'unexpected release asset count')
    remote = {item['name']: item for item in existing}
    require(len(remote) == len(existing) and set(remote) <= set(assets), 'unexpected existing assets; no replacement')
    for name, row in assets.items():
        if name in remote:
            require(remote[name].get('digest') == 'sha256:' + row['sha256'] and remote[name].get('size') == row['size'] and remote[name].get('state') == 'uploaded', 'existing asset bytes differ or incomplete; no replacement')
        else:
            require(release['draft'] is True, 'published release missing asset; no mutation')
            item = api.request('POST', '/releases/' + release_id + '/assets?name=' + urllib.parse.quote(name), upload=row['path'])
            require(item.get('digest') == 'sha256:' + row['sha256'] and item.get('size') == row['size'] and item.get('state') == 'uploaded', 'uploaded asset digest differs')
    if release['draft']:
        api.request('PATCH', '/releases/' + release_id, {'draft': False, 'make_latest': 'false'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('admit', 'build', 'publish'))
    parser.add_argument('--runner', choices=('macos-15', 'macos-26'))
    parser.add_argument('--output', type=Path, default=Path('release-assets'))
    args = parser.parse_args()
    tag, commit = os.environ['RELEASE_TAG'], os.environ['RELEASE_COMMIT']
    if args.action == 'build':
        identity = dict(version(tag), commit=commit)
        require(command(['git', 'rev-parse', 'HEAD']) == commit, 'build checkout differs')
        build(identity, args.runner, args.output)
        return
    api = API(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN'])
    identity = admit(tag, commit, api)
    if args.action == 'admit':
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for name in ('tag', 'commit', 'prerelease'):
                output.write(name + '=' + str(identity[name]).lower() + '\n')
    else:
        publish(api, tag, commit, asset_plan(args.output, tag, commit))


if __name__ == '__main__':
    try:
        main()
    except (Refused, OSError, KeyError, subprocess.TimeoutExpired) as error:
        raise SystemExit('Release refused: ' + str(error))

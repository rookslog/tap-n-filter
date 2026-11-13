#!/usr/bin/env python3
"""Tag admission, minimal ad-hoc app packaging in a DMG and immutable prerelease assets."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


class Refused(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise Refused(message)


def version(tag):
    match = re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta)\.([1-9][0-9]*))?', tag)
    require(match is not None, 'expected vX.Y.Z, vX.Y.Z-alpha.N or vX.Y.Z-beta.N')
    major, minor, patch, stage, build = match.groups()
    require(len(major) <= 4 and int(major) < 9999 and len(minor) <= 2 and len(patch) <= 2,
            'version must fit Apple bundle version components')
    if build is not None:
        require(int(build) <= 255, stage + ' build number must be 1 through 255')
    base = '.'.join((major, minor, patch))
    return {'tag': tag, 'version': base, 'bundleVersion': str(int(major) + 1) + '.' + minor + '.' + patch + (stage[0] + build if build else ''), 'prerelease': build is not None}


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
    require(info.get('CFBundleIconFile') == 'AppIcon', 'App icon declaration missing')
    icon = info_source.parent / 'AppIcon.icns'
    require(icon.is_file() and not icon.is_symlink() and icon.stat().st_size > 0, 'App icon missing or aliased')
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
    shutil.copy2(icon, app / 'Contents/Resources/AppIcon.icns')
    run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', app])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
    require(run(['/usr/bin/lipo', '-archs', macos / binary.name]) == arch, 'packaged architecture differs')
    signed = regular_files(target)
    require(all(signed.get(name) == value for name, value in inventory.items()), 'signing changed compiled resource bytes')
    require(set(signed) - set(inventory) <= {'_CodeSignature/CodeResources', 'Contents/_CodeSignature/CodeResources'}, 'unexpected signed resources')
    require((app / 'Contents/Resources/AppIcon.icns').read_bytes() == icon.read_bytes(), 'signing changed icon bytes')
    return app, arch, inventory


def volume_name(identity):
    return 'tap-n-filter ' + identity['version'] + (identity['tag'].split(identity['version'], 1)[1] if identity['prerelease'] else '')


def make_dmg(app, identity, output, run=command):
    """Compressed image holding the app and an Applications link, and nothing else."""
    require(not output.exists(), 'disk image already exists; never overwrite')
    folder = Path(tempfile.mkdtemp(prefix='tnf-dmg-', dir='/private/tmp'))
    try:
        shutil.copytree(app, folder / app.name, symlinks=True)
        (folder / 'Applications').symlink_to('/Applications')
        run(['/usr/bin/hdiutil', 'create', '-quiet', '-srcfolder', folder, '-volname', volume_name(identity),
             '-fs', 'HFS+', '-format', 'UDZO', '-ov', output])
    finally:
        shutil.rmtree(folder, ignore_errors=True)


HIDDEN_VOLUME_METADATA = {'.fseventsd'}


def app_inventory(app):
    """Every entry of the app, dot-files and signature included: path -> sha256, link target or 'dir'."""
    require(app.is_dir() and not app.is_symlink(), 'app missing or aliased')
    rows = {}
    for folder, dirnames, filenames in os.walk(app):
        for name in dirnames + filenames:
            path = Path(folder) / name
            key = str(path.relative_to(app))
            if path.is_symlink():
                rows[key] = 'link:' + os.readlink(path)
            elif path.is_dir():
                rows[key] = 'dir'
            else:
                rows[key] = digest(path)
    return rows


def detach_image(mountpoint, run):
    """Bounded recovery: one plain detach, then forced retries. True only when a detach succeeded."""
    for force in (False, True, True):
        try:
            run(['/usr/bin/hdiutil', 'detach'] + (['-force'] if force else []) + [mountpoint])
            return True
        except Refused:
            time.sleep(0.2)
    return False


def verify_dmg(image, app, arch, run=command):
    """Attach read-only and hidden at a fresh mountpoint; always try to detach; any mismatch refuses."""
    mountpoint = Path(tempfile.mkdtemp(prefix='tnf-mount-', dir='/private/tmp'))
    attempted = False
    attached = False
    problem = None
    try:
        attempted = True
        run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noverify', '-noautoopen', '-mountpoint', mountpoint, image])
        attached = True
        names = set(path.name for path in mountpoint.iterdir()) - HIDDEN_VOLUME_METADATA
        require(names == {'Applications', 'tap-n-filter.app'}, 'disk image must hold exactly the app and Applications')
        link = mountpoint / 'Applications'
        require(link.is_symlink() and os.readlink(link) == '/Applications', 'Applications link target differs')
        mounted = mountpoint / 'tap-n-filter.app'
        require(mounted.is_dir() and not mounted.is_symlink(), 'app missing or aliased in disk image')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', mounted])
        require(run(['/usr/bin/lipo', '-archs', mounted / 'Contents/MacOS/tap-n-filter']) == arch, 'image architecture differs')
        require(app_inventory(mounted) == app_inventory(app), 'image app differs from the staged app')
    except BaseException as error:
        problem = error
    detached = detach_image(mountpoint, run) if attempted else True
    if detached:
        shutil.rmtree(mountpoint, ignore_errors=True)
    else:
        try:
            mountpoint.rmdir()
        except OSError:
            pass
        if isinstance(problem, KeyboardInterrupt):
            raise problem
        if attached or problem is None:
            raise Refused('disk image could not be detached; mountpoint kept' + (': ' + str(problem) if problem else '')) from problem
    if problem is not None:
        raise problem


def build(identity, runner, output):
    require(not output.exists(), 'release output exists; never overwrite')
    origin = Path.cwd()
    output = output.absolute()
    root = Path(tempfile.mkdtemp(prefix='tnf-release-', dir='/private/tmp'))
    require(root.resolve() == root and not root.is_symlink() and root.stat().st_uid == os.getuid() and root.stat().st_mode & 0o777 == 0o700, 'private owned public build root required')
    work = root / 'source'
    try:
        command(['git', 'worktree', 'add', '--detach', work, identity['commit']], cwd=origin)
        require(command(['git', 'rev-parse', 'HEAD'], cwd=work) == identity['commit'], 'detached release checkout differs')
        require(command(['git', 'rev-parse', 'refs/tags/' + identity['tag'] + '^{commit}'], cwd=work) == identity['commit'], 'detached release tag differs')
        build_at(work, root / 'build', identity, runner, output)
    finally:
        registered = command(['git', 'worktree', 'list', '--porcelain'], cwd=origin)
        if 'worktree ' + str(work) in registered.splitlines():
            command(['git', 'worktree', 'remove', '--force', work], cwd=origin)
        require(not work.exists(), 'owned build checkout cleanup incomplete; root retained')
        shutil.rmtree(root)


def build_at(work, scratch, identity, runner, output):
    command(['swift', 'test', '--build-system', 'native', '--scratch-path', scratch, '-c', 'release', '-j', '2', '-Xswiftc', '-j2'], cwd=work)
    mapping = str(work) + '=.'
    command(['swift', 'build', '--build-system', 'native', '--product', 'tap-n-filter', '--scratch-path', scratch, '-c', 'release', '-j', '2', '-Xswiftc', '-j2', '-Xswiftc', '-file-prefix-map', '-Xswiftc', mapping, '-Xswiftc', '-gnone', '-Xcc', '-ffile-prefix-map=' + mapping], cwd=work)
    product = Path(command(['swift', 'build', '--build-system', 'native', '--scratch-path', scratch, '-c', 'release', '--show-bin-path'], cwd=work))
    command(['/usr/bin/strip', '-S', product / 'tap-n-filter'])
    output.mkdir()
    staging = output / 'staging'
    app, arch, resources = package(product, work / 'Sources/tap-n-filter/Resources/Info.plist', staging, identity, runner)
    name = 'tap-n-filter-' + identity['tag'] + '-' + runner + '-' + arch
    image = output / (name + '.dmg')
    make_dmg(app, identity, image)
    verify_dmg(image, app, arch)
    toolchain = {'swift': command(['swift', '--version']), 'xcode': command(['xcodebuild', '-version'])}
    provenance = dict(identity, runner=runner, architecture=arch, toolchain=toolchain, signing='ad-hoc; not Developer ID signed or notarized',
                      asset=image.name, sha256=digest(image), resources=resources, tests='swift test release; native/audio/device/window tests excluded by default',
                      launch='Open the DMG and drag tap-n-filter to Applications')
    (output / (name + '.json')).write_text(json.dumps(provenance, sort_keys=True, indent=2) + '\n')
    shutil.rmtree(staging)


def asset_plan(folder, tag, commit):
    version(tag)
    files = sorted(folder.iterdir())
    require(len(files) == 4 and all(p.is_file() and not p.is_symlink() and p.suffix in ('.json', '.dmg') for p in files), 'expected exactly two dmg/provenance pairs')
    manifests = [json.loads(p.read_text()) for p in files if p.suffix == '.json']
    require(len(manifests) == 2 and {p.get('runner') for p in manifests} == {'macos-15', 'macos-26'}, 'both runner packages required')
    for row in manifests:
        require(row.get('tag') == tag and row.get('commit') == commit, 'artifact commit/tag differs')
        name = 'tap-n-filter-' + tag + '-' + row['runner'] + '-' + row['architecture']
        require(row['architecture'] in ('arm64', 'x86_64') and row['asset'] == name + '.dmg', 'artifact identity differs')
        require((folder / (name + '.json')).is_file() and digest(folder / row['asset']) == row['sha256'], 'artifact digest differs')
    return {p.name: {'path': p, 'sha256': digest(p), 'size': p.stat().st_size} for p in files}


def release_for_tag(api, tag):
    published = api.request('GET', '/releases/tags/' + tag)
    if published is not None:
        require(type(published) is dict and published.get('tag_name') == tag and published.get('draft') is False, 'published tag lookup differs')
    seen = set()
    matches = []
    for page in range(1, 101):
        rows = api.request('GET', '/releases?per_page=100&page=' + str(page))
        require(type(rows) is list and len(rows) <= 100, 'authenticated release listing unavailable or malformed')
        for row in rows:
            require(type(row) is dict and type(row.get('id')) is int and row['id'] > 0 and type(row.get('draft')) is bool and type(row.get('tag_name')) is str, 'release listing identity malformed')
            require(row['id'] not in seen, 'release pagination repeated an identity; retry from unchanged artifacts')
            seen.add(row['id'])
            if row['tag_name'] == tag:
                matches.append(row)
        if len(rows) < 100:
            break
    else:
        raise Refused('release pagination incomplete; no draft created')
    require(len(matches) <= 1, 'ambiguous releases for tag; no draft created')
    if published is not None:
        require(len(matches) == 1 and matches[0]['id'] == published['id'], 'published/listed release identity differs')
        require(all(matches[0].get(key) == published.get(key) for key in ('tag_name', 'draft', 'body', 'target_commitish', 'prerelease')), 'published/listed release metadata differs')
    return matches[0] if matches else None


def publish(api, tag, commit, assets):
    require(version(tag)['prerelease'], 'stable publishing requires separate deliberate owner action')
    body = 'Source commit `' + commit + '`.\n\nAd-hoc signed. Not Developer ID signed or notarized.\n\nSHA256\n' + '\n'.join(name + '  ' + row['sha256'] for name, row in sorted(assets.items()))
    release = release_for_tag(api, tag)
    if release is None:
        release = api.request('POST', '/releases', {'tag_name': tag, 'target_commitish': commit, 'name': tag, 'body': body, 'draft': True, 'prerelease': True, 'make_latest': 'false'})
    require(release['tag_name'] == tag and release['prerelease'] is True and release['body'] == body and release['target_commitish'] == commit, 'existing release identity differs; no replacement')
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

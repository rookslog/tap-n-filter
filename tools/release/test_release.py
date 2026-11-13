"""Bounded synthetic fixtures. No Swift build, signing, App or network execution."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release as r

COMMIT = 'a' * 40
TAG = 'v0.2.0-beta.1'


class SyntheticAPI:
    def __init__(self):
        self.calls = []
        self.release = None
        self.releases = []
        self.release_pages = None
        self.assets = []
        self.main_protected = True
        self.remote_commit = COMMIT
        self.status = 'ahead'

    def request(self, method, path, value=None, upload=None):
        self.calls.append((method, path, value, upload))
        if path == '/branches/main':
            return {'protected': self.main_protected}
        if path.startswith('/commits/'):
            return {'sha': self.remote_commit}
        if path.startswith('/compare/'):
            return {'status': self.status}
        if path.startswith('/releases/tags/'):
            return self.release if self.release and not self.release['draft'] else None
        if method == 'GET' and path.startswith('/releases?per_page=100&page='):
            page = int(path.rsplit('=', 1)[1])
            return self.release_pages.get(page, []) if self.release_pages is not None else self.releases[(page-1)*100:page*100]
        if method == 'POST' and path == '/releases':
            self.release = dict(value, id=len(self.releases)+1)
            self.releases.append(self.release)
            return self.release
        if method == 'GET' and '/assets?' in path:
            return self.assets
        if method == 'POST' and '/assets?' in path:
            row = {'name': upload.name, 'digest': 'sha256:' + r.digest(upload), 'size': upload.stat().st_size, 'state': 'uploaded'}
            self.assets.append(row)
            return row
        if method == 'PATCH':
            self.release.update(value)
            return self.release
        raise AssertionError((method, path))


class AdmissionTests(unittest.TestCase):
    def test_valid_beta_and_stable_versions(self):
        self.assertEqual(r.version(TAG), {'tag': TAG, 'version': '0.2.0', 'bundleVersion': '1.2.0b1', 'prerelease': True})
        self.assertFalse(r.version('v1.2.3')['prerelease'])

    def test_valid_alpha_versions_are_prereleases(self):
        self.assertEqual(r.version('v0.1.0-alpha.1'), {'tag': 'v0.1.0-alpha.1', 'version': '0.1.0', 'bundleVersion': '1.1.0a1', 'prerelease': True})
        self.assertEqual(r.version('v0.1.0-alpha.255')['bundleVersion'], '1.1.0a255')

    def test_malformed_or_unsafe_versions_refuse(self):
        for tag in ['1.2.3', 'v01.2.3', 'v1.2', 'v1.2.3-rc.1', 'v1.2.3-beta.0', 'v1.2.3-beta.256', 'v1.2.3;echo injected', 'v1.2.3\n', 'v9999.1.1',
                    'v1.2.3-alpha', 'v1.2.3-alpha.0', 'v1.2.3-alpha.01', 'v1.2.3-alpha.256', 'v1.2.3-alpha1', 'v1.2.3-Alpha.1', 'v1.2.3-alpha.1-beta.1', 'v1.2.3-alpha.1\n']:
            with self.subTest(tag=tag), self.assertRaises(r.Refused):
                r.version(tag)

    def test_reachable_exact_tag_on_protected_main_accepts(self):
        api = SyntheticAPI()
        calls = []
        def run(command):
            calls.append(command)
            return COMMIT if command[1] == 'rev-parse' else ''
        self.assertEqual(r.admit(TAG, COMMIT, api, run)['commit'], COMMIT)
        self.assertIn(['git', 'merge-base', '--is-ancestor', COMMIT, 'refs/remotes/origin/main'], calls)

    def test_wrong_checkout_tag_branch_only_and_unprotected_main_refuse(self):
        for wrong in ('checkout', 'tag', 'ancestry', 'remote', 'main', 'comparison'):
            api = SyntheticAPI()
            api.main_protected = wrong != 'main'
            api.remote_commit = 'b' * 40 if wrong == 'remote' else COMMIT
            api.status = 'diverged' if wrong == 'comparison' else 'ahead'
            def run(command):
                if wrong == 'ancestry' and command[1] == 'merge-base':
                    raise r.Refused('SYNTHETIC branch-only commit')
                if command[1] == 'rev-parse':
                    return 'b' * 40 if (wrong == 'checkout' and command[2] == 'HEAD') or (wrong == 'tag' and command[2] != 'HEAD') else COMMIT
                return ''
            with self.subTest(wrong=wrong), self.assertRaises(r.Refused):
                r.admit(TAG, COMMIT, api, run)

    def test_command_failure_keeps_diagnostics(self):
        outcome = subprocess.CompletedProcess(['SYNTHETIC'], 7, 'out', 'err')
        with patch('release.subprocess.run', return_value=outcome) as run:
            with self.assertRaises(r.Refused) as error:
                r.command(['SYNTHETIC'])
        self.assertEqual(json.loads(str(error.exception)), {'command': ['SYNTHETIC'], 'exit': 7, 'stdout': 'out', 'stderr': 'err'})
        run.assert_called_once()

    def test_command_timeout_retains_partial_outputs(self):
        with patch('release.subprocess.run', side_effect=subprocess.TimeoutExpired(['SYNTHETIC'], 1, output=b'partial out', stderr=b'partial err')) as run:
            with self.assertRaises(r.Refused) as error:
                r.command(['SYNTHETIC'])
        self.assertEqual(json.loads(str(error.exception)), {'command': ['SYNTHETIC'], 'exit': None, 'timedOut': True, 'stdout': 'partial out', 'stderr': 'partial err'})
        run.assert_called_once()


ICON = b'SYNTHETIC icns bytes, not a real icon'
LAUNCH = 'Open the DMG and drag tap-n-filter to Applications'
PROVENANCE_FIELDS = {'tag', 'version', 'bundleVersion', 'prerelease', 'commit', 'runner', 'architecture', 'toolchain',
                     'signing', 'asset', 'sha256', 'resources', 'tests', 'launch'}


def make_product(product):
    resource = product / 'tap-n-filter_tap-n-filter.bundle/Resources'
    resource.mkdir(parents=True)
    (resource / 'neck1.pdf').write_bytes(b'SYNTHETIC glyph, not actual native evidence')
    (resource / 'nested').mkdir()
    (resource / 'nested/file.bin').write_bytes(b'SYNTHETIC nested resource')
    (product / 'tap-n-filter').write_bytes(b'SYNTHETIC not a Mach-O executable')
    (product / 'tap-n-filter').chmod(0o755)
    (product / 'Tests.bundle').mkdir()
    (product / 'Tests.bundle/private.txt').write_text('SYNTHETIC must not be copied')
    return resource


def make_info(info):
    """Source Info.plist with the S3 icon beside it, as in Sources/tap-n-filter/Resources."""
    info.parent.mkdir(parents=True, exist_ok=True)
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.loganrooks.tap-n-filter', 'CFBundleExecutable': 'tap-n-filter',
                                     'LSUIElement': True, 'CFBundleIconFile': 'AppIcon'}))
    (info.parent / 'AppIcon.icns').write_bytes(ICON)


def flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv else None


class SyntheticInterrupt(KeyboardInterrupt):
    """A Ctrl-C stand-in: a BaseException, not an Exception, raised from inside a synthetic native call."""


class SyntheticNative:
    """Stands in for subprocess.run under release.command. hdiutil create snapshots -srcfolder; attach
    copies that snapshot (symlinks kept) to -mountpoint; detach empties it. Nothing native runs.
    `damage` alters the mounted copy only, to model an image whose contents differ from staging."""

    def __init__(self, root, product, damage=None, fail=None):
        self.root = root
        self.product = product
        self.damage = damage
        self.fail = fail
        self.calls = []
        self.images = {}
        self.created = []
        self.mounts = []
        self.mounted = None
        self.detaches = []
        self.store = Path(tempfile.mkdtemp(prefix='synthetic-image-store-', dir=root))

    def result(self, argv, stdout='', code=0):
        return subprocess.CompletedProcess(argv, code, stdout, 'SYNTHETIC failure' if code else '')

    def under_mount(self, path):
        return self.mounted is not None and (path == self.mounted or path.startswith(self.mounted + '/'))

    def __call__(self, argv, cwd=None, **kwargs):
        argv = list(map(str, argv))
        self.calls.append(argv)
        tool = argv[0]
        if tool == 'swift' and '--show-bin-path' in argv:
            return self.result(argv, str(self.product) + '\n')
        if tool == 'swift' and argv[1:2] == ['--version']:
            return self.result(argv, 'SYNTHETIC swift version')
        if tool == 'swift':
            return self.result(argv)
        if tool == 'xcodebuild':
            return self.result(argv, 'SYNTHETIC Xcode version')
        if tool == '/usr/bin/strip':
            return self.result(argv)
        if tool == '/usr/bin/lipo':
            if self.under_mount(argv[-1]) and self.damage == 'architecture':
                return self.result(argv, 'x86_64\n')
            return self.result(argv, 'arm64\n')
        if tool == '/usr/bin/codesign':
            if '--verify' in argv and self.under_mount(argv[-1]) and self.damage == 'signature':
                return self.result(argv, code=1)
            if '--verify' in argv and self.under_mount(argv[-1]) and self.fail == 'interrupt-verify':
                raise SyntheticInterrupt()
            return self.result(argv)
        if tool == '/usr/bin/ditto':
            if '-k' in argv or '-c' in argv or '-x' in argv:
                raise AssertionError('zip archive step remains: ' + str(argv))
            shutil.copytree(argv[-2], argv[-1], symlinks=True)
            return self.result(argv)
        if tool == '/usr/bin/hdiutil':
            return self.hdiutil(argv)
        raise AssertionError('Unexpected native boundary ' + str(argv))

    def hdiutil(self, argv):
        verb = argv[1]
        if verb == 'create':
            source = Path(flag(argv, '-srcfolder'))
            image = Path(argv[-1])
            snapshot = self.store / str(len(self.images))
            shutil.copytree(source, snapshot, symlinks=True)
            self.created.append({'argv': argv, 'entries': sorted(os.listdir(source)),
                                 'link': os.readlink(source / 'Applications') if (source / 'Applications').is_symlink() else None,
                                 'app_signed_before': any(c[0] == '/usr/bin/codesign' and '--force' in c for c in self.calls)})
            token = ('SYNTHETIC disk image ' + str(len(self.images))).encode()
            image.write_bytes(token)
            self.images[token] = snapshot
            return self.result(argv)
        if verb == 'attach':
            mountpoint = flag(argv, '-mountpoint')
            image = Path(argv[-1])
            fresh = not os.path.exists(mountpoint) or not os.listdir(mountpoint)
            self.mounts.append({'argv': argv, 'mountpoint': mountpoint, 'fresh': fresh, 'image': image.name})
            if self.fail == 'attach':
                return self.result(argv, code=1)
            if os.path.exists(mountpoint):
                os.rmdir(mountpoint)
            shutil.copytree(self.images[image.read_bytes()], mountpoint, symlinks=True)
            self.mounted = mountpoint
            self.alter(Path(mountpoint))
            if self.fail == 'attach-after-mount':
                return self.result(argv, code=1)
            if self.fail == 'interrupt-attach':
                raise SyntheticInterrupt()
            return self.result(argv)
        if verb == 'detach':
            mountpoint = next((m['mountpoint'] for m in self.mounts if m['mountpoint'] in argv), None)
            if mountpoint is None:
                raise AssertionError('detach of an unknown mountpoint ' + str(argv))
            self.detaches.append(argv)
            if self.mounted is None or self.fail in ('detach', 'detach-always'):
                return self.result(argv, code=1)
            if self.fail == 'detach-once' and len(self.detaches) == 1:
                return self.result(argv, code=1)
            for child in Path(mountpoint).iterdir():
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()
            self.mounted = None
            return self.result(argv)
        raise AssertionError('Unexpected hdiutil verb ' + str(argv))

    def alter(self, mount):
        app = mount / 'tap-n-filter.app'
        resources = app / 'Contents/Resources/tap-n-filter_tap-n-filter.bundle/Resources'
        if self.damage == 'link-target':
            (mount / 'Applications').unlink()
            (mount / 'Applications').symlink_to('/private/tmp')
        elif self.damage == 'link-relative':
            (mount / 'Applications').unlink()
            (mount / 'Applications').symlink_to('Applications')
        elif self.damage == 'link-folder':
            (mount / 'Applications').unlink()
            (mount / 'Applications').mkdir()
        elif self.damage == 'link-missing':
            (mount / 'Applications').unlink()
        elif self.damage == 'extra-file':
            (mount / 'README.txt').write_text('SYNTHETIC extra')
        elif self.damage == 'extra-launcher':
            (mount / 'Launch tap-n-filter.command').write_text('SYNTHETIC launcher')
        elif self.damage == 'app-missing':
            shutil.rmtree(app)
        elif self.damage == 'resource-bytes':
            (resources / 'nested/file.bin').write_bytes(b'SYNTHETIC changed resource')
        elif self.damage == 'resource-extra':
            (resources / 'unexpected.bin').write_bytes(b'SYNTHETIC extra resource')
        elif self.damage == 'resource-missing':
            (resources / 'nested/file.bin').unlink()
        elif self.damage == 'icon':
            (app / 'Contents/Resources/AppIcon.icns').write_bytes(b'SYNTHETIC different icon')
        elif self.damage == 'executable':
            (app / 'Contents/MacOS/tap-n-filter').write_bytes(b'SYNTHETIC different, validly signed executable')
        elif self.damage == 'info-plist':
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            info['CFBundleIdentifier'] = 'com.example.other'
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        elif self.damage == 'app-extra':
            (app / 'Contents/MacOS/helper').write_bytes(b'SYNTHETIC extra executable')
        elif self.damage == 'hidden-payload':
            (mount / '.private-notes').write_text('SYNTHETIC hidden payload')
        elif self.damage == 'hidden-app-payload':
            (app / 'Contents/.private-notes').write_text('SYNTHETIC hidden payload inside the app')
        elif self.damage == 'fseventsd':
            (mount / '.fseventsd').mkdir()
            (mount / '.fseventsd/fseventsd-uuid').write_bytes(b'SYNTHETIC filesystem metadata')


class DiskImageBuildTests(unittest.TestCase):
    """build_at end to end with every native command synthetic (S4)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tnf-dmg-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / 'source'
        make_info(self.work / 'Sources/tap-n-filter/Resources/Info.plist')
        self.product = self.root / 'products'
        make_product(self.product)
        self.name = 'tap-n-filter-' + TAG + '-macos-15-arm64'

    def run_build(self, damage=None, fail=None, tag=TAG, output=None):
        native = SyntheticNative(self.root, self.product, damage, fail)
        self.last_native = native
        output = output or self.root / 'assets'
        with patch('release.subprocess.run', side_effect=native):
            r.build_at(self.work, self.root / 'scratch', dict(r.version(tag), commit=COMMIT), 'macos-15', output)
        return native, output

    def hdiutil_calls(self, native, verb):
        return [i for i, c in enumerate(native.calls) if c[:2] == ['/usr/bin/hdiutil', verb]]

    def test_assets_are_one_dmg_and_its_provenance_without_launcher_or_zip(self):
        native, output = self.run_build()
        self.assertEqual(sorted(os.listdir(output)), [self.name + '.dmg', self.name + '.json'])
        self.assertFalse(any(p.suffix in ('.zip', '.command') for p in self.root.rglob('*') if 'synthetic-image-store-' not in str(p)))
        provenance = json.loads((output / (self.name + '.json')).read_text())
        self.assertEqual(set(provenance), PROVENANCE_FIELDS)
        self.assertEqual(provenance['asset'], self.name + '.dmg')
        self.assertEqual(provenance['sha256'], r.digest(output / (self.name + '.dmg')))
        self.assertEqual(provenance['launch'], LAUNCH)
        self.assertEqual(provenance['architecture'], 'arm64')
        self.assertEqual(provenance['resources'], r.regular_files(self.product / 'tap-n-filter_tap-n-filter.bundle'))

    def test_image_is_compressed_named_and_holds_exactly_signed_app_and_applications_link(self):
        native, output = self.run_build()
        self.assertEqual(len(native.created), 1)
        created = native.created[0]
        self.assertEqual(flag(created['argv'], '-format'), 'UDZO')
        self.assertEqual(flag(created['argv'], '-volname'), 'tap-n-filter 0.2.0-beta.1')
        self.assertTrue(created['argv'][-1].endswith('.dmg'))
        self.assertEqual(created['entries'], ['Applications', 'tap-n-filter.app'])
        self.assertEqual(created['link'], '/Applications')
        self.assertTrue(created['app_signed_before'], 'image made before the app was ad-hoc signed')
        for tag, volume in (('v0.1.0-alpha.2', 'tap-n-filter 0.1.0-alpha.2'), ('v1.2.3', 'tap-n-filter 1.2.3')):
            with self.subTest(tag=tag):
                native, _ = self.run_build(tag=tag, output=self.root / ('assets-' + tag))
                self.assertEqual(flag(native.created[0]['argv'], '-volname'), volume)

    def test_verification_attaches_read_only_hidden_at_fresh_mountpoint_checks_then_detaches(self):
        native, output = self.run_build()
        attaches, detaches = self.hdiutil_calls(native, 'attach'), self.hdiutil_calls(native, 'detach')
        self.assertEqual(len(attaches), 1)
        self.assertEqual(len(detaches), 1)
        attach = native.calls[attaches[0]]
        self.assertIn('-readonly', attach)
        self.assertIn('-nobrowse', attach)
        mount = native.mounts[0]
        self.assertTrue(mount['fresh'], 'mountpoint was not fresh')
        self.assertEqual(mount['image'], self.name + '.dmg')
        self.assertFalse(mount['mountpoint'].startswith('/Volumes/'))
        self.assertFalse(Path(mount['mountpoint']).resolve().is_relative_to(output.resolve()))
        between = native.calls[attaches[0] + 1:detaches[0]]
        def on_mount(c):
            return any(a == mount['mountpoint'] or a.startswith(mount['mountpoint'] + '/') for a in c[1:])
        self.assertTrue(any(c[0] == '/usr/bin/codesign' and '--verify' in c and on_mount(c) for c in between), 'mounted signature not checked')
        self.assertTrue(any(c[0] == '/usr/bin/lipo' and on_mount(c) for c in between), 'mounted architecture not checked')
        self.assertIn(mount['mountpoint'], native.calls[detaches[0]])
        self.assertLess(attaches[0], detaches[0])
        self.assertIsNone(native.mounted)
        second, _ = self.run_build(output=self.root / 'assets-second')
        self.assertNotEqual(second.mounts[0]['mountpoint'], mount['mountpoint'])

    def test_image_content_mismatch_refuses_and_always_detaches(self):
        for damage in ('link-target', 'link-relative', 'link-folder', 'link-missing', 'extra-file', 'extra-launcher', 'app-missing',
                       'architecture', 'signature', 'resource-bytes', 'resource-extra', 'resource-missing', 'icon'):
            with self.subTest(damage=damage):
                output = self.root / ('assets-' + damage)
                with self.assertRaises(r.Refused):
                    self.run_build(damage=damage, output=output)
                native = self.last_native
                self.assertEqual(len(self.hdiutil_calls(native, 'attach')), 1)
                self.assertEqual(len(self.hdiutil_calls(native, 'detach')), 1, 'image left attached after refusal')
                self.assertIsNone(native.mounted)
                self.assertFalse(output.exists() and any(p.suffix == '.json' for p in output.iterdir()), 'provenance written for a refused image')

    def test_attach_or_detach_failure_refuses(self):
        for fail in ('attach', 'detach'):
            with self.subTest(fail=fail):
                output = self.root / ('assets-' + fail)
                with self.assertRaises(r.Refused):
                    self.run_build(fail=fail, output=output)
                self.assertFalse(output.exists() and any(p.suffix == '.json' for p in output.iterdir()), 'provenance written after a failed attach/detach')

    def assert_refused_and_detached(self, damage=None, fail=None):
        output = self.root / ('assets-' + str(damage) + '-' + str(fail))
        with self.assertRaises(r.Refused):
            self.run_build(damage=damage, fail=fail, output=output)
        native = self.last_native
        self.assertFalse(output.exists() and any(p.suffix == '.json' for p in output.iterdir()), 'provenance written for a refused image')
        return native

    def test_round1_app_that_differs_from_staging_refuses_D1_3(self):
        for damage in ('executable', 'info-plist', 'app-extra', 'hidden-app-payload'):
            with self.subTest(damage=damage):
                native = self.assert_refused_and_detached(damage=damage)
                self.assertIsNone(native.mounted, 'image left attached after refusal')

    def test_round1_hidden_payload_refuses_but_filesystem_metadata_is_accepted_D1_4(self):
        native = self.assert_refused_and_detached(damage='hidden-payload')
        self.assertIsNone(native.mounted)
        native, output = self.run_build(damage='fseventsd', output=self.root / 'assets-fseventsd')
        self.assertEqual(sorted(os.listdir(output)), [self.name + '.dmg', self.name + '.json'])

    def test_round1_partial_attach_is_detached_D1_5(self):
        native = self.assert_refused_and_detached(fail='attach-after-mount')
        mountpoint = native.mounts[0]['mountpoint']
        self.assertTrue(any(mountpoint in c for c in native.detaches), 'no detach after an attach that mounted then failed')
        self.assertIsNone(native.mounted, 'image left attached after a partial attach')

    def test_round1_failed_detach_retries_bounded_then_refuses_keeping_mountpoint_D1_5(self):
        native = self.assert_refused_and_detached(fail='detach-always')
        mountpoint = native.mounts[0]['mountpoint']
        self.assertGreaterEqual(len(native.detaches), 2, 'no detach retry')
        self.assertLessEqual(len(native.detaches), 5, 'detach retry unbounded')
        self.assertTrue(any('-force' in c for c in native.detaches), 'no -force detach retry')
        self.assertTrue(all(mountpoint in c for c in native.detaches))
        self.assertTrue(os.path.isdir(os.path.join(mountpoint, 'tap-n-filter.app')), 'mountpoint contents removed while still mounted')

    def test_round1_detach_that_succeeds_on_retry_completes_and_removes_mountpoint_D1_5(self):
        native, output = self.run_build(fail='detach-once', output=self.root / 'assets-detach-once')
        self.assertEqual(sorted(os.listdir(output)), [self.name + '.dmg', self.name + '.json'])
        self.assertEqual(len(native.detaches), 2)
        self.assertIsNone(native.mounted)
        self.assertFalse(os.path.exists(native.mounts[0]['mountpoint']), 'mountpoint kept after a confirmed detach')

    def test_round2_interrupt_after_attach_detaches_and_reraises_R2_3(self):
        for fail in ('interrupt-verify', 'interrupt-attach'):
            with self.subTest(fail=fail):
                output = self.root / ('assets-' + fail)
                with self.assertRaises(SyntheticInterrupt):
                    self.run_build(fail=fail, output=output)
                native = self.last_native
                mountpoint = native.mounts[0]['mountpoint']
                self.assertTrue(any(mountpoint in c for c in native.detaches), 'no detach after an interrupt')
                self.assertIsNone(native.mounted, 'image left attached after an interrupt')
                self.assertFalse(output.exists() and any(p.suffix == '.json' for p in output.iterdir()), 'provenance written after an interrupt')

    def test_round1_mountpoint_removed_after_clean_detach(self):
        native, _ = self.run_build(output=self.root / 'assets-clean-mount')
        self.assertFalse(os.path.exists(native.mounts[0]['mountpoint']))


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tnf-release-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.product = self.root / 'products'
        make_product(self.product)
        self.info = self.root / 'Info.plist'
        make_info(self.info)
        self.calls = []

    def synthetic_native(self, command):
        self.calls.append(list(map(str, command)))
        return 'arm64' if command[0] == '/usr/bin/lipo' else ''

    def test_minimal_nested_resources_version_icon_and_no_launcher(self):
        output = self.root / 'package'
        app, arch, resources = r.package(self.product, self.info, output, dict(r.version(TAG), commit=COMMIT), 'macos-15', self.synthetic_native)
        self.assertEqual(arch, 'arm64')
        self.assertEqual(r.regular_files(app / 'Contents/Resources/tap-n-filter_tap-n-filter.bundle'), resources)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '0.2.0')
        self.assertEqual(info['CFBundleVersion'], '1.2.0b1')
        self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
        self.assertEqual((app / 'Contents/Resources/AppIcon.icns').read_bytes(), ICON)
        self.assertFalse(any('Tests.bundle' in str(p) for p in output.rglob('*')))
        self.assertFalse(any(p.suffix in ('.command', '.zip') for p in output.rglob('*')), 'launcher or zip left in package')
        self.assertEqual([c[1] for c in self.calls if c[0] == '/usr/bin/codesign'], ['--force', '--verify'])
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, output, r.version(TAG), 'macos-15', self.synthetic_native)

    def test_missing_icon_refuses(self):
        (self.info.parent / 'AppIcon.icns').unlink()
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', self.synthetic_native)

    def test_missing_or_symlink_resource_refuses(self):
        self.resource = self.product / 'tap-n-filter_tap-n-filter.bundle/Resources'
        (self.resource / 'neck1.pdf').unlink()
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', self.synthetic_native)
        (self.resource / 'neck1.pdf').symlink_to(self.resource / 'nested/file.bin')
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', self.synthetic_native)
        self.assertEqual(self.calls, [])

    def test_embedded_runner_path_refuses_before_native_boundary(self):
        (self.product / 'tap-n-filter').write_bytes(b'SYNTHETIC /Users/runner/work/private-source.swift')
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', self.synthetic_native)
        self.assertEqual(self.calls, [])

    def test_private_info_or_signature_failure_refuses(self):
        info = plistlib.loads(self.info.read_bytes())
        info['TNFLibrarySessionFile'] = '/SYNTHETIC/private/library-v5.json'
        self.info.write_bytes(plistlib.dumps(info))
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', self.synthetic_native)
        del info['TNFLibrarySessionFile']
        self.info.write_bytes(plistlib.dumps(info))
        def refuse(command):
            if command[0] == '/usr/bin/codesign':
                raise r.Refused('SYNTHETIC signing failure')
            return 'arm64'
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, self.root / 'out', r.version(TAG), 'macos-15', refuse)


class BuildCheckoutTests(unittest.TestCase):
    def test_public_exact_commit_roots_and_owned_cleanup_on_success_or_refusal(self):
        for failure in (None, 'build', 'HEAD', 'tag'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix='tnf-build-boundary-') as tmp:
                calls = []
                roots = []
                registered = []
                def fake_command(argv, cwd=None):
                    argv = list(map(str, argv))
                    calls.append((argv, cwd))
                    if argv[:3] == ['git', 'worktree', 'add']:
                        work = Path(argv[4])
                        work.mkdir()
                        (work / '.git').write_text('SYNTHETIC Git boundary, not a real checkout')
                        registered.append(work)
                        roots.append(work.parent)
                        self.assertEqual(work.parent.stat().st_mode & 0o777, 0o700)
                        self.assertTrue(str(work).startswith('/private/tmp/tnf-release-'))
                        self.assertEqual(argv[-1], COMMIT)
                    elif argv[:2] == ['git', 'rev-parse']:
                        if failure == 'HEAD' and argv[2] == 'HEAD' or failure == 'tag' and argv[2] != 'HEAD':
                            return 'b' * 40
                        return COMMIT
                    elif argv[:3] == ['git', 'worktree', 'list']:
                        return '\n'.join('worktree ' + str(p) for p in registered)
                    elif argv[:3] == ['git', 'worktree', 'remove']:
                        self.assertEqual(Path(argv[-1]), registered[0])
                        shutil.rmtree(registered.pop())
                    else:
                        self.fail('Unexpected boundary ' + str(argv))
                    return ''
                def fake_build(work, scratch, identity, runner, output):
                    self.assertEqual(scratch, work.parent / 'build')
                    self.assertEqual(identity['commit'], COMMIT)
                    self.assertTrue(output.is_absolute())
                    if failure == 'build':
                        raise r.Refused('SYNTHETIC build refusal')
                with patch('release.command', side_effect=fake_command), patch('release.build_at', side_effect=fake_build) as builder:
                    if failure:
                        with self.assertRaises(r.Refused):
                            r.build(dict(r.version(TAG), commit=COMMIT), 'macos-15', Path(tmp) / 'assets')
                    else:
                        r.build(dict(r.version(TAG), commit=COMMIT), 'macos-15', Path(tmp) / 'assets')
                    self.assertEqual(builder.call_count, 0 if failure in ('HEAD', 'tag') else 1)
                self.assertTrue(roots and all(not p.exists() for p in roots))
                self.assertFalse(any('prune' in argv for argv, _ in calls))


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tnf-assets-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for runner in ('macos-15', 'macos-26'):
            name = 'tap-n-filter-' + TAG + '-' + runner + '-arm64'
            image = self.root / (name + '.dmg')
            image.write_bytes(b'SYNTHETIC non-native disk image ' + runner.encode())
            (self.root / (name + '.json')).write_text(json.dumps({'tag': TAG, 'commit': COMMIT, 'runner': runner, 'architecture': 'arm64', 'asset': image.name, 'sha256': r.digest(image)}))
        self.assets = r.asset_plan(self.root, TAG, COMMIT)

    def test_prerelease_publishes_only_after_upload_and_identical_rerun_is_noop(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        self.assertFalse(api.release['draft'])
        self.assertTrue(api.release['prerelease'])
        self.assertEqual(len(api.assets), 4)
        self.assertEqual(api.calls[-1][0], 'PATCH')
        api.calls.clear()
        r.publish(api, TAG, COMMIT, self.assets)
        self.assertTrue(all(call[0] == 'GET' for call in api.calls))

    def test_different_existing_asset_or_release_identity_refuses_without_replacement(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        api.assets[0]['digest'] = 'sha256:' + '0' * 64
        api.calls.clear()
        with self.assertRaises(r.Refused):
            r.publish(api, TAG, COMMIT, self.assets)
        self.assertTrue(all(call[0] == 'GET' for call in api.calls))
        api.release['body'] = 'SYNTHETIC different commit'
        with self.assertRaises(r.Refused):
            r.publish(api, TAG, COMMIT, self.assets)

    def test_partial_draft_can_finish_same_bytes(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        api.release['draft'] = True
        api.assets.pop()
        api.calls.clear()
        r.publish(api, TAG, COMMIT, self.assets)
        self.assertEqual(len([c for c in api.calls if c[0] == 'POST']), 1)
        self.assertFalse(api.release['draft'])

    def test_draft_invisible_to_tag_lookup_is_resumed_without_second_release(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        api.release['draft'] = True
        api.assets.pop()
        self.assertIsNone(api.request('GET', '/releases/tags/' + TAG))
        api.calls.clear()
        r.publish(api, TAG, COMMIT, self.assets)
        self.assertEqual(len(api.releases), 1)
        self.assertFalse(any(c[0] == 'POST' and c[1] == '/releases' for c in api.calls))
        self.assertFalse(api.release['draft'])
        self.assertEqual(len(api.assets), 4)

    def test_draft_lookup_checks_later_pages_and_refuses_ambiguous_matches(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        api.release['draft'] = True
        unrelated = [{'id': 1000+i, 'tag_name': 'other-'+str(i), 'draft': True} for i in range(100)]
        api.release_pages = {1: unrelated, 2: [api.release]}
        api.calls.clear()
        r.publish(api, TAG, COMMIT, self.assets)
        self.assertTrue(any(c[1].endswith('page=2') for c in api.calls))
        self.assertEqual(len(api.releases), 1)
        api.release['draft'] = True
        api.release_pages = {1: [api.release, dict(api.release, id=999)]}
        api.calls.clear()
        with self.assertRaises(r.Refused):
            r.publish(api, TAG, COMMIT, self.assets)
        self.assertTrue(all(c[0] == 'GET' for c in api.calls))

    def test_draft_lookup_refuses_unavailable_or_repeated_pagination(self):
        for first in (None, {'unexpected': True}, [{'id': 1, 'tag_name': TAG, 'draft': True}]*100):
            api = SyntheticAPI()
            api.release_pages = {1: first}
            with self.subTest(page=first), self.assertRaises(r.Refused):
                r.publish(api, TAG, COMMIT, self.assets)
            self.assertTrue(all(c[0] == 'GET' for c in api.calls))

    def test_published_plus_draft_and_metadata_drift_refuse_before_mutation(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        for rows in ([api.release, dict(api.release, id=999, draft=True)], [dict(api.release, target_commitish='b' * 40)]):
            api.release_pages = {1: rows}
            api.calls.clear()
            with self.subTest(rows=rows), self.assertRaises(r.Refused):
                r.publish(api, TAG, COMMIT, self.assets)
            self.assertTrue(all(c[0] == 'GET' for c in api.calls))

    def test_stable_publishing_refuses_before_api_call(self):
        api = SyntheticAPI()
        with self.assertRaises(r.Refused):
            r.publish(api, 'v1.2.3', COMMIT, self.assets)
        self.assertEqual(api.calls, [])

    def test_publish_uploads_exactly_the_dmg_and_json_pairs(self):
        api = SyntheticAPI()
        r.publish(api, TAG, COMMIT, self.assets)
        uploaded = sorted(c[3].name for c in api.calls if c[0] == 'POST' and '/assets?' in c[1])
        expected = sorted('tap-n-filter-' + TAG + '-' + runner + '-arm64' + suffix for runner in ('macos-15', 'macos-26') for suffix in ('.dmg', '.json'))
        self.assertEqual(uploaded, expected)
        self.assertEqual(sorted(self.assets), expected)

    def test_zip_pairs_are_no_longer_release_assets(self):
        with tempfile.TemporaryDirectory(prefix='tnf-zip-synthetic-') as tmp:
            folder = Path(tmp)
            for runner in ('macos-15', 'macos-26'):
                name = 'tap-n-filter-' + TAG + '-' + runner + '-arm64'
                archive = folder / (name + '.zip')
                archive.write_bytes(b'SYNTHETIC old zip archive')
                (folder / (name + '.json')).write_text(json.dumps({'tag': TAG, 'commit': COMMIT, 'runner': runner, 'architecture': 'arm64', 'asset': archive.name, 'sha256': r.digest(archive)}))
            with self.assertRaises(r.Refused):
                r.asset_plan(folder, TAG, COMMIT)
        (self.root / 'Launch tap-n-filter.command').write_text('SYNTHETIC launcher')
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, COMMIT)

    def test_wrong_commit_digest_or_extra_files_refuse(self):
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, 'b' * 40)
        target = next(self.root.glob('*.dmg'))
        target.write_bytes(b'SYNTHETIC changed bytes')
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, COMMIT)
        (self.root / 'private.log').write_text('SYNTHETIC unrelated output')
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, COMMIT)


if __name__ == '__main__':
    unittest.main()

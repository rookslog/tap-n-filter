"""Bounded synthetic fixtures. No Swift build, signing, App or network execution."""
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

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

    def test_malformed_or_unsafe_versions_refuse(self):
        for tag in ['1.2.3', 'v01.2.3', 'v1.2', 'v1.2.3-rc.1', 'v1.2.3-beta.0', 'v1.2.3-beta.256', 'v1.2.3;echo injected', 'v1.2.3\n', 'v9999.1.1']:
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


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tnf-launcher-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.session = self.root / 'sessions' / TAG
        self.open_call = self.root / 'open-call'

    def run_launcher(self, count='0', status=0):
        owner = self.root / 'synthetic-owner'
        owner.write_text("#!/bin/bash\ncat >/dev/null\nprintf '%s\\n' " + shlex.quote(count) + "\nexit " + str(status) + "\n")
        owner.chmod(0o755)
        opener = self.root / 'synthetic-open'
        opener.write_text("#!/bin/bash\nprintf '%s\\0' \"$@\" > " + shlex.quote(str(self.open_call)) + "\n")
        opener.chmod(0o755)
        script = r.launcher(TAG).replace('/usr/bin/osascript', str(owner)).replace('/usr/bin/open', str(opener))
        script = script.replace('$HOME/Library/Application Support/tap-n-filter/versions/', str(self.root / 'sessions') + '/')
        launcher = self.root / 'launch.command'
        launcher.write_text(script)
        return subprocess.run(['/bin/bash', str(launcher)], capture_output=True, text=True, timeout=5)

    def test_incumbent_and_unknown_owner_refuse_without_open_or_data_creation(self):
        for count, status in [('1', 0), ('2', 0), ('unknown', 0), ('', 0), ('0', 9)]:
            with self.subTest(count=count, status=status):
                outcome = self.run_launcher(count, status)
                self.assertNotEqual(outcome.returncode, 0)
                self.assertFalse(self.open_call.exists())
                self.assertFalse(self.session.exists())

    def test_no_owner_uses_launchservices_without_new_instance_and_private_directory(self):
        outcome = self.run_launcher()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(self.session.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.session.parent.stat().st_mode & 0o777, 0o700)
        arguments = self.open_call.read_bytes().decode().rstrip('\0').split('\0')
        self.assertEqual(arguments, ['-a', str(self.root / 'tap-n-filter.app'), '--args', '--library-session-file', str(self.session / 'library-v5.json')])
        self.assertNotIn('-n', arguments)

    def test_existing_version_data_and_permissions_are_not_rewritten(self):
        self.session.mkdir(parents=True)
        self.session.chmod(0o750)
        saved = self.session / 'library-v5.json'
        saved.write_bytes(b'SYNTHETIC existing owned data, not a real library')
        outcome = self.run_launcher()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertEqual(self.session.stat().st_mode & 0o777, 0o750)
        self.assertEqual(saved.read_bytes(), b'SYNTHETIC existing owned data, not a real library')

    def test_generated_owner_predicate_covers_bundle_executable_and_try_families(self):
        query = r.launcher(TAG).split("<<'JXA'\n", 1)[1].split('\nJXA', 1)[0]
        rows = [
            ({'id': 'com.loganrooks.tap-n-filter', 'executable': 'unusual', 'bundle': 'Other.app'}, '1'),
            ({'id': 'com.loganrooks.tap-n-filter.operator-try', 'executable': 'unusual', 'bundle': 'Other.app'}, '1'),
            ({'id': 'local.private.pin', 'executable': 'tap-n-filter', 'bundle': 'Pinned.app'}, '1'),
            ({'id': 'local.private.try', 'executable': 'unusual', 'bundle': 'TNF-Trial.app'}, '1'),
            ({'id': 'local.private.pin', 'executable': 'unusual', 'bundle': 'TNF.app'}, '1'),
            ({'id': 'local.private.try', 'executable': 'unusual', 'bundle': 'TNF-operator-try-04.app'}, '1'),
            ({'id': 'com.apple.Safari', 'executable': 'Safari', 'bundle': 'Safari.app'}, '0'),
        ]
        prefix = "var ObjC={import:function(){},unwrap:function(v){return v;}};"
        def execute(items):
            fixture = json.dumps(items)
            mock = "var rows=" + fixture + ";var apps={count:rows.length,objectAtIndex:function(i){var r=rows[i];return {bundleIdentifier:r.id,executableURL:{lastPathComponent:r.executable},bundleURL:{lastPathComponent:r.bundle}};}};var $={NSWorkspace:{sharedWorkspace:{runningApplications:apps}}};"
            return subprocess.run(['node', '-e', prefix + mock + query + ';console.log(run());'], capture_output=True, text=True, timeout=5)
        for row, expected in rows:
            with self.subTest(row=row):
                result = execute([row])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        self.assertNotEqual(execute([{}]).returncode, 0)
        self.assertEqual(execute([]).stdout.strip(), '0')


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tnf-release-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.product = self.root / 'products'
        self.resource = self.product / 'tap-n-filter_tap-n-filter.bundle/Resources'
        self.resource.mkdir(parents=True)
        (self.resource / 'neck1.pdf').write_bytes(b'SYNTHETIC glyph, not actual native evidence')
        (self.resource / 'nested').mkdir()
        (self.resource / 'nested/file.bin').write_bytes(b'SYNTHETIC nested resource')
        (self.product / 'tap-n-filter').write_bytes(b'SYNTHETIC not a Mach-O executable')
        (self.product / 'tap-n-filter').chmod(0o755)
        (self.product / 'Tests.bundle').mkdir()
        (self.product / 'Tests.bundle/private.txt').write_text('SYNTHETIC must not be copied')
        self.info = self.root / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.loganrooks.tap-n-filter', 'CFBundleExecutable': 'tap-n-filter', 'LSUIElement': True}))
        self.calls = []

    def synthetic_native(self, command):
        self.calls.append(list(map(str, command)))
        return 'arm64' if command[0] == '/usr/bin/lipo' else ''

    def test_minimal_nested_resources_version_launcher_and_archive(self):
        output = self.root / 'package'
        app, arch, resources = r.package(self.product, self.info, output, dict(r.version(TAG), commit=COMMIT), 'macos-15', self.synthetic_native)
        self.assertEqual(arch, 'arm64')
        self.assertEqual(r.regular_files(app / 'Contents/Resources/tap-n-filter_tap-n-filter.bundle'), resources)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '0.2.0')
        self.assertEqual(info['CFBundleVersion'], '1.2.0b1')
        self.assertFalse(any('Tests.bundle' in str(p) for p in output.rglob('*')))
        launcher = output / 'Launch tap-n-filter.command'
        self.assertIn('versions/' + TAG, launcher.read_text())
        self.assertIn('--library-session-file "$session_dir/library-v5.json"', launcher.read_text())
        self.assertNotIn(str(self.root), launcher.read_text())
        archive = self.root / 'asset.zip'
        r.archive(output, archive)
        with zipfile.ZipFile(archive) as zipped:
            self.assertIn('tap-n-filter.app/Contents/Resources/tap-n-filter_tap-n-filter.bundle/Resources/nested/file.bin', zipped.namelist())
            self.assertEqual(zipped.getinfo('Launch tap-n-filter.command').external_attr >> 16 & 0o777, 0o755)
        second = self.root / 'asset2.zip'
        r.archive(output, second)
        self.assertEqual(r.digest(archive), r.digest(second))
        self.assertEqual([c[1] for c in self.calls if c[0] == '/usr/bin/codesign'], ['--force', '--verify'])
        with self.assertRaises(r.Refused):
            r.package(self.product, self.info, output, r.version(TAG), 'macos-15', self.synthetic_native)

    def test_missing_or_symlink_resource_refuses(self):
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
            zip_path = self.root / (name + '.zip')
            zip_path.write_bytes(b'SYNTHETIC non-native archive')
            (self.root / (name + '.json')).write_text(json.dumps({'tag': TAG, 'commit': COMMIT, 'runner': runner, 'architecture': 'arm64', 'asset': zip_path.name, 'sha256': r.digest(zip_path)}))
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

    def test_wrong_commit_digest_or_extra_files_refuse(self):
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, 'b' * 40)
        target = next(self.root.glob('*.zip'))
        target.write_bytes(b'SYNTHETIC changed bytes')
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, COMMIT)
        (self.root / 'private.log').write_text('SYNTHETIC unrelated output')
        with self.assertRaises(r.Refused):
            r.asset_plan(self.root, TAG, COMMIT)


if __name__ == '__main__':
    unittest.main()

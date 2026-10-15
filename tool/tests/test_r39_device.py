import base64
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse


spec = importlib.util.spec_from_file_location(
    'r39_device', Path(__file__).resolve().parents[1] / 'r39-device.py')
device = importlib.util.module_from_spec(spec)
spec.loader.exec_module(device)


class R39DeviceTests(unittest.TestCase):
    def setUp(self):
        self.cfg = {'runId': '0123456789abcdef0123456789abcdef'}

    def test_callback_matches_dart_fixture_without_real_accounts(self):
        uri = urlparse(device.callback(self.cfg))
        query = parse_qs(uri.query)
        self.assertEqual((uri.scheme, uri.netloc, uri.path),
                         ('shun-uuremote', 'callback', '/bind'))
        state = query['state'][0]
        self.assertEqual(len(state), 22)
        self.assertEqual(base64.urlsafe_b64decode(state + '==').hex(), self.cfg['runId'])
        self.assertEqual(query['nonce'], ['r39-' + self.cfg['runId']])

    def test_phase_report_rejects_wrong_run_phase_status_and_pid(self):
        good = {**self.cfg, 'phase': 'cold', 'status': 'passed', 'pid': 123}
        self.assertEqual(device.report(json.dumps(good), self.cfg, 'cold', 'passed'), good)
        for changes in ({'runId': 'old'}, {'phase': 'seed'},
                        {'status': 'started'}, {'pid': True}, {'pid': 0}):
            with self.assertRaises(RuntimeError):
                device.report(json.dumps({**good, **changes}), self.cfg, 'cold', 'passed')

    def test_vm_uri_only_accepts_local_service_announcement(self):
        self.assertIsNone(device.vm_service('http://127.0.0.1:1234/abc/'))
        self.assertIsNone(device.vm_service(
            'Dart VM service is listening on http://example.com:1234/abc/'))
        uri = device.vm_service(
            '10-14 I/flutter: The Dart VM service is listening on http://127.0.0.1:43210/abc=/')
        self.assertEqual(uri.port, 43210)
        self.assertEqual(uri.path, '/abc=/')

    def test_private_write_refuses_path_escape_before_adb(self):
        with patch.object(device, 'shell') as shell:
            for name in ('../outside', '/absolute', 'x;id', ''):
                with self.assertRaises(RuntimeError):
                    device.private_write(name, 'unused')
            shell.assert_not_called()

    def test_timeout_does_not_disclose_callback_arguments(self):
        args = ['adb', 'shell', device.callback(self.cfg)]
        with patch.object(device.subprocess, 'run', side_effect=
                          device.subprocess.TimeoutExpired(args, 1)):
            with self.assertRaises(RuntimeError) as failure:
                device.run(args)
        self.assertNotIn(self.cfg['runId'], str(failure.exception))
        self.assertNotIn('shun-uuremote', str(failure.exception))

    def test_wrong_avd_refused_before_shell_operations(self):
        with patch.object(device, 'adb', side_effect=['device', 'other-avd\nOK']), \
                patch.object(device, 'shell') as shell:
            with self.assertRaisesRegex(RuntimeError, 'other than'):
                device.check_device()
            shell.assert_not_called()

    def test_physical_device_refused(self):
        with patch.object(device, 'adb', side_effect=['device', device.AVD + '\nOK']), \
                patch.object(device, 'shell', return_value='0'):
            with self.assertRaisesRegex(RuntimeError, 'physical'):
                device.check_device()

    def test_missing_sdk_refused_before_device_check(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(device, 'SDK', Path(directory)), \
                patch.object(device, 'check_device') as check:
            with self.assertRaisesRegex(RuntimeError, 'SDK missing'):
                device.preflight({})
            check.assert_not_called()

    def test_low_space_refused_before_device_or_install(self):
        with patch.object(Path, 'is_file', return_value=True), \
                patch.object(device.shutil, 'disk_usage') as usage, \
                patch.object(device, 'check_device') as check:
            usage.return_value.free = device.MIN_BUILD_FREE - 1
            with self.assertRaisesRegex(RuntimeError, '12 GiB'):
                device.preflight({'FLUTTER_SDK': '/unused'}, build=True)
            check.assert_not_called()


    def test_same_name_avd_outside_project_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            chain = Path(directory)
            (chain / 'avd').mkdir()
            (chain / 'avd' / f'{device.AVD}.ini').write_text('path=/some/other/avd\n')
            with patch.object(device, 'CHAIN', chain), \
                    patch.object(device, 'adb', side_effect=['device', device.AVD]), \
                    patch.object(device, 'shell', side_effect=['1', device.AVD_APIS[device.AVD]]), \
                    patch.object(device, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'outside the project'):
                    device.check_device()
                run.assert_not_called()

    def test_avd_must_run_from_project_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            chain = Path(directory).resolve()
            (chain / 'avd').mkdir()
            (chain / 'avd' / f'{device.AVD}.ini').write_text(
                f'path={chain}/avd/{device.AVD}.avd\n')
            for process, accepted in [
                (f'{device.SDK}/emulator/qemu -avd {device.AVD} -port 5580', True),
                (f'/other/emulator/qemu -avd {device.AVD} -port 5580', False),
                (f'{device.SDK}/emulator/qemu -avd {device.AVD} -port 5554', False),
            ]:
                with patch.object(device, 'CHAIN', chain), \
                        patch.object(device, 'adb', side_effect=['device', device.AVD]), \
                        patch.object(device, 'shell', side_effect=['1', device.AVD_APIS[device.AVD]]), \
                        patch.object(device, 'run', return_value=process):
                    if accepted:
                        device.check_device()
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'emulator process'):
                            device.check_device()

    def test_reused_emulator_symlink_is_checked_by_real_binary_location(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / 'project-sdk'
            existing = root / 'homebrew-emulator'
            sdk.mkdir()
            existing.mkdir()
            (sdk / 'emulator').symlink_to(existing, target_is_directory=True)
            with patch.object(device, 'SDK', sdk):
                self.assertTrue(device.emulator_process_matches(
                    f'{existing}/qemu -avd {device.AVD} -port 5580'))
                for command in (
                    f'{root}/other/qemu -avd {device.AVD} -port 5580',
                    f'{existing}/qemu -avd {device.AVD}-other -port 5580',
                    f'{existing}/qemu -avd {device.AVD} -port 55800',
                    f'{existing}/qemu -avd',
                ):
                    self.assertFalse(device.emulator_process_matches(command))

    def test_unknown_profile_refused_before_contacting_device(self):
        with patch.object(device, 'AVD', 'personal-phone'), \
                patch.object(device, 'adb') as adb:
            with self.assertRaisesRegex(RuntimeError, 'Unsupported'):
                device.check_device()
            adb.assert_not_called()

    def test_build_environment_disables_implicit_sdk_installation(self):
        with patch.dict(device.os.environ, {'PATH': '/usr/bin'}, clear=True), \
                patch.object(device, 'run', side_effect=['/fixture/bin/zig', '0.16.0']):
            env = device.environment()
        self.assertEqual(env['ORG_GRADLE_PROJECT_android.builder.sdkDownload'], 'false')
        self.assertEqual(env['ANDROID_HOME'], str(device.SDK))

    def test_storage_scan_accepts_no_plaintext_and_requires_both_namespaces(self):
        def archive(rows):
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode='w') as output:
                for name, contents in rows.items():
                    entry = tarfile.TarInfo(name)
                    entry.size = len(contents)
                    output.addfile(entry, io.BytesIO(contents))
            return data.getvalue()

        good = {'shared_prefs/shun_uuremote.xml': b'ciphertext-uu',
                'shared_prefs/shun_rustdesk.xml': b'ciphertext-rd'}
        for rows, accepted in [
            (good, True),
            ({'files/unrelated': b'nothing'}, False),
            ({**good, 'files/leak': ('r39-new-' + self.cfg['runId']).encode()}, False),
            ({**good, 'files/leak': b'Zm9v+YmFy/YmF6=='}, False),
        ]:
            with tempfile.TemporaryDirectory() as directory, \
                    patch.object(device.subprocess, 'run',
                                 return_value=SimpleNamespace(stdout=archive(rows))):
                path = Path(directory)
                if accepted:
                    device.scan_storage(self.cfg, path)
                    self.assertTrue(json.loads((path / 'storage-scan.json').read_text())['passed'])
                else:
                    with self.assertRaises(RuntimeError):
                        device.scan_storage(self.cfg, path)
                    self.assertFalse((path / 'storage-scan.json').exists())


if __name__ == '__main__':
    unittest.main()

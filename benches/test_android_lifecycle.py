# SPDX-License-Identifier: AGPL-3.0-only
"""Lifecycle-only fixtures: real local descendants, no adb/device/timing run."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('android_runner', ROOT / 'run-android.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Lifecycle(unittest.TestCase):
    def test_interrupt_retires_local_child_and_grandchild(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig), tempfile.TemporaryDirectory() as tmp:
                tmp = Path(tmp)
                helper = tmp / 'helper.py'
                helper.write_text('''import subprocess,signal,os,sys,json,time
p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"])
def stop(s,f):
 p.terminate();p.wait();raise SystemExit(128+s)
signal.signal(signal.SIGTERM,stop)
open(sys.argv[1],"w").write(json.dumps([os.getpid(),p.pid]))
time.sleep(60)
''')
                controller = tmp / 'controller.py'
                controller.write_text('''import importlib.util,signal,sys
s=importlib.util.spec_from_file_location("runner",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
for n in (signal.SIGINT,signal.SIGTERM):signal.signal(n,m.interrupted)
try:m.command([sys.executable,sys.argv[2],sys.argv[3]])
except m.Interrupted as e:raise SystemExit(128+e.signum)
''')
                p = subprocess.Popen([sys.executable, str(controller), str(ROOT / 'run-android.py'),
                                      str(helper), str(tmp / 'pids')], start_new_session=True)
                pids = []
                try:
                    deadline = time.monotonic() + 5
                    while not (tmp / 'pids').exists() and time.monotonic() < deadline:
                        time.sleep(.01)
                    pids = json.loads((tmp / 'pids').read_text())
                    p.send_signal(sig)
                    self.assertEqual(p.wait(timeout=8), 128 + sig)
                    self.assertTrue(all(not alive(pid) for pid in pids), pids)
                finally:
                    if p.poll() is None:
                        os.killpg(p.pid, signal.SIGKILL)
                        p.wait()
                    for pid in pids:
                        if alive(pid):
                            os.kill(pid, signal.SIGKILL)

    def test_transport_unknown_retains_identity_and_scratch(self):
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'oscillux-bench.fixture'
            scratch.mkdir()
            (scratch / 'native-frame').write_text('owned recovery evidence')
            record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                          remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
            with mock.patch.object(runner, 'command', side_effect=subprocess.CalledProcessError(42, ['adb'])):
                self.assertFalse(runner.cleanup(scratch, record))
            self.assertTrue((scratch / 'native-frame').exists())
            saved = json.loads((scratch / 'ownership.json').read_text())
            self.assertEqual(saved['cleanup'], 'UNKNOWN')
            self.assertEqual(saved['remote'], record['remote'])

    def test_unknown_retirement_never_requests_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'oscillux-bench.fixture'
            scratch.mkdir()
            record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                          remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
            with mock.patch.object(runner, 'command', side_effect=['PRESENT\n', 'fixture-token\n', 'UNKNOWN\n']) as call:
                self.assertFalse(runner.cleanup(scratch, record))
            self.assertEqual(call.call_count, 3)
            self.assertTrue((scratch / 'ownership.json').exists())

    def test_confirmed_absence_recovers_known_quiescent_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'oscillux-bench.fixture'
            scratch.mkdir()
            record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                          remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
            with mock.patch.object(runner, 'command', side_effect=['ABSENT\n', 'ABSENT\n']):
                self.assertTrue(runner.cleanup(scratch, record))
            self.assertFalse(scratch.exists())

    def test_foreign_directory_owner_prevents_cleanup_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'oscillux-bench.fixture'
            scratch.mkdir()
            record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                          remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
            with mock.patch.object(runner, 'command', side_effect=['PRESENT\n', 'foreign-token\n']) as call:
                self.assertFalse(runner.cleanup(scratch, record))
            self.assertEqual(call.call_count, 2)
            self.assertTrue((scratch / 'ownership.json').exists())

    def test_removal_confirmation_failure_keeps_local_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / 'oscillux-bench.fixture'
            scratch.mkdir()
            record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                          remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
            with mock.patch.object(runner, 'command', side_effect=['PRESENT\n', 'fixture-token\n', 'RETIRED\n', None,
                                                                  subprocess.CalledProcessError(42, ['adb'])]):
                self.assertFalse(runner.cleanup(scratch, record))
            self.assertTrue((scratch / 'ownership.json').exists())

    def test_entrypoint_uncertain_setup_stays_held_after_transport_recovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            producer = tmp / 'producer'
            (producer / 'dist').mkdir(parents=True)
            (producer / 'dist/manifest.json').write_text(json.dumps({'build': {'sourceRevision': 'fixture'}}))
            library = producer / 'target/artifacts/aarch64-linux-android/release/liboscillux.so'
            library.parent.mkdir(parents=True)
            library.write_bytes(b'fixture-only-not-loaded')
            compiler = tmp / 'ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang'
            compiler.parent.mkdir(parents=True)
            compiler.write_text('#!' + sys.executable + '\nimport pathlib,sys\npathlib.Path(sys.argv[sys.argv.index("-o")+1]).write_bytes(b"fixture-not-executed")\n')
            compiler.chmod(0o700)
            tools = tmp / 'bin'
            tools.mkdir()
            adb = tools / 'adb'
            adb.write_text('#!/bin/sh\nexit 42\n')
            adb.chmod(0o700)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                       ANDROID_NDK_HOME=str(tmp / 'ndk'), TMPDIR=str(tmp))
            result = subprocess.run([sys.executable, str(ROOT / 'run-android.py'), str(producer), 'fixture'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 90, result.stderr)
            self.assertIn('CLEANUP_HOLD UNKNOWN', result.stderr)
            records = list(tmp.glob('oscillux-bench.*/ownership.json'))
            self.assertEqual(len(records), 1)
            record = json.loads(records[0].read_text())
            self.assertTrue(record['remoteMayExist'])
            self.assertEqual(record['cleanup'], 'UNKNOWN')
            self.assertTrue((records[0].parent / 'native-frame').exists())
            self.assertEqual(record['pendingMutation'], 'mkdir')
            # Transport restored and two absence responses would still not fence a late mkdir.
            adb.write_text('#!/bin/sh\necho ABSENT\n')
            recovered = subprocess.run([sys.executable, str(ROOT / 'run-android.py'),
                                        '--cleanup-only', str(records[0].parent)], env=env,
                                       capture_output=True, text=True, timeout=10)
            self.assertEqual(recovered.returncode, 90, recovered.stderr)
            self.assertTrue(records[0].parent.exists())
            self.assertEqual(json.loads(records[0].read_text())['pendingMutation'], 'mkdir')

    def test_delayed_mutation_cannot_outlive_discarded_ownership(self):
        # Controlled ordering witness: a dispatched operation applies only after
        # cleanup's decision. Neither current absence nor restored transport fences it.
        for operation in ('mkdir', 'push', 'chmod', 'retirement', 'scratch-removal'):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as tmp:
                tmp = Path(tmp)
                scratch = tmp / 'oscillux-bench.fixture'
                scratch.mkdir()
                late = tmp / 'late-remote-effect'
                release = threading.Event()
                worker = threading.Thread(target=lambda: (release.wait(), late.write_text(operation)))
                worker.start()
                record = dict(serial='fixture', remote='/data/local/tmp/' + scratch.name,
                              remoteMayExist=True, ownerToken='fixture-token', pendingMutation=None)
                try:
                    with mock.patch.object(runner, 'command', side_effect=subprocess.TimeoutExpired(['adb'], 1)):
                        with self.assertRaises(subprocess.TimeoutExpired):
                            runner.mutation(scratch, record, operation, ['adb'])
                    with mock.patch.object(runner, 'command', return_value='ABSENT\n') as call:
                        self.assertFalse(runner.cleanup(scratch, record))
                        call.assert_not_called()
                    self.assertTrue((scratch / 'ownership.json').exists())
                    release.set()
                    worker.join(timeout=3)
                    self.assertTrue(late.exists())
                    saved = json.loads((scratch / 'ownership.json').read_text())
                    self.assertEqual(saved['pendingMutation'], operation)
                    with mock.patch.object(runner, 'command', return_value='ABSENT\n') as call:
                        self.assertFalse(runner.cleanup(scratch, saved))
                        call.assert_not_called()
                    self.assertTrue((scratch / 'ownership.json').exists())
                finally:
                    release.set()
                    worker.join(timeout=3)
                    self.assertFalse(worker.is_alive())

    def test_remote_pending_identity_is_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            remote = Path(tmp)
            control = remote / 'android-control.sh'
            control.write_text((ROOT / 'android-control.sh').read_text())
            (remote / 'NATIVE_PENDING').touch()
            result = subprocess.run(['sh', str(control), 'cleanup'], capture_output=True,
                                    text=True, timeout=8)
            self.assertEqual(result.returncode, 90)
            self.assertIn('UNKNOWN', result.stdout)
            self.assertTrue((remote / 'NATIVE_PENDING').exists())

    def test_cancelled_launcher_cannot_start_native(self):
        with tempfile.TemporaryDirectory() as tmp:
            remote = Path(tmp)
            control = remote / 'android-control.sh'
            control.write_text((ROOT / 'android-control.sh').read_text())
            (remote / 'CANCEL').touch()
            native = remote / 'native-frame'
            native.write_text('#!/bin/sh\ntouch "' + str(remote / 'UNEXPECTED_LAUNCH') + '"\n')
            native.chmod(0o700)
            result = subprocess.run(['sh', str(control), 'run'], capture_output=True,
                                    text=True, timeout=8)
            self.assertEqual(result.returncode, 90)
            self.assertFalse((remote / 'UNEXPECTED_LAUNCH').exists())
            self.assertFalse((remote / 'control.lock').exists())

    def test_remote_control_retires_only_verified_native(self):
        self.remote_control_case(False)

    def test_remote_identity_mismatch_preserves_native_and_evidence(self):
        self.remote_control_case(True)

    def remote_control_case(self, mismatch):
        # Substitute only /proc path in the shell fixture; run its actual identity,
        # TERM, bounded retirement and acknowledgement branches against a real sleep.
        with tempfile.TemporaryDirectory() as tmp:
            remote = Path(tmp)
            proc = remote / 'proc'
            proc.mkdir()
            control = remote / 'android-control.sh'
            control.write_text((ROOT / 'android-control.sh').read_text().replace('proc_root=/proc',
                                                                               'proc_root=' + str(proc)))
            native = remote / 'native-frame'
            shutil.copyfile('/bin/sleep', native)
            native.chmod(0o700)
            p = subprocess.Popen([str(native), '60'])
            identity = proc / str(p.pid)
            identity.mkdir()
            # stat fields after the parenthesized comm: field20 is starttime.
            (identity / 'stat').write_text(str(p.pid) + ' (native-frame) ' + ' '.join(['0'] * 19 + ['123']) + '\n')
            (identity / 'cmdline').write_bytes((str(native) + '\0' + '60\0').encode())
            (remote / 'native.identity').write_text(str(p.pid) + (' 999\n' if mismatch else ' 123\n'))
            def reap():
                p.wait()
                shutil.rmtree(identity)
            watcher = threading.Thread(target=reap)
            watcher.start()
            try:
                result = subprocess.run(['sh', str(control), 'cleanup'], capture_output=True,
                                        text=True, timeout=8)
                if mismatch:
                    self.assertEqual(result.returncode, 90)
                    self.assertIn('UNKNOWN', result.stdout)
                    self.assertTrue(alive(p.pid))
                    self.assertTrue((remote / 'native.identity').exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(result.stdout.strip(), 'RETIRED')
                    self.assertFalse(alive(p.pid))
                self.assertTrue((remote / 'CANCEL').exists())
                self.assertFalse((remote / 'control.lock').exists())
            finally:
                if p.poll() is None:
                    p.terminate()
                watcher.join(timeout=5)
                self.assertFalse(watcher.is_alive())


if __name__ == '__main__':
    unittest.main()

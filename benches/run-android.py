#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run one native frame sample; retain recovery evidence when cleanup is unknown."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid


class Interrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def interrupted(signum, _frame):
    raise Interrupted(signum)


def command(args, *, capture=False, timeout=120, env=None):
    """Every local command owns a process group, including transport descendants."""
    process = subprocess.Popen(args, stdout=subprocess.PIPE if capture else None,
                               text=True, start_new_session=True, env=env)
    try:
        stdout, _ = process.communicate(timeout=timeout)
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, args, stdout)
        return stdout
    finally:
        # Even an exited launcher may have left a helper in its owned group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def mutation(scratch, record, name, args, **options):
    # Persist before dispatch. Losing transport or interruption does not prove the
    # remote mutation finished, even if later instantaneous reads report absence.
    record['pendingMutation'] = name
    (scratch / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
    result = command(args, **options)
    record['pendingMutation'] = None
    (scratch / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
    return result


def cleanup(scratch, record):
    serial, remote = record['serial'], record['remote']
    try:
        if record['remoteMayExist']:
            if record.get('pendingMutation', 'legacy completion state unavailable') is not None:
                raise RuntimeError('remote mutation completion unproved: ' + str(record.get('pendingMutation', 'legacy state')))
            # Never interpret failed transport, absent output or a malformed response as retirement.
            presence = command(['adb', '-s', serial, 'shell',
                                'if [ ! -e ' + shlex.quote(remote) + ' ]; then echo ABSENT; else echo PRESENT; fi'],
                               capture=True, timeout=15).strip()
            if presence not in ('ABSENT', 'PRESENT'):
                raise RuntimeError('remote scratch observation unavailable')
            if presence == 'PRESENT':
                owner = command(['adb', '-s', serial, 'shell', 'cat', remote + '/owner'],
                                capture=True, timeout=15).strip()
                if owner != record['ownerToken']:
                    raise RuntimeError('remote directory ownership mismatch')
                output = mutation(scratch, record, 'retirement',
                                  ['adb', '-s', serial, 'shell', 'sh', remote + '/android-control.sh',
                                   'cleanup'], capture=True, timeout=15)
                if output.strip() != 'RETIRED':
                    raise RuntimeError('remote retirement acknowledgement unavailable')
                mutation(scratch, record, 'scratch-removal',
                         ['adb', '-s', serial, 'shell', 'rm', '-rf', remote], timeout=15)
            output = command(['adb', '-s', serial, 'shell',
                              'if [ ! -e ' + shlex.quote(remote) + ' ]; then echo ABSENT; else echo PRESENT; fi'],
                             capture=True, timeout=15)
            if output.strip() != 'ABSENT':
                raise RuntimeError('remote scratch removal unproved')
        shutil.rmtree(scratch)
        return True
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        record['cleanup'] = 'UNKNOWN'
        record['cleanupError'] = str(error)
        (scratch / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
        print('CLEANUP_HOLD UNKNOWN: ownership retained at ' + str(scratch / 'ownership.json'), file=sys.stderr)
        if record.get('pendingMutation', 'legacy state') is not None:
            print('Mutation completion is unproved; absence alone cannot release this hold. '
                  'Retain ownership until separate quiescence evidence is established.', file=sys.stderr)
        print('Retry preserves any unresolved mutation hold: python3 ' + shlex.quote(str(Path(__file__).resolve()))
              + ' --cleanup-only ' + shlex.quote(str(scratch)), file=sys.stderr)
        return False


def main():
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    if len(sys.argv) == 3 and sys.argv[1] == '--cleanup-only':
        scratch = Path(sys.argv[2]).resolve()
        record = json.loads((scratch / 'ownership.json').read_text())
        if (not scratch.name.startswith('oscillux-bench.')
                or record['remote'] != '/data/local/tmp/' + scratch.name):
            raise ValueError('invalid benchmark recovery identity')
        return 0 if cleanup(scratch, record) else 90
    if len(sys.argv) not in (2, 3):
        raise SystemExit('usage: benches/run-android.sh PRODUCER_CHECKOUT [EXISTING_SERIAL]')
    root = Path(__file__).resolve().parent.parent
    producer = Path(sys.argv[1]).resolve()
    serial = sys.argv[2] if len(sys.argv) == 3 else 'emulator-5556'
    library = producer / 'target/artifacts/aarch64-linux-android/release/liboscillux.so'
    source = json.loads((producer / 'dist/manifest.json').read_text())['build']['sourceRevision']
    digest = hashlib.sha256(library.read_bytes()).hexdigest()
    ndk = Path(os.environ.get('ANDROID_NDK_HOME', '/opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358'))
    compiler = ndk / 'toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang'
    scratch = Path(tempfile.mkdtemp(prefix='oscillux-bench.'))
    record = dict(serial=serial, remote='/data/local/tmp/' + scratch.name,
                  remoteMayExist=False, source=source, librarySha256=digest,
                  localController=os.getpid(), ownerToken=uuid.uuid4().hex, cleanup='PENDING',
                  pendingMutation=None)
    status = 1
    try:
        (scratch / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
        (scratch / 'owner').write_text(record['ownerToken'] + '\n')
        shutil.copyfile(root / 'benches/android-control.sh', scratch / 'android-control.sh')
        command([str(compiler), '-O3', '-std=c11', '-Wall', '-Wextra', '-Werror',
                 '-I', str(root / 'ffi/include'), '-DOSCILLUX_SOURCE="' + source + '"',
                 '-DOSCILLUX_LIBRARY_SHA256="' + digest + '"', str(root / 'benches/native-frame.c'),
                 '-L', str(library.parent), '-loscillux', '-Wl,-rpath,$ORIGIN', '-lm',
                 '-o', str(scratch / 'native-frame')])
        remote = record['remote']
        # Set before transport: failure can mean the directory was created but reply was lost.
        record['remoteMayExist'] = True
        (scratch / 'ownership.json').write_text(json.dumps(record, indent=2) + '\n')
        mutation(scratch, record, 'mkdir', ['adb', '-s', serial, 'shell', 'mkdir', remote])
        mutation(scratch, record, 'push', ['adb', '-s', serial, 'push', str(scratch / 'native-frame'),
                 str(scratch / 'android-control.sh'), str(scratch / 'owner'), str(library), remote + '/'], capture=True)
        mutation(scratch, record, 'chmod', ['adb', '-s', serial, 'shell', 'chmod', '700', remote + '/native-frame',
                 remote + '/android-control.sh'])
        command(['adb', '-s', serial, 'shell', 'sh', remote + '/android-control.sh', 'run'])
        status = 0
    except Interrupted as error:
        status = 128 + error.signum
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
    finally:
        # Finish a single bounded retirement attempt even if the user signals again.
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        if not cleanup(scratch, record):
            status = 90
    return status


if __name__ == '__main__':
    raise SystemExit(main())

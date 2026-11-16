#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Platform gate: link every shipped Apple and Android library, load the npm package, and run
conformance vectors on the slices this host can execute (docs/packaging.md, "Platform gate").

1. Builds `make artifacts ARTIFACT_TARGETS=apple,android,wasm` at the clean HEAD (or, with
   --reuse-dist, accepts an existing dist/manifest.json for exactly HEAD) and checks every
   archive against the manifest's SHA-256.
2. Links packaging/smoke/conformance_smoke.c against every XCFramework slice and AAR ABI.
3. Runs it, with all DSP fixtures (bit-exact output digests) and the region flash sequences,
   natively on macOS arm64 (the only macOS slice: Intel Macs are not supported), on an iOS and a
   tvOS simulator, and on an arm64-v8a Android emulator; runs AdapterSmoke through the AAR's
   classes.jar and JNI glue on that emulator; and runs the portable Rust conformance suites (the
   test-wasi list) on the simulators and the emulator.
4. Runs tools/test-wasm-package.mjs against the unpacked npm archive under Node.
5. With --windows-host HOST (an x64 Windows PC's WSL shell over ssh), builds oscillux.dll and the
   portable Rust suites for x86_64-pc-windows-msvc with the pinned rustc here and MSVC link.exe on
   HOST (tools/msvc-remote-link.py), builds the C harness there with cl.exe, and runs it and the
   suites natively on Windows; aarch64-pc-windows-msvc is linked when HOST has the MSVC ARM64
   tools and fails naming what is missing otherwise. Without --windows-host the leg is recorded
   NOT EXECUTED. Nothing is installed on HOST; its work directory under %TEMP% is removed on exit.

Device slices are linked only: no device is attached. armeabi-v7a runs only if the emulator
lists that ABI, which an arm64 emulator on Apple Silicon (no AArch32) does not. The gate creates its own simulator devices and AVD, never touches existing ones,
downloads nothing, and shuts down and deletes what it created on exit, SIGINT, SIGTERM and SIGHUP.
Any failure, or a required runtime that is missing, fails the gate; nothing is skipped silently.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import zipfile

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'target/platform-gate'
SMOKE = ROOT / 'packaging/smoke/conformance_smoke.c'
SYSTEM_IMAGE = 'system-images;android-34;aosp_atd;arm64-v8a'
DEVICE_DIR = '/data/local/tmp/oscillux-platform-gate'
# Deployment minimums for the harness; the Rust slices use the rustc defaults, which are lower.
APPLE_MINIMUM = {'macos': '11.0', 'ios': '14.0', 'tvos': '14.0'}
ANDROID_CLANG = {'arm64-v8a': 'aarch64-linux-android21-clang',
                 'armeabi-v7a': 'armv7a-linux-androideabi21-clang'}
# The exact slices and ABIs a release must ship; a missing or unexpected one fails the gate.
EXPECTED_APPLE = {('ios-arm64', 'arm64'), ('ios-arm64-simulator', 'arm64'), ('macos-arm64', 'arm64'),
                  ('tvos-arm64', 'arm64'), ('tvos-arm64-simulator', 'arm64')}
EXPECTED_ABIS = set(ANDROID_CLANG)
# Signals that end the gate; each one runs cleanup before exit.
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
RUST_TARGETS = {'ios': 'aarch64-apple-ios-sim', 'tvos': 'aarch64-apple-tvos-sim',
                'android': 'aarch64-linux-android'}
WINDOWS_TARGETS = {'x86_64': 'x86_64-pc-windows-msvc', 'aarch64': 'aarch64-pc-windows-msvc'}
# Starts every Windows host script on a Windows drive, where cmd.exe accepts the working directory
# without a UNC warning, with $temp set to the WSL path of the Windows %TEMP%.
WINDOWS_TEMP = r'''cd /mnt/c
temp=$(wslpath -u "$(/mnt/c/Windows/System32/cmd.exe /c 'echo %TEMP%' </dev/null | tr -d '\r')")
'''


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


llvm = load('cargo_llvm', 'cargo-llvm.py')
wasi = load('test_wasi', 'test-wasi.py')
jni = load('jni_smoke', 'jni-smoke.py')
msvc = load('msvc_remote_link', 'msvc-remote-link.py')


class GateFailure(RuntimeError):
    pass


def run(*args, capture=False, timeout=None, check=True, **kwargs):
    args = [str(a) for a in args]
    print('+ ' + ' '.join(args), flush=True)
    result = subprocess.run(args, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT if capture else None, text=True,
                            timeout=timeout, **kwargs)
    if capture and result.stdout:
        print(result.stdout, end='' if result.stdout.endswith('\n') else '\n', flush=True)
    if check and result.returncode != 0:
        raise GateFailure(f'exit {result.returncode}: {" ".join(args)}')
    return result


def output(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, stdout=subprocess.PIPE, text=True,
                          **kwargs).stdout.strip()


def expect_exact(kind, found, expected):
    """Raises GateFailure unless found is exactly expected; returns the sorted set as text."""
    missing, unexpected = sorted(expected - found), sorted(found - expected)
    if missing or unexpected:
        raise GateFailure(f'{kind}: missing {missing or "none"}, unexpected {unexpected or "none"}')
    return ', '.join('/'.join(entry) if isinstance(entry, tuple) else entry for entry in sorted(found))


class Gate:
    """Records each slice's link and execution result and owns cleanup of created state."""

    def __init__(self):
        self.rows = []
        self.cleanups = []

    def record(self, slice_, check, status, detail=''):
        self.rows.append((slice_, check, status, detail))
        print(f'== {slice_}: {check}: {status} {detail}'.rstrip(), flush=True)

    def attempt(self, slice_, check, action):
        """Runs action and records PASS with its text result, or FAIL; returns its result."""
        try:
            result = action()
        except (GateFailure, subprocess.SubprocessError, OSError, RuntimeError) as error:
            self.record(slice_, check, 'FAIL', str(error))
            return None
        self.record(slice_, check, 'PASS', result if isinstance(result, str) else '')
        return result if result is not None else True

    def on_exit(self, description, action):
        self.cleanups.append((description, action))

    def cleanup(self):
        while self.cleanups:
            description, action = self.cleanups.pop()
            try:
                print(f'cleanup: {description}', flush=True)
                action()
            except Exception as error:  # Keep cleaning up; report what remains.
                print(f'cleanup failed: {description}: {error}', file=sys.stderr, flush=True)

    def summary(self):
        print('\nplatform gate summary')
        for slice_, check, status, detail in self.rows:
            print(f'  {status:<12} {slice_:<34} {check}{" (" + detail + ")" if detail else ""}')
        # NOT EXECUTED marks an opt-in leg that was not requested; it is listed, never hidden.
        return all(status in ('PASS', 'LINK ONLY', 'NOT EXECUTED') for _, _, status, _ in self.rows)


# ---- artifacts -------------------------------------------------------------------------------

def artifacts(env, reuse):
    head = output('git', 'rev-parse', 'HEAD', cwd=ROOT)
    if not reuse:
        run(sys.executable, ROOT / 'tools/artifacts.py', '--targets', 'apple,android,wasm', cwd=ROOT, env=env)
    manifest = json.loads((ROOT / 'dist/manifest.json').read_text())
    build = manifest['build']
    if build['sourceRevision'] != head or build['sourceDirty']:
        raise GateFailure(f'dist/manifest.json is for {build["sourceRevision"]}, not clean HEAD {head}')
    if not {'apple', 'android', 'wasm'} <= set(manifest['selectedTargets']):
        raise GateFailure('dist/manifest.json does not cover apple, android and wasm')
    files = {}
    for entry in manifest['artifacts']:
        path = ROOT / 'dist' / entry['file']
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise GateFailure(f'{entry["file"]} does not match its manifest checksum')
        files[entry['file']] = path
    for name in ('oscillux-xcframework.zip', 'oscillux.aar', 'oscillux-wasm.tgz'):
        if name not in files:
            raise GateFailure(f'manifest lists no {name}')
    return files, head


def unpack(archive, destination):
    shutil.rmtree(destination, ignore_errors=True)
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(destination)
    return destination


def vectors():
    """Flattens conformance/dsp for conformance_smoke.c, with the digests and tolerances the
    Rust conformance test records, and the region sequences as tools/jni-smoke.py flattens them."""
    test = (ROOT / 'crates/oscillux-core/tests/dsp_conformance.rs').read_text()
    constants = {}
    for line in test.splitlines():
        if line.startswith('const TOL_'):
            name, value = line[len('const '):].split(':')[0], line.split('=')[1].strip(' ;')
            constants[name] = float(value)
    if constants.get('TOL_SCALAR') != constants.get('TOL_SPECTRUM'):
        raise GateFailure('conformance_smoke uses one tolerance for scalars and spectrum')
    fixtures = []
    for line in test.splitlines():
        line = line.strip()
        if line.startswith('fixture!("'):
            fields = [f.strip(' ")') for f in line[len('fixture!('):].rstrip(',').split(',')]
            rate = int(fields[2].replace('_', '')) if len(fields) > 2 else 48000
            fixtures.append((fields[0], int(fields[1].replace('_', ''), 16), rate))
    if len(fixtures) < 8:
        raise GateFailure('expected the eight recorded DSP fixtures')
    lines = [f'tolerance {constants["TOL_TIME_MS"]!r} {constants["TOL_SCALAR"]!r}']
    for name, digest, rate in fixtures:
        samples = wav_samples(ROOT / f'conformance/dsp/{name}.wav', rate)
        frames = (ROOT / f'conformance/dsp/{name}.frames').read_text().splitlines()
        rows = [l.split() for l in frames if l.split()[:1] == ['frame']]
        chunks = [l.split()[1:] for l in frames if l.split()[:1] == ['chunk']] or [['0', '0', str(len(samples)), '0']]
        lines.append(f'dsp {name} {rate} 0x{digest:016x} {len(samples)}')
        lines.extend(' '.join(map(str, samples[i:i + 32])) for i in range(0, len(samples), 32))
        for start, begin, end, stall in chunks:
            lines.append(f'segment {start} {stall} {begin} {end}')
        lines.append(f'expect {len(rows)}')
        lines.extend(' '.join([row[1], row[2], str(len(row) - 3)] + row[3:]) for row in rows)
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / 'dsp-vectors.txt').write_text('\n'.join(lines) + '\n')
    jni.region_fixture(WORK / 'region-vectors.txt')
    return WORK / 'dsp-vectors.txt', WORK / 'region-vectors.txt'


def wav_samples(path, rate):
    """Signed 16-bit mono PCM samples; conformance_smoke divides by 32768 as decode_wav_mono does."""
    data = path.read_bytes()
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise GateFailure(f'{path.name} is not RIFF/WAVE')
    offset, fmt, pcm = 12, None, None
    while offset + 8 <= len(data):
        tag, size = data[offset:offset + 4], int.from_bytes(data[offset + 4:offset + 8], 'little')
        body = data[offset + 8:offset + 8 + size]
        if tag == b'fmt ':
            fmt = body
        elif tag == b'data':
            pcm = body
        offset += 8 + size + size % 2
    channels, sample_rate = int.from_bytes(fmt[2:4], 'little'), int.from_bytes(fmt[4:8], 'little')
    bits = int.from_bytes(fmt[14:16], 'little')
    if (channels, sample_rate, bits) != (1, rate, 16):
        raise GateFailure(f'{path.name}: expected mono 16-bit {rate} Hz')
    return [int.from_bytes(pcm[i:i + 2], 'little', signed=True) for i in range(0, len(pcm) - 1, 2)]


# ---- Apple -----------------------------------------------------------------------------------

def apple_slices(framework):
    info = plistlib.loads((framework / 'Info.plist').read_bytes())
    for library in info['AvailableLibraries']:
        identifier = library['LibraryIdentifier']
        yield (identifier, library['SupportedPlatform'], library.get('SupportedPlatformVariant'),
               library['SupportedArchitectures'], framework / identifier / library['LibraryPath'])


def apple_link(identifier, system, variant, arch, library):
    sdk = {('macos', None): 'macosx', ('ios', None): 'iphoneos', ('ios', 'simulator'): 'iphonesimulator',
           ('tvos', None): 'appletvos', ('tvos', 'simulator'): 'appletvsimulator'}.get((system, variant))
    if sdk is None:
        raise GateFailure(f'{identifier}: no harness recipe for {system}/{variant}')
    sysroot = output('xcrun', '--sdk', sdk, '--show-sdk-path')
    target = f'{arch}-apple-{system}{APPLE_MINIMUM[system]}' + ('-simulator' if variant else '')
    executable = WORK / 'bin' / f'conformance-{identifier}-{arch}'
    executable.parent.mkdir(parents=True, exist_ok=True)
    run(output('xcrun', '--find', 'clang'), f'--target={target}', '-isysroot', sysroot, '-std=c11',
        '-O1', '-Wall', '-Werror', '-I', library.parent / 'Headers', SMOKE, library, '-o', executable)
    return executable


# ---- simulators ------------------------------------------------------------------------------

def simulator(gate, system):
    runtimes = json.loads(output('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    name = {'ios': 'iOS', 'tvos': 'tvOS'}[system]
    available = [r for r in runtimes if r['platform'] == name and r['isAvailable'] and r.get('supportedDeviceTypes')]
    if not available:
        raise GateFailure(f'no installed {name} simulator runtime; the gate does not download one')
    chosen = max(available, key=lambda r: [int(p) for p in r['version'].split('.')])
    device_type = chosen['supportedDeviceTypes'][0]['identifier']
    device_name = f'oscillux-platform-gate-{system}-{os.getpid()}'
    # Registered by name before create, so an interrupt during create still removes the device.
    gate.on_exit(f'shut down and delete simulator {device_name}', lambda: delete_simulators(device_name))
    udid = output('xcrun', 'simctl', 'create', device_name, device_type, chosen['identifier'])
    run('xcrun', 'simctl', 'bootstatus', udid, '-b', timeout=600)
    return udid, f'{chosen["name"]} {device_type.rsplit(".", 1)[-1]}'


def delete_simulators(name):
    devices = json.loads(output('xcrun', 'simctl', 'list', 'devices', '-j'))['devices']
    for udid in [d['udid'] for group in devices.values() for d in group if d['name'] == name]:
        run('xcrun', 'simctl', 'shutdown', udid, check=False)
        run('xcrun', 'simctl', 'delete', udid, check=False)


def simctl_run(udid, executable, *args):
    result = run('xcrun', 'simctl', 'spawn', udid, executable, *args, capture=True, timeout=900)
    return result.stdout


# ---- Android ---------------------------------------------------------------------------------

def android_sdk():
    home = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not home:
        raise GateFailure('set ANDROID_HOME (SDK with emulator, platform-tools and cmdline-tools)')
    return Path(home)


def ndk_clang(abi):
    ndk = os.environ.get('ANDROID_NDK_HOME')
    if not ndk:
        raise GateFailure('set ANDROID_NDK_HOME')
    host = 'darwin-x86_64' if platform.system() == 'Darwin' else 'linux-x86_64'
    return Path(ndk) / 'toolchains/llvm/prebuilt' / host / 'bin' / ANDROID_CLANG[abi]


def android_link(abi, aar):
    executable = WORK / 'bin' / f'conformance-android-{abi}'
    executable.parent.mkdir(parents=True, exist_ok=True)
    run(ndk_clang(abi), '-std=c11', '-O1', '-Wall', '-Werror', '-I', aar / 'headers', SMOKE,
        '-L', aar / 'jni' / abi, '-loscillux', '-lm', '-o', executable)
    return executable


class Emulator:
    def __init__(self, gate, sdk, port):
        self.sdk, self.port, self.serial = sdk, port, f'emulator-{port}'
        self.adb = shutil.which('adb') or str(sdk / 'platform-tools/adb')
        image = sdk / Path(*SYSTEM_IMAGE.split(';'))
        if not image.is_dir():
            raise GateFailure(f'{SYSTEM_IMAGE} is not installed; the gate does not download it')
        if self.serial in output(self.adb, 'devices'):
            raise GateFailure(f'{self.serial} is already in use; set PLATFORM_GATE_EMULATOR_PORT')
        home = os.environ.get('ANDROID_AVD_HOME') or str(WORK / 'avd')
        Path(home).mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ, ANDROID_AVD_HOME=home, ANDROID_SDK_ROOT=str(sdk), ANDROID_HOME=str(sdk))
        self.name = f'oscillux-platform-gate-{os.getpid()}'
        avdmanager = sdk / 'cmdline-tools/latest/bin/avdmanager'
        gate.on_exit(f'delete AVD {self.name}', self.delete)
        run(avdmanager, 'create', 'avd', '-n', self.name, '-k', SYSTEM_IMAGE, input='no\n',
            env=self.env, timeout=300)
        log = (WORK / 'emulator.log').open('w')
        self.process = None
        gate.on_exit(f'stop emulator {self.serial}', self.stop)
        # Block the gate's signals until self.process is set, so stop() always sees the emulator;
        # the child unblocks them before exec.
        signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
        try:
            self.process = subprocess.Popen(
                [str(sdk / 'emulator/emulator'), '-avd', self.name, '-port', str(port), '-no-window',
                 '-no-audio', '-no-boot-anim', '-no-snapshot', '-no-metrics', '-gpu', 'swiftshader_indirect'],
                env=self.env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, SIGNALS))
        finally:
            signal.pthread_sigmask(signal.SIG_UNBLOCK, SIGNALS)
        self.wait_for_boot()

    def wait_for_boot(self):
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise GateFailure(f'emulator exited {self.process.returncode}; see {WORK / "emulator.log"}')
            state = subprocess.run([self.adb, '-s', self.serial, 'shell', 'getprop', 'sys.boot_completed'],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            if state.stdout.strip() == '1':
                return
            time.sleep(3)
        raise GateFailure(f'{self.serial} did not finish booting in 600 s')

    def shell(self, command, timeout=900):
        # adb shell returns the remote exit status.
        return run(self.adb, '-s', self.serial, 'shell', command, capture=True, timeout=timeout).stdout

    def push(self, *paths):
        run(self.adb, '-s', self.serial, 'push', *paths, DEVICE_DIR + '/', capture=True, timeout=600)

    def stop(self):
        if self.process is None:
            return
        try:
            subprocess.run([self.adb, '-s', self.serial, 'emu', 'kill'], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
        except (subprocess.SubprocessError, OSError) as error:
            print(f'cleanup: adb emu kill failed: {error}', file=sys.stderr, flush=True)
        finally:
            # Always reap the emulator, killing its process group if adb could not stop it.
            try:
                self.process.wait(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=60)

    def delete(self):
        avdmanager = self.sdk / 'cmdline-tools/latest/bin/avdmanager'
        run(avdmanager, 'delete', 'avd', '-n', self.name, env=self.env, check=False, timeout=300)
        home = Path(self.env['ANDROID_AVD_HOME'])
        shutil.rmtree(home / f'{self.name}.avd', ignore_errors=True)
        (home / f'{self.name}.ini').unlink(missing_ok=True)


def adapter_smoke_dex(sdk, aar):
    """AdapterSmoke compiled against the shipped classes.jar and dexed with it for dalvikvm."""
    classes = WORK / 'adapter-classes'
    shutil.rmtree(classes, ignore_errors=True)
    classes.mkdir(parents=True)
    run('javac', '--release', '11', '-cp', aar / 'classes.jar', '-d', classes,
        ROOT / 'packaging/android/AdapterSmoke.java')
    build_tools = sorted((sdk / 'build-tools').iterdir(), key=lambda p: [int(x) for x in p.name.split('.') if x.isdigit()])
    dex = WORK / 'adapter-dex'
    shutil.rmtree(dex, ignore_errors=True)
    dex.mkdir()
    run(build_tools[-1] / 'd8', '--min-api', '34', '--output', dex, aar / 'classes.jar',
        *sorted(classes.rglob('*.class')))
    return dex / 'classes.dex'


# ---- Rust suites -----------------------------------------------------------------------------

def rust_tests(cargo, env, target):
    """Builds the test-wasi portable suites for target and returns their executables."""
    command = [cargo, 'test', '--workspace', '--lib', '--target', target, '--offline', '--no-run',
               '--message-format=json-render-diagnostics']
    for test in wasi.PORTABLE:
        command += ['--test', test]
    print('+ ' + ' '.join(command), flush=True)
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise GateFailure(f'cargo test --no-run --target {target} exited {result.returncode}')
    executables = []
    for line in result.stdout.splitlines():
        message = json.loads(line)
        if message.get('reason') == 'compiler-artifact' and message.get('executable') and message['profile']['test']:
            executables.append(Path(message['executable']))
    if len(executables) < len(wasi.PORTABLE):
        raise GateFailure(f'{target}: expected at least {len(wasi.PORTABLE)} test executables')
    return executables


def count_passed(text):
    passed = 0
    for line in text.splitlines():
        if line.startswith('test result: ok.'):
            passed += int(line.split()[3])
        elif line.startswith('test result:'):
            raise GateFailure(line)
    return passed


# ---- Windows ---------------------------------------------------------------------------------

class WindowsHost:
    """A Windows PC reached over ssh into its WSL shell, which runs Windows programs through
    interop. The gate's work directory there, under the Windows %TEMP%, is removed on exit."""

    def __init__(self, gate, host):
        self.host, name = host, f'oscillux-platform-gate-{os.getpid()}'
        # Registered by name before the directory exists, so an interrupt still removes it.
        gate.on_exit(f'remove %TEMP%\\{name} on {host}', lambda: self.shell(f'rm -rf "$temp/{name}"', timeout=300))
        self.dir = self.shell(f'mkdir -p "$temp/{name}" && echo "$temp/{name}"').strip().splitlines()[-1]
        self.work, self.studio, _ = msvc.probe(host, self.dir + '/link')
        tools, version, arch = self.shell(
            f'studio=$(wslpath -u {shlex.quote(self.studio)})\n'
            'tr -d "\\r\\n " < "$studio/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"; echo\n'
            '/mnt/c/Windows/System32/cmd.exe /c ver </dev/null | tr -d "\\r" | grep -o "[0-9][0-9.]*[0-9]"\n'
            "/mnt/c/Windows/System32/cmd.exe /c 'echo %PROCESSOR_ARCHITECTURE%' </dev/null | tr -d '\\r'\n"
        ).split()[-3:]
        self.tools, self.device = tools, f'Windows {version} {arch}'

    def shell(self, script, stdin=None, timeout=900):
        """Runs a bash script on the host with $temp set to the Windows %TEMP%; returns its output."""
        print(f'+ [{self.host}] ' + script.strip().splitlines()[0], flush=True)
        result = subprocess.run([*msvc.SSH, self.host, 'bash -c ' + shlex.quote(msvc.PRELUDE + WINDOWS_TEMP + script)],
                                input=stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        text = result.stdout.decode(errors='replace').replace('\r', '')
        if text:
            print(text, end='' if text.endswith('\n') else '\n', flush=True)
        if result.returncode != 0:
            raise GateFailure(f'exit {result.returncode} on {self.host}: {script.strip().splitlines()[0]}')
        return text

    def push(self, into, *paths, extra=()):
        """Copies local files, and (name, bytes) pairs, into a fresh directory under the work directory."""
        upload = io.BytesIO()
        with tarfile.open(fileobj=upload, mode='w') as archive:
            for path in paths:
                archive.add(path, arcname=Path(path).name, recursive=False)
            for name, data in extra:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        target = shlex.quote(f'{self.dir}/{into}')
        self.shell(f'rm -rf {target} && mkdir -p {target} && tar -xf - -C {target}', stdin=upload.getvalue())
        return f'{self.dir}/{into}'

    def missing_arm64(self):
        """The MSVC ARM64 library and tool directories this Visual Studio lacks."""
        base = f'{self.studio}\\VC\\Tools\\MSVC\\{self.tools}'
        wanted = [f'{base}\\lib\\arm64', f'{base}\\bin\\Hostx64\\arm64']
        found = self.shell(''.join(f'[ -d "$(wslpath -u {shlex.quote(d)})" ] && echo {shlex.quote(d)}\n' for d in wanted) + 'true\n')
        return [d for d in wanted if d not in found.splitlines()]


def windows_environment(env, host):
    # A target directory of its own, emptied first, so every link in the leg runs on the host.
    shutil.rmtree(WORK / 'windows-target', ignore_errors=True)
    windows_env = dict(env, CARGO_TARGET_DIR=str(WORK / 'windows-target'), OSCILLUX_WINDOWS_HOST=host.host,
                       OSCILLUX_WINDOWS_WORKDIR=host.dir + '/link')
    for target in WINDOWS_TARGETS.values():
        windows_env[f'CARGO_TARGET_{target.upper().replace("-", "_")}_LINKER'] = str(ROOT / 'tools/msvc-remote-link.py')
    return windows_env


def windows_library(cargo, env, target):
    """Builds oscillux-ffi for target, as tools/artifacts.py does; returns oscillux.dll and its import library."""
    command = [cargo, 'build', '--locked', '--release', '--target', target, '-p', 'oscillux-ffi', '--offline',
               '--message-format=json-render-diagnostics']
    print('+ ' + ' '.join(map(str, command)), flush=True)
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, text=True, timeout=1800)
    if result.returncode != 0:
        raise GateFailure(f'cargo build --target {target} -p oscillux-ffi exited {result.returncode}')
    files = {}
    for line in result.stdout.splitlines():
        message = json.loads(line)
        if message.get('reason') == 'compiler-artifact' and message['target']['name'] == 'oscillux':
            files.update({Path(f).name: Path(f) for f in message['filenames']})
    if not {'oscillux.dll', 'oscillux.dll.lib'} <= set(files):
        raise GateFailure(f'{target}: cargo produced no oscillux.dll and oscillux.dll.lib')
    return files['oscillux.dll'], files['oscillux.dll.lib']


def windows_leg(gate, cargo, env, host_name, dsp, region):
    if host_name is None:
        for target in WINDOWS_TARGETS.values():
            gate.record(f'windows {target}', 'link and execute', 'NOT EXECUTED', 'pass --windows-host HOST')
        return
    name = f'windows {WINDOWS_TARGETS["x86_64"]}'
    try:
        host = WindowsHost(gate, host_name)
    except (GateFailure, subprocess.SubprocessError, OSError, RuntimeError) as error:
        gate.record(name, f'reach Windows host {host_name}', 'FAIL', str(error))
        return
    windows_env = windows_environment(env, host)
    library = gate.attempt(name, f'link oscillux.dll (MSVC {host.tools} link.exe on {host_name})',
                           lambda: windows_library(cargo, windows_env, WINDOWS_TARGETS['x86_64']))
    if library is not None:
        def harness():
            remote = host.push('harness', *library, ROOT / 'ffi/include/oscillux.h', SMOKE, dsp, region,
                               extra=[('build.bat', msvc.batch(host.studio, 'x86_64', [
                                   'cd /d "%~dp0"', 'cl.exe /nologo /std:c11 /O1 /W3 /WX /D_CRT_SECURE_NO_WARNINGS '
                                   f'/I . {SMOKE.name} oscillux.dll.lib /Fe:conformance.exe']))])
            quoted = shlex.quote(remote)
            host.shell(f'/mnt/c/Windows/System32/cmd.exe /c "$(wslpath -w {quoted}/build.bat)" </dev/null')
            text = host.shell(f'cd {quoted} && ./conformance.exe {dsp.name} {region.name} </dev/null')
            return text.strip().splitlines()[-1]
        gate.attempt(name, f'execute C harness (cl.exe, {host.device})', harness)

    def suites():
        tests = rust_tests(cargo, windows_env, WINDOWS_TARGETS['x86_64'])
        remote = shlex.quote(host.push('rust', *tests))
        passed = 0
        for test in tests:
            passed += count_passed(host.shell(f'cd {remote} && ./{test.name} </dev/null'))
        return f'{passed} tests passed on {host.device}'
    gate.attempt(f'rust {WINDOWS_TARGETS["x86_64"]}', 'portable conformance suites', suites)

    name = f'windows {WINDOWS_TARGETS["aarch64"]}'
    missing = host.missing_arm64()
    if missing:
        gate.record(name, 'link oscillux.dll', 'FAIL', 'no MSVC ARM64 tools on the host: missing ' + ', '.join(missing))
        return
    if gate.attempt(name, f'link oscillux.dll (MSVC {host.tools} link.exe on {host_name})',
                    lambda: windows_library(cargo, windows_env, WINDOWS_TARGETS['aarch64'])) is not None:
        gate.record(name, 'execute', 'LINK ONLY', f'{host.device} host; no Windows ARM64 device attached to the gate')


# ---- main ------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('cargo', help='the selected cargo (make passes $(CARGO))')
    parser.add_argument('--reuse-dist', action='store_true',
                        help='accept dist/manifest.json built for exactly the clean HEAD instead of rebuilding')
    parser.add_argument('--windows-host', metavar='HOST',
                        help='ssh destination of a Windows PC\'s WSL shell for the Windows leg; '
                             'without it that leg is recorded NOT EXECUTED')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise GateFailure('the platform gate needs an Apple Silicon Mac with Xcode and the Android SDK')
    env = llvm.environment(args.cargo, os.environ, platform.system())
    sdk = android_sdk()
    gate = Gate()

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    for signum in SIGNALS:
        signal.signal(signum, interrupted)
    try:
        shutil.rmtree(WORK / 'bin', ignore_errors=True)
        files, head = artifacts(env, args.reuse_dist)
        gate.record('dist (apple,android,wasm)', 'manifest and checksums', 'PASS', head[:12])
        dsp, region = vectors()
        framework = unpack(files['oscillux-xcframework.zip'], WORK / 'apple') / 'Oscillux.xcframework'
        aar = unpack(files['oscillux.aar'], WORK / 'android')

        def npm():
            shutil.rmtree(WORK / 'npm', ignore_errors=True)
            with tarfile.open(files['oscillux-wasm.tgz']) as archive:
                members = archive.getmembers()
                for member in members:
                    parts = Path(member.name).parts
                    if not (member.isfile() or member.isdir()) or Path(member.name).is_absolute() or '..' in parts:
                        raise GateFailure(f'unexpected npm archive member {member.name}')
                # The checks above leave only plain files and directories; the 'data' filter (where
                # this Python has it) additionally strips setuid/special mode bits and owner info.
                archive.extractall(WORK / 'npm', members, **({'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}))
            node = run('node', ROOT / 'tools/test-wasm-package.mjs', WORK / 'npm/package', capture=True,
                       cwd=ROOT, timeout=600)
            return node.stdout.strip().splitlines()[-1] if node.stdout.strip() else 'exit 0'
        gate.attempt('npm (wasm32)', 'execute test-wasm-package.mjs (Node)', npm)

        slices = list(apple_slices(framework))
        gate.attempt('xcframework', 'expected slices', lambda: expect_exact(
            'XCFramework slices', {(s[0], arch) for s in slices for arch in s[3]}, EXPECTED_APPLE))
        aar_abis = sorted(p.name for p in (aar / 'jni').iterdir())
        gate.attempt('aar', 'expected ABIs', lambda: expect_exact('AAR ABIs', set(aar_abis), EXPECTED_ABIS))

        simulators = {}
        for identifier, system, variant, archs, library in slices:
            for arch in archs:
                name = f'xcframework {identifier} {arch}'
                executable = gate.attempt(name, 'link', lambda: apple_link(identifier, system, variant, arch, library))
                if executable is None:
                    continue
                if system == 'macos':
                    gate.attempt(name, 'execute (native)',
                                 lambda: run(executable, dsp, region, capture=True, timeout=900).stdout.strip())
                elif variant == 'simulator':
                    simulators[system] = executable
                else:
                    gate.record(name, 'execute', 'LINK ONLY', 'device slice; no device attached to the gate')

        for system, executable in sorted(simulators.items()):
            name = f'xcframework {system} simulator arm64'
            try:
                udid, device = simulator(gate, system)
            except (GateFailure, subprocess.SubprocessError) as error:
                gate.record(name, 'boot simulator', 'FAIL', str(error))
                continue
            gate.attempt(name, f'execute ({device})', lambda: simctl_run(udid, executable, dsp, region).strip())
            target = RUST_TARGETS[system]

            def suites():
                passed = 0
                for test in rust_tests(args.cargo, env, target):
                    passed += count_passed(simctl_run(udid, test))
                return f'{passed} tests passed on {device}'
            gate.attempt(f'rust {target}', 'portable conformance suites', suites)

        executables = {}
        for abi in aar_abis:
            if abi not in ANDROID_CLANG:
                gate.record(f'aar {abi}', 'link', 'FAIL', 'no harness recipe for this ABI')
                continue
            executables[abi] = gate.attempt(f'aar {abi}', 'link', lambda: android_link(abi, aar))

        name = 'aar arm64-v8a'
        try:
            emulator = Emulator(gate, sdk, int(os.environ.get('PLATFORM_GATE_EMULATOR_PORT', '5810')))
        except (GateFailure, subprocess.SubprocessError, OSError) as error:
            gate.record(name, 'boot emulator', 'FAIL', str(error))
        else:
            release = emulator.shell('getprop ro.build.version.release').strip()
            device = f'Android {release} {SYSTEM_IMAGE.split(";")[2]} emulator'
            abis = emulator.shell('getprop ro.product.cpu.abilist').strip().split(',')
            emulator.shell(f'rm -rf {DEVICE_DIR} && mkdir -p {DEVICE_DIR}')
            for abi, executable in sorted(executables.items()):
                if executable is None:
                    continue
                if abi not in abis:
                    # Apple Silicon has no AArch32, so no emulator here can run armeabi-v7a.
                    gate.record(f'aar {abi}', 'execute', 'LINK ONLY', f'{device} ABIs are {",".join(abis)}')
                    continue

                def harness():
                    emulator.shell(f'rm -rf {DEVICE_DIR} && mkdir -p {DEVICE_DIR}')
                    emulator.push(executable, aar / f'jni/{abi}/liboscillux.so', dsp, region)
                    return emulator.shell(f'cd {DEVICE_DIR} && LD_LIBRARY_PATH=. ./{executable.name} '
                                          f'{dsp.name} {region.name}').strip() + f' on {device}'
                gate.attempt(f'aar {abi}', 'execute C harness', harness)

            def adapter():
                emulator.shell(f'rm -rf {DEVICE_DIR} && mkdir -p {DEVICE_DIR}')
                dex = adapter_smoke_dex(sdk, aar)
                emulator.push(dex, aar / 'jni/arm64-v8a/liboscillux_jni.so', aar / 'jni/arm64-v8a/liboscillux.so',
                              region, ROOT / 'conformance')
                return emulator.shell(f'cd {DEVICE_DIR} && LD_LIBRARY_PATH=. dalvikvm -Xcheck:jni '
                                      f'-Djava.library.path=. -cp classes.dex AdapterSmoke {region.name}').strip()
            gate.attempt(name, 'execute AdapterSmoke (classes.jar + JNI)', adapter)

            def suites():
                rust_env = dict(env)
                rust_env['CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER'] = str(ndk_clang('arm64-v8a'))
                passed = 0
                for test in rust_tests(args.cargo, rust_env, RUST_TARGETS['android']):
                    emulator.push(test)
                    passed += count_passed(emulator.shell(f'cd {DEVICE_DIR} && ./{test.name}'))
                return f'{passed} tests passed on {device}'
            gate.attempt(f'rust {RUST_TARGETS["android"]}', 'portable conformance suites', suites)
            emulator.shell(f'rm -rf {DEVICE_DIR}')

        windows_leg(gate, args.cargo, env, args.windows_host, dsp, region)
    finally:
        # Cleanup must finish: a second interrupt would leave devices behind.
        for signum in SIGNALS:
            signal.signal(signum, signal.SIG_IGN)
        gate.cleanup()
    if not gate.summary():
        raise GateFailure('platform gate failed')
    print('platform gate: PASS')


if __name__ == '__main__':
    try:
        main()
    except (GateFailure, OSError, subprocess.SubprocessError, KeyError, ValueError) as error:
        print(f'platform-gate: {error}', file=sys.stderr)
        sys.exit(1)

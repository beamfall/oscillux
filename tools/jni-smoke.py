#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build the JNI glue against a host liboscillux and run AdapterSmoke on the host JVM."""
from pathlib import Path
import json
import os
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, cwd=ROOT, **kwargs)


def jdk_include():
    # The JDK that provides javac also provides jni.h; JAVA_HOME wins when set.
    home = os.environ.get('JAVA_HOME')
    if not home:
        javac = shutil.which('javac')
        if not javac:
            raise RuntimeError('jni-smoke requires javac on PATH or JAVA_HOME')
        home = Path(javac).resolve().parent.parent
    include = Path(home) / 'include'
    if not (include / 'jni.h').is_file():
        raise RuntimeError(f'no jni.h under {include}')
    native = include / ('darwin' if platform.system() == 'Darwin' else 'linux')
    return include, native


def target_dir(cargo):
    # Honour CARGO_TARGET_DIR and build.target-dir the same way the build below does.
    metadata = subprocess.run([cargo, 'metadata', '--format-version', '1', '--no-deps', '--offline'],
                              check=True, cwd=ROOT, stdout=subprocess.PIPE, text=True).stdout
    return Path(json.loads(metadata)['target_directory'])


def region_fixture(path):
    """Flattens conformance/limiter/region-sequences.json into whitespace-separated lines that
    AdapterSmoke parses without a JSON library. Values are repr()s, which round-trip doubles."""
    doc = json.loads((ROOT / 'conformance/limiter/region-sequences.json').read_text())
    keys = ('columns', 'rows', 'fieldWidth', 'fieldHeight', 'maxFieldArea', 'maxFlashHz', 'maxRedFlashes', 'redRule')
    report = ('admitted', 'general', 'red', 'generalRegions', 'redRegions', 'flashes', 'redFlashes', 'exceeds')
    number = lambda value: repr(float(value)) if not isinstance(value, bool) else str(int(value))
    lines = [f"tolerance {number(doc['tolerance'])}"]
    for case in doc['validation']:
        lines.append(' '.join(['validation', case['name'], 'ok' if case['error'] is None else 'error']
                              + [number(case['config'][k]) for k in keys]))
    for case in doc['cases']:
        config = case['config']
        count = config['columns'] * config['rows']
        lines.append(' '.join(['case', case['name'], case['mode']] + [number(config[k]) for k in keys]))
        assert len(case['frames']) == len(case['expected'])
        for frame, want in zip(case['frames'], case['expected']):
            assert frame['t'] == want['t']
            head = [number(frame['t']), number(bool(frame.get('reset')))]
            tail = [number(want[k]) for k in report]
            if 'rgb' in frame:
                # One [r, g, b] for every region, or one per region.
                rgb = frame['rgb'] if isinstance(frame['rgb'][0], list) else [frame['rgb']] * count
                assert len(rgb) == count
                lines.append(' '.join(['rgbframe'] + head + [number(v) for c in rgb for v in c] + tail))
                continue
            level = lambda key, i: (frame.get(key, 0)[i] if isinstance(frame.get(key, 0), list) else frame.get(key, 0))
            lines.append(' '.join(['frame'] + head
                                  + [number(level('luminance', i)) for i in range(count)]
                                  + [number(level('red', i)) for i in range(count)]
                                  + tail))
    for color in doc['colors']:
        lines.append(' '.join(['color'] + [number(v) for v in color['rgb'] + [color['luminance'], color['red']]]))
    for rgb in doc['invalidColors']:
        lines.append(' '.join(['invalid'] + [number(v) for v in rgb]))
    path.write_text('\n'.join(lines) + '\n')


def main():
    if len(sys.argv) != 2:
        raise RuntimeError('usage: jni-smoke.py /path/to/selected/cargo')
    cargo = sys.argv[1]
    include, native = jdk_include()
    run(cargo, 'build', '-p', 'oscillux-ffi', '--offline')
    target = target_dir(cargo)
    library = target / 'debug'
    out = target / 'jni-smoke'
    shutil.rmtree(out, ignore_errors=True)
    (out / 'classes').mkdir(parents=True)
    suffix = 'dylib' if platform.system() == 'Darwin' else 'so'
    cc = os.environ.get('CC', 'cc')
    run(cc, '-shared', '-fPIC', '-Wall', '-Werror', '-I', ROOT / 'ffi/include', '-I', include,
        '-I', native, ROOT / 'packaging/android/oscillux_jni.c', '-L', library, '-loscillux',
        f'-Wl,-rpath,{library}', '-o', out / f'liboscillux_jni.{suffix}')
    run('javac', '-d', out / 'classes', ROOT / 'packaging/android/Oscillux.java',
        ROOT / 'packaging/android/AdapterSmoke.java')
    # AdapterSmoke reads conformance/ relative to the repository root.
    region_fixture(out / 'region-sequences.txt')
    run('java', '-Xcheck:jni', f'-Djava.library.path={out}', '-cp', out / 'classes', 'AdapterSmoke',
        out / 'region-sequences.txt')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'jni-smoke: {error}', file=sys.stderr)
        sys.exit(1)

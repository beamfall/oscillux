#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run portable WASI tests with the selected compiler's process-local LLVM path."""
import os
from pathlib import Path
import importlib.util
import platform
import shutil
import subprocess
import sys

# The selected compiler's libLLVM loader path is shared with other cargo recipes (cargo-llvm.py).
_spec = importlib.util.spec_from_file_location('cargo_llvm', Path(__file__).with_name('cargo-llvm.py'))
llvm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(llvm)


# Integration tests that embed their fixtures and need no host process or repository files.
# Header tests spawn a host C compiler/read repository files and remain in make gate.
# tools/platform-gate.py runs the same list on the Apple simulators and the Android emulator.
PORTABLE = ('core2_early', 'core2_boundaries', 'core2_vectors', 'dsp_streaming',
            'dsp_conformance', 'dsp_beat', 'dsp_agc', 'limiter_vectors', 'limiter_safety',
            'limiter_properties', 'limiter_regions', 'core2_ffi', 'limiter_ffi', 'realtime_paths',
            'ffi_robustness', 'dsp_descriptors', 'reaction_vectors', 'beatgrid_vectors',
            'beatgrid_ffi', 'cdg_vectors', 'cdg_present', 'cdg_realtime', 'cdg_ffi',
            'window_governor_vectors', 'window_governor_ffi')


def environment(cargo, environ, system):
    env = llvm.environment(cargo, environ, system)
    # WASI test binaries must execute, not merely compile. No implicit installation.
    if not shutil.which('wasmtime', path=env['PATH']):
        raise RuntimeError('test-wasi requires wasmtime on PATH')
    env['CARGO_TARGET_WASM32_WASIP1_RUNNER'] = 'wasmtime'
    # The shipped oscillux-cdg-render.wasm is built with wasm SIMD (tools/artifacts.py); test the
    # same code generation.
    env['CARGO_TARGET_WASM32_WASIP1_RUSTFLAGS'] = '-C target-feature=+simd128'
    return env


def main():
    if len(sys.argv) != 2:
        raise RuntimeError('usage: test-wasi.py /path/to/selected/cargo')
    cargo = sys.argv[1]
    env = environment(cargo, os.environ, platform.system())
    # Replace the wrapper: no detached cargo process or controller to outlive it.
    command = [cargo, 'test', '--workspace', '--lib', '--target', 'wasm32-wasip1', '--offline']
    for test in PORTABLE:
        command.extend(['--test', test])
    os.execve(cargo, command, env)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'test-wasi: {error}', file=sys.stderr)
        sys.exit(1)

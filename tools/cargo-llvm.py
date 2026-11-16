#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Run the selected cargo with its compiler's libLLVM on the macOS loader path.

The macOS host toolchain's rust-objcopy (used for `strip`) and rust-lld load @rpath/libLLVM.dylib
from lib/rustlib/<host>/lib, but the dylib ships in <sysroot>/lib, so without this they abort and
release builds warn and keep debuginfo. make cannot
export DYLD_* itself: macOS drops them when it runs the SIP-protected /bin/sh."""
import os
from pathlib import Path
import subprocess
import sys


def environment(cargo, environ, system):
    env = dict(environ)
    # Match Cargo's compiler selection, including an explicit RUSTC override.
    env['PATH'] = str(Path(cargo).parent) + os.pathsep + env.get('PATH', '')
    rustc = env.get('RUSTC') or str(Path(cargo).with_name('rustc'))
    if system == 'Darwin':
        sysroot = subprocess.check_output([rustc, '--print', 'sysroot'], env=env, text=True).strip()
        lib = Path(sysroot) / 'lib'
        if not (lib / 'libLLVM.dylib').is_file():
            raise RuntimeError(f'selected compiler has no {lib / "libLLVM.dylib"}')
        previous = env.get('DYLD_LIBRARY_PATH', '')
        env['DYLD_LIBRARY_PATH'] = str(lib) + (os.pathsep + previous if previous else '')
    return env


def main():
    if len(sys.argv) < 3:
        raise RuntimeError('usage: cargo-llvm.py /path/to/selected/cargo <cargo arguments>')
    cargo = sys.argv[1]
    env = environment(cargo, os.environ, os.uname().sysname)
    # Replace the wrapper so cargo's exit status and signals reach make unchanged.
    os.execve(cargo, [cargo, *sys.argv[2:]], env)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'cargo-llvm: {error}', file=sys.stderr)
        sys.exit(1)

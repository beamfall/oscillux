# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WRAPPER = Path(__file__).with_name('cargo-llvm.py')
spec = importlib.util.spec_from_file_location('cargo_llvm', WRAPPER)
llvm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(llvm)


class CargoLlvmTests(unittest.TestCase):
    def fake_toolchain(self, root, cargo_body):
        (root / 'lib').mkdir()
        (root / 'lib/libLLVM.dylib').touch()
        for name, body in [('cargo', cargo_body), ('rustc', 'printf "%s\\n" "' + str(root) + '"')]:
            file = root / name
            file.write_text('#!/bin/sh\n' + body + '\n')
            file.chmod(0o755)

    def run_wrapper(self, root, *args):
        env = dict(os.environ)
        env.pop('RUSTC', None)
        env['DYLD_LIBRARY_PATH'] = '/caller/lib'
        return subprocess.run([sys.executable, str(WRAPPER), str(root / 'cargo'), *args],
                              env=env, capture_output=True, text=True)

    def test_forwards_arguments_and_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fake_toolchain(root, 'printf "%s|" "$@"; exit 23')
            result = self.run_wrapper(root, 'bench', '-p', 'oscillux-ffi')
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertEqual(result.stdout, 'bench|-p|oscillux-ffi|')

    def test_selected_compiler_library_precedes_caller_loader_path(self):
        # In-process: macOS drops DYLD_* when exec'ing a SIP-protected interpreter such as /bin/sh,
        # so a shell-script cargo could not report the variable it received.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fake_toolchain(root, 'exit 0')
            env = {'PATH': '/caller/bin', 'DYLD_LIBRARY_PATH': '/caller/lib'}
            result = llvm.environment(str(root / 'cargo'), env, 'Darwin')
            self.assertEqual(result['DYLD_LIBRARY_PATH'], str(root / 'lib') + ':/caller/lib')
            self.assertEqual(result['PATH'], str(root) + ':/caller/bin')
            self.assertEqual(env['DYLD_LIBRARY_PATH'], '/caller/lib')

    def test_compiler_without_libllvm_fails_on_macos(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.fake_toolchain(root, 'exit 0')
            (root / 'lib/libLLVM.dylib').unlink()
            with self.assertRaisesRegex(RuntimeError, 'selected compiler has no'):
                llvm.environment(str(root / 'cargo'), {}, 'Darwin')

    def test_non_macos_leaves_loader_path(self):
        result = llvm.environment('/selected/bin/cargo', {'DYLD_LIBRARY_PATH': 'kept'}, 'Linux')
        self.assertEqual(result['DYLD_LIBRARY_PATH'], 'kept')

    def test_missing_cargo_arguments_fail(self):
        result = subprocess.run([sys.executable, str(WRAPPER), '/selected/bin/cargo'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('usage', result.stderr)


if __name__ == '__main__':
    unittest.main()

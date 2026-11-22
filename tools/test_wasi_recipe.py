# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
from pathlib import Path
import tempfile
import os
import sys
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location('wasi_recipe', Path(__file__).with_name('test-wasi.py'))
recipe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recipe)


class WasiRecipeTests(unittest.TestCase):
    def test_selected_compiler_library_precedes_and_preserves_caller_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib = Path(tmp) / 'lib'
            lib.mkdir()
            (lib / 'libLLVM.dylib').touch()
            original = {'PATH': '/caller/bin', 'DYLD_LIBRARY_PATH': '/caller/lib', 'RUSTC': '/custom/bin/rustc'}
            with patch.object(recipe.subprocess, 'check_output', return_value=tmp + '\n') as probe, patch.object(recipe.shutil, 'which', return_value='/caller/bin/wasmtime'):
                result = recipe.environment('/selected/bin/cargo', original, 'Darwin')
            self.assertEqual(probe.call_args.args[0], ['/custom/bin/rustc', '--print', 'sysroot'])
            self.assertEqual(result['DYLD_LIBRARY_PATH'], str(lib) + ':/caller/lib')
            self.assertEqual(result['PATH'], '/selected/bin:/caller/bin')
            self.assertEqual(original['DYLD_LIBRARY_PATH'], '/caller/lib')

    def test_default_compiler_is_paired_with_selected_cargo(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.object(recipe.subprocess, 'check_output', return_value=tmp) as probe:
                with self.assertRaisesRegex(RuntimeError, 'selected compiler has no'):
                    recipe.environment('/selected/bin/cargo', {}, 'Darwin')
            self.assertEqual(probe.call_args.args[0], ['/selected/bin/rustc', '--print', 'sysroot'])

    def test_compiler_failure_propagates(self):
        with patch.object(recipe.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(7, 'rustc')):
            with self.assertRaises(subprocess.CalledProcessError):
                recipe.environment('/selected/bin/cargo', {}, 'Darwin')

    def test_non_macos_does_not_probe_or_modify_loader_path(self):
        with patch.object(recipe.subprocess, 'check_output') as probe, patch.object(recipe.shutil, 'which', return_value='/bin/wasmtime'):
            result = recipe.environment('/selected/bin/cargo', {'DYLD_LIBRARY_PATH': 'preserved'}, 'Linux')
        probe.assert_not_called()
        self.assertEqual(result['DYLD_LIBRARY_PATH'], 'preserved')
        self.assertEqual(result['CARGO_TARGET_WASM32_WASIP1_RUNNER'], 'wasmtime')

    def test_missing_runner_fails(self):
        with patch.object(recipe.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(RuntimeError, 'requires wasmtime'):
                recipe.environment('/selected/bin/cargo', {}, 'Linux')

    def test_real_wrapper_preserves_cargo_failure_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'lib').mkdir()
            (root / 'lib/libLLVM.dylib').touch()
            for name, body in [('cargo', 'exit 37'), ('rustc', 'printf "%s\\n" "' + tmp + '"'), ('wasmtime', 'exit 0')]:
                file = root / name
                file.write_text('#!/bin/sh\n' + body + '\n')
                file.chmod(0o755)
            env = dict(os.environ)
            env.pop('RUSTC', None)
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('test-wasi.py')), str(root / 'cargo')], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 37, result.stderr)

    def test_exec_replaces_wrapper_with_actual_workspace_test_command(self):
        with patch.object(recipe.sys, 'argv', ['test-wasi.py', '/selected/bin/cargo']), patch.object(recipe, 'environment', return_value={'selected': 'environment'}), patch.object(recipe.os, 'execve') as execute:
            recipe.main()
        argv = execute.call_args.args[1]
        self.assertEqual(argv[:8], ['/selected/bin/cargo', 'test', '--workspace', '--lib', '--target', 'wasm32-wasip1', '--offline', '--test'])
        self.assertEqual(set(argv[8::2]), {
            'core2_early', 'core2_boundaries', 'core2_vectors', 'dsp_streaming',
            'dsp_conformance', 'dsp_beat', 'dsp_agc', 'limiter_vectors', 'limiter_safety',
            'limiter_properties', 'limiter_regions', 'core2_ffi', 'limiter_ffi', 'realtime_paths',
            'ffi_robustness', 'dsp_descriptors', 'reaction_vectors', 'beatgrid_vectors',
            'beatgrid_ffi', 'cdg_vectors', 'cdg_realtime', 'cdg_ffi', 'cdg_present',
            'window_governor_vectors', 'window_governor_ffi',
        })
        self.assertEqual(execute.call_args.args[2], {'selected': 'environment'})


if __name__ == '__main__':
    unittest.main()

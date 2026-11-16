# SPDX-License-Identifier: AGPL-3.0-only
"""Host-independent parts of tools/platform-gate.py: vector flattening, verdicts and cleanup."""
import importlib.util
import hashlib
from pathlib import Path
import re
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('platform_gate', Path(__file__).with_name('platform-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PlatformGateTests(unittest.TestCase):
    def test_dsp_vectors_carry_every_recorded_digest_and_frame(self):
        dsp, region = gate.vectors()
        lines = dsp.read_text().splitlines()
        self.assertEqual(lines[0], 'tolerance 0.02 1e-06')
        headers = [l.split() for l in lines if l.startswith('dsp ')]
        recorded = re.findall(r'fixture!\("([^"]+)", (0x[0-9a-f_]+)',
                              (gate.ROOT / 'crates/oscillux-core/tests/dsp_conformance.rs').read_text())
        self.assertEqual([(h[1], int(h[3], 16)) for h in headers],
                         [(name, int(digest.replace('_', ''), 16)) for name, digest in recorded])
        for header in headers:
            frames = (gate.ROOT / f'conformance/dsp/{header[1]}.frames').read_text()
            self.assertIn(f'expect {frames.count(chr(10) + "frame ")}', lines)
        self.assertIn('segment 300 1 5000 11025', lines)
        self.assertTrue(region.read_text().startswith('tolerance '))

    def test_wav_samples_are_the_raw_signed_pcm(self):
        samples = gate.wav_samples(gate.ROOT / 'conformance/dsp/sine-440.wav', 48000)
        self.assertEqual(len(samples), 24000)
        self.assertEqual(samples[:3], [0, 943, 1883])
        with self.assertRaisesRegex(gate.GateFailure, 'mono 16-bit 44100'):
            gate.wav_samples(gate.ROOT / 'conformance/dsp/sine-440.wav', 44100)

    def test_rust_suite_results_are_counted_and_failures_raise(self):
        self.assertEqual(gate.count_passed('test result: ok. 3 passed; 0 failed\ntest result: ok. 0 passed;'), 3)
        with self.assertRaisesRegex(gate.GateFailure, 'FAILED'):
            gate.count_passed('test result: FAILED. 2 passed; 1 failed')

    def test_only_pass_and_link_only_rows_pass(self):
        run = gate.Gate()
        run.record('a', 'link', 'PASS')
        run.record('b', 'execute', 'LINK ONLY', 'AArch32')
        self.assertTrue(run.summary())
        self.assertIsNone(run.attempt('c', 'execute', lambda: (_ for _ in ()).throw(gate.GateFailure('boom'))))
        self.assertFalse(run.summary())

    def test_an_unrequested_windows_leg_is_listed_not_executed_and_passes(self):
        run = gate.Gate()
        gate.windows_leg(run, 'cargo', {}, None, None, None)
        self.assertEqual([(row[0], row[2]) for row in run.rows],
                         [('windows x86_64-pc-windows-msvc', 'NOT EXECUTED'), ('windows aarch64-pc-windows-msvc', 'NOT EXECUTED')])
        self.assertTrue(run.summary())

    def test_link_arguments_become_windows_paths_with_content_addressed_inputs(self):
        msvc = gate.msvc
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lib = root / 'rustlib/x86_64-pc-windows-msvc/lib'
            lib.mkdir(parents=True)
            (lib / 'libstd.rlib').write_bytes(b'std')
            (root / 'lib.def').write_bytes(b'EXPORTS')
            args = ['/NOLOGO', f'/LIBPATH:{lib}', str(lib / 'libstd.rlib'), f'/DEF:{root}/lib.def', 'kernel32.lib',
                    f'/OUT:{root}/out/oscillux.dll', f'/IMPLIB:{root}/out/oscillux.dll.lib', '/DLL']
            self.assertEqual(msvc.target_arch(args), 'x86_64')
            rewritten, inputs, outputs = msvc.rewrite(args, 'C:\\w', 'j')
            std, exports = hashlib.sha256(b'std').hexdigest(), hashlib.sha256(b'EXPORTS').hexdigest()
            self.assertEqual(rewritten, ['/NOLOGO', f'C:\\w\\cache\\{std}\\libstd.rlib', f'/DEF:C:\\w\\cache\\{exports}\\lib.def',
                                         'kernel32.lib', '/OUT:C:\\w\\jobs\\j\\out\\oscillux.dll',
                                         '/IMPLIB:C:\\w\\jobs\\j\\out\\oscillux.dll.lib', '/DLL'])
            self.assertEqual(inputs, {std: lib / 'libstd.rlib', exports: root / 'lib.def'})
            self.assertEqual(set(outputs), {'oscillux.dll', 'oscillux.dll.lib'})
            # A path link.exe would read that is not a local file cannot be forwarded.
            for argument in (f'/NATVIS:{root}/missing.natvis', str(lib)):
                with self.assertRaisesRegex(msvc.LinkError, 'cannot forward'):
                    msvc.rewrite([argument], 'C:\\w', 'j')
            with self.assertRaisesRegex(msvc.LinkError, 'no x86_64 or aarch64'):
                msvc.target_arch(['/NOLOGO'])
            (root / 'link.rsp').write_bytes('"/NOLOGO"\n"a b.o"\n'.encode('utf-16'))
            self.assertEqual(msvc.expand([f'@{root}/link.rsp', '/DLL']), ['/NOLOGO', 'a b.o', '/DLL'])
        self.assertEqual(msvc.response_file(['/OUT:C:\\a b.dll']), b'"/OUT:C:\\a b.dll"\r\n')
        script = msvc.batch('C:\\VS', 'aarch64', ['link.exe @x.rsp'])
        self.assertIn(b'call "C:\\VS\\VC\\Auxiliary\\Build\\vcvarsall.bat" x64_arm64 >nul', script)
        self.assertTrue(script.endswith(b'link.exe @x.rsp || exit /b\r\n'))

    def test_cleanup_runs_newest_first_and_survives_failures(self):
        run, order = gate.Gate(), []
        run.on_exit('first', lambda: order.append('first'))
        run.on_exit('broken', lambda: 1 / 0)
        run.on_exit('last', lambda: order.append('last'))
        run.cleanup()
        self.assertEqual(order, ['last', 'first'])
        self.assertEqual(run.cleanups, [])


    def test_expected_slices_and_abis_must_match_exactly(self):
        found = set(gate.EXPECTED_APPLE)
        self.assertIn('ios-arm64/arm64', gate.expect_exact('slices', found, gate.EXPECTED_APPLE))
        with self.assertRaisesRegex(gate.GateFailure, r"missing \[\('tvos-arm64', 'arm64'\)\], unexpected none"):
            gate.expect_exact('slices', found - {('tvos-arm64', 'arm64')}, gate.EXPECTED_APPLE)
        with self.assertRaisesRegex(gate.GateFailure, r"missing none, unexpected \['x86_64'\]"):
            gate.expect_exact('ABIs', gate.EXPECTED_ABIS | {'x86_64'}, gate.EXPECTED_ABIS)
        with self.assertRaisesRegex(gate.GateFailure, r"missing \['armeabi-v7a'\]"):
            gate.expect_exact('ABIs', {'arm64-v8a'}, gate.EXPECTED_ABIS)
        # The expectations track what tools/artifacts.py builds.
        artifacts = (gate.ROOT / 'tools/artifacts.py').read_text()
        for abi in gate.EXPECTED_ABIS:
            self.assertIn(f'"{abi}"', artifacts)
        self.assertEqual({identifier.split('-')[0] for identifier, _ in gate.EXPECTED_APPLE}, {'ios', 'macos', 'tvos'})


if __name__ == '__main__':
    unittest.main()

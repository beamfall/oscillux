# SPDX-License-Identifier: AGPL-3.0-only
"""Archive determinism survives changed input mtimes and creation order."""
import importlib.util
import io
import json
from unittest import mock
from pathlib import Path
import os
import tarfile
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("artifacts", Path(__file__).with_name("artifacts.py"))
artifacts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifacts)


class ArchiveTests(unittest.TestCase):
    def test_legal_payload_in_all_archive_layouts(self):
        # Exercise the same legal writer and archive encoders used by the three
        # producers. Native builds separately verify their actual final archives.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dependency = root / "dependency"
            dependency.mkdir()
            (dependency / "LICENSE-MIT").write_bytes(b"third-party fixture notice\n")
            metadata = {"workspace_members": [], "packages": [{
                "id": "fixture", "name": "fixture", "version": "1", "license": "MIT",
                "manifest_path": str(dependency / "Cargo.toml"),
            }]}
            for kind, legal_prefix, member_prefix in (
                ("apple", "Oscillux.xcframework", "Oscillux.xcframework/"),
                ("android", "assets/oscillux", "assets/oscillux/"),
                ("wasm", ".", "package/"),
            ):
                with self.subTest(kind=kind):
                    source = root / kind
                    with mock.patch.object(artifacts.subprocess, "check_output", return_value=json.dumps(metadata)):
                        artifacts.legal(source / legal_prefix)
                    archive_path = root / (kind + (".tgz" if kind == "wasm" else ".zip"))
                    if kind == "wasm":
                        artifacts.npm_tar(source, archive_path)
                        with tarfile.open(archive_path) as archive:
                            payload = {m.name: archive.extractfile(m).read() for m in archive if m.isfile()}
                    else:
                        artifacts.zip_tree(source, archive_path)
                        with zipfile.ZipFile(archive_path) as archive:
                            payload = {name: archive.read(name) for name in archive.namelist()}
                    for name in ("LICENSE", "LICENSING.md", "THIRD-PARTY-NOTICES.md"):
                        self.assertEqual(payload[member_prefix + name], (artifacts.ROOT / name).read_bytes())
                    self.assertEqual(payload[member_prefix + "third-party/fixture-1/LICENSE-MIT"],
                                     b"third-party fixture notice\n")
                    self.assertEqual(json.loads(payload[member_prefix + "third-party.json"]),
                                     [{"name": "fixture", "version": "1", "license": "MIT"}])

    def test_windows_on_other_hosts_is_recorded_as_not_built(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(artifacts.platform, "system", return_value="Darwin"):
            dist = Path(tmp)
            detail = artifacts.windows(dist / "stage", dist)
            self.assertEqual(detail["status"], "not-built")
            self.assertEqual([p.name for p in dist.iterdir()], ["windows-required-host.json"])
            self.assertEqual(json.loads((dist / "windows-required-host.json").read_text())["status"], "required-host")

    def test_wasm_budget_fails_closed(self):
        self.assertLess(artifacts.wasm_size(bytes(102400))["gzipBytes"], 102400)
        with self.assertRaisesRegex(RuntimeError, "budget exceeded"):
            artifacts.wasm_size(os.urandom(110000))

    def test_archives_normalize_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "z").write_text("last")
            (source / "a").write_text("first")
            for archive_fn, suffix in ((artifacts.zip_tree, "zip"), (artifacts.npm_tar, "tgz")):
                one, two = root / ("one." + suffix), root / ("two." + suffix)
                archive_fn(source, one)
                for file in source.iterdir():
                    os.utime(file, (1234567890, 1234567890))
                    file.chmod(0o600)
                archive_fn(source, two)
                self.assertEqual(one.read_bytes(), two.read_bytes())
            with zipfile.ZipFile(root / "one.zip") as archive:
                self.assertEqual(archive.namelist(), ["a", "z"])
                self.assertEqual(archive.read("z"), b"last")
            with tarfile.open(root / "one.tgz") as archive:
                self.assertEqual(archive.getnames(), ["package/a", "package/z"])
                self.assertTrue(all(item.uid == item.gid == item.mtime == 0 for item in archive))

    def test_host_paths_fail_closed_inside_nested_archives(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jar = io.BytesIO()
            with zipfile.ZipFile(jar, "w") as archive:
                archive.writestr("org/Oscillux.class", b"\0src at /Users/someone/oscillux\0")
            source = root / "source"
            (source / "jni").mkdir(parents=True)
            (source / "classes.jar").write_bytes(jar.getvalue())
            (source / "jni/liboscillux.so").write_bytes(b"\0/cargo/registry/src/lib.rs\0")
            clean, leaky = root / "clean.zip", root / "leaky.zip"
            artifacts.zip_tree(source, leaky)
            (source / "classes.jar").unlink()
            artifacts.zip_tree(source, clean)
            npm = root / "npm"
            npm.mkdir()
            (npm / "oscillux_bg.wasm").write_bytes(b"\0" + str(Path.home()).encode() + b"/.cargo/registry\0")
            tgz = root / "leaky.tgz"
            artifacts.npm_tar(npm, tgz)
            artifacts.check_host_paths([clean])
            for leak, member in ((leaky, "leaky.zip!classes.jar!org/Oscillux.class: /Users/"),
                                 (tgz, "leaky.tgz!gunzip!package/oscillux_bg.wasm: " + str(Path.home()))):
                with self.subTest(archive=leak.name):
                    with self.assertRaises(RuntimeError) as raised:
                        artifacts.check_host_paths([leak])
                    self.assertIn(member, str(raised.exception))
            named = root / "named.zip"
            with zipfile.ZipFile(named, "w") as archive:
                archive.writestr("Users/" + str(artifacts.ROOT).lstrip("/") + "/x", b"")
            with self.assertRaisesRegex(RuntimeError, "named.zip!Users/"):
                artifacts.check_host_paths([named])
            checkout = root / "checkout.zip"
            (source / "jni/liboscillux.so").write_bytes(str(artifacts.ROOT).encode())
            artifacts.zip_tree(source, checkout)
            with self.assertRaisesRegex(RuntimeError, "liboscillux.so"):
                artifacts.check_host_paths([checkout])

    def test_host_paths_fail_on_temporary_homebrew_and_xcode_paths(self):
        leaks = {
            b"/private/var/folders/": b"/private/var/folders/x1/abc/T/rustcXYZ/symbols.o",
            b"/opt/homebrew/": b"/opt/homebrew/share/android-commandlinetools/ndk/sysroot",
            b"/Applications/Xcode": b"/Applications/Xcode.app/Contents/Developer/Platforms",
        }
        for needle, leak in leaks.items():
            with self.subTest(needle=needle), tempfile.TemporaryDirectory() as directory:
                self.assertIn(needle, artifacts.host_path_needles())
                source = Path(directory) / "source"
                (source / "jni").mkdir(parents=True)
                (source / "jni/liboscillux.so").write_bytes(b"\0" + leak + b"\0")
                archive = Path(directory) / "leaky.aar"
                artifacts.zip_tree(source, archive)
                with self.assertRaises(RuntimeError) as raised:
                    artifacts.check_host_paths([archive])
                self.assertIn("leaky.aar!jni/liboscillux.so: " + needle.decode(), str(raised.exception))

    def test_host_path_check_covers_an_archive_root_member(self):
        # windows() writes the legal payload at the zip root, so members have no directory prefix.
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / "windows"
            (package / "include").mkdir(parents=True)
            (package / "LICENSE").write_bytes(b"licence text\n")
            artifacts.zip_tree(package, Path(directory) / "oscillux-windows.zip")
            artifacts.check_host_paths([Path(directory) / "oscillux-windows.zip"])
            (package / "include/leak.h").write_bytes(b"/Users/someone/oscillux\n")
            artifacts.zip_tree(package, Path(directory) / "leaky-windows.zip")
            with self.assertRaises(RuntimeError) as raised:
                artifacts.check_host_paths([Path(directory) / "leaky-windows.zip"])
            self.assertIn("leaky-windows.zip!include/leak.h: /Users/", str(raised.exception))

    def test_unfetched_crates_name_cargo_fetch(self):
        failure = artifacts.subprocess.CalledProcessError(101, ["cargo", "metadata"])
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(artifacts.subprocess, "check_output", side_effect=failure):
            with self.assertRaisesRegex(RuntimeError, "cargo fetch --locked"):
                artifacts.legal(Path(directory) / "package")


if __name__ == "__main__":
    unittest.main()

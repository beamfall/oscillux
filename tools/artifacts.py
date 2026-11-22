#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Build checksum-pinned distributions. Missing SDKs fail; selected subsets are explicit."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import sys
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPDX = "AGPL-3.0-only"
BINDGEN = "0.2.130"

def crate_version():
    """The workspace crate version, so the npm package matches the C header and Cargo.toml."""
    for line in (ROOT / "Cargo.toml").read_text().split("[workspace.package]", 1)[1].splitlines():
        if line.startswith("version = "):
            return line.split('"')[1]
    raise RuntimeError("no [workspace.package] version in Cargo.toml")


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def legal(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("LICENSE", "LICENSING.md", "THIRD-PARTY-NOTICES.md"):
        shutil.copyfile(ROOT / name, destination / name)
    (destination / "SPDX.txt").write_text("SPDX-License-Identifier: " + SPDX + "\n")
    # Include registry dependency attribution and licence texts, not only our licence.
    try:
        meta = json.loads(subprocess.check_output(["cargo", "metadata", "--locked", "--offline", "--format-version", "1"], cwd=ROOT))
    except subprocess.CalledProcessError as error:
        # --offline sees only fetched crates; a fresh CARGO_HOME has none yet.
        raise RuntimeError("cargo metadata --offline failed; run cargo fetch --locked first") from error
    deps = []
    for p in meta["packages"]:
        if p["id"] in meta["workspace_members"]:
            continue
        deps.append({"name": p["name"], "version": p["version"], "license": p["license"]})
        source = Path(p["manifest_path"]).parent
        for file in sorted(source.glob("*")):
            if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")):
                dest = destination / "third-party" / (p["name"] + "-" + p["version"])
                dest.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(file, dest / file.name)
    write_json(destination / "third-party.json", deps)


def zip_tree(source, output):
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                info = zipfile.ZipInfo(file.relative_to(source).as_posix(), (1980, 1, 1, 0, 0, 0))
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, file.read_bytes())


def npm_tar(source, output):
    with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for file in sorted(source.rglob("*")):
                if file.is_file():
                    data = file.read_bytes()
                    info = tarfile.TarInfo("package/" + file.relative_to(source).as_posix())
                    info.size, info.mode, info.mtime = len(data), 0o644, 0
                    archive.addfile(info, io.BytesIO(data))


def host_path_needles():
    """Byte strings that reveal the build host's layout: any macOS home, the macOS per-user
    temporary directory, Homebrew and Xcode installs, this home and the checkout."""
    return sorted({b"/Users/", b"/private/var/folders/", b"/opt/homebrew/", b"/Applications/Xcode",
                   str(Path.home()).encode(), str(ROOT).encode()})


def host_paths(name, data, needles):
    """`member: needle` for every needle in `data`, descending into nested zip, tar and gzip."""
    # A container is checked through its member names and contents, not its raw bytes.
    if data[:4] == b"PK\x03\x04":
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            members = [(member, archive.read(member)) for member in archive.namelist()]
    elif data[:2] == b"\x1f\x8b":
        members = [("gunzip", gzip.decompress(data))]
    elif data[257:262] == b"ustar":
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            members = [(member.name, archive.extractfile(member).read() if member.isfile() else b"")
                       for member in archive]
    else:
        return [f"{name}: {needle.decode()}" for needle in needles if needle in data]
    found = [f"{name}!{member}: {needle.decode()}" for member, _ in members
             for needle in needles if needle in member.encode()]
    for member, content in members:
        found += host_paths(name + "!" + member, content, needles)
    return found


def check_host_paths(files):
    """Fails when a shipped file, or any member inside it, embeds a host path."""
    found = [hit for file in files for hit in host_paths(file.name, file.read_bytes(), host_path_needles())]
    if found:
        raise RuntimeError("artifacts embed host paths:\n  " + "\n  ".join(found[:20]))


def build(target, package="oscillux-ffi"):
    run("cargo", "build", "--locked", "--release", "--target", target, "-p", package, cwd=ROOT)
    return Path(os.environ["CARGO_TARGET_DIR"]) / target / "release"


def apple(stage, dist):
    products = {}
    for target in ("aarch64-apple-darwin", "aarch64-apple-ios", "aarch64-apple-ios-sim", "aarch64-apple-tvos", "aarch64-apple-tvos-sim"):
        # The prebuilt std carries DWARF and build-host paths; ship the slices without debug info.
        (stage / target).mkdir()
        products[target] = stage / target / "liboscillux.a"
        run("xcrun", "strip", "-S", "-o", products[target], build(target) / "liboscillux.a")
    output = stage / "Oscillux.xcframework"
    args = ["xcodebuild", "-create-xcframework"]
    for library in products.values():
        args += ["-library", library, "-headers", ROOT / "ffi/include"]
    run(*args, "-output", output)
    # Xcode emits AvailableLibraries in nondeterministic order even with identical inputs.
    plist_path = output / "Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    info["AvailableLibraries"].sort(key=lambda entry: entry["LibraryIdentifier"])
    plist_path.write_bytes(plistlib.dumps(info, sort_keys=True))
    legal(output)
    archive_root = stage / "archive"
    archive_root.mkdir()
    shutil.move(str(output), archive_root / output.name)
    zip_tree(archive_root, dist / "oscillux-xcframework.zip")


def android(stage, dist):
    ndk = os.environ.get("ANDROID_NDK_HOME")
    if not ndk:
        raise RuntimeError("Android requires ANDROID_NDK_HOME and JDK javac (see docs/packaging.md)")
    host = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
    toolchain = Path(ndk) / "toolchains/llvm/prebuilt" / host
    aar = stage / "aar"
    legal(aar / "assets/oscillux")
    (aar / "AndroidManifest.xml").write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="org.oscillux"><uses-sdk android:minSdkVersion="21"/></manifest>\n')
    for target, abi, clang in (("aarch64-linux-android", "arm64-v8a", "aarch64-linux-android21-clang"), ("armv7-linux-androideabi", "armeabi-v7a", "armv7a-linux-androideabi21-clang")):
        compiler = toolchain / "bin" / clang
        os.environ["CARGO_TARGET_" + target.upper().replace("-", "_") + "_LINKER"] = str(compiler)
        library = build(target) / "liboscillux.so"
        destination = aar / "jni" / abi
        destination.mkdir(parents=True)
        run(toolchain / "bin/llvm-strip", "--strip-debug", "-o", destination / library.name, library)
        run(compiler, "-shared", "-fPIC", "-Wl,--build-id=none", "-Wl,--strip-debug", "-I", ROOT / "ffi/include", ROOT / "packaging/android/oscillux_jni.c", "-L", library.parent, "-loscillux", "-o", destination / "liboscillux_jni.so")
    classes = stage / "classes"
    classes.mkdir()
    run("javac", "--release", "8", "-d", classes, ROOT / "packaging/android/Oscillux.java")
    zip_tree(classes, aar / "classes.jar")
    shutil.copytree(ROOT / "ffi/include", aar / "headers")
    zip_tree(aar, dist / "oscillux.aar")


def windows(stage, dist):
    if platform.system() != "Windows":
        write_json(dist / "windows-required-host.json", {"status": "required-host", "targets": ["x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"], "requirements": "Windows with Visual Studio MSVC x64 and ARM64 build tools, Windows SDK, pinned Rust targets; run make artifacts ARTIFACT_TARGETS=windows"})
        # The manifest says outright that no Windows binary exists, not only the JSON's name.
        return {"status": "not-built", "reason": "requires a Windows host; windows-required-host.json is a requirement record, not a binary"}
    package = stage / "windows"
    legal(package)
    for target in ("x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc"):
        library = build(target)
        destination = package / target
        destination.mkdir()
        for name in ("oscillux.dll", "oscillux.dll.lib"):
            shutil.copyfile(library / name, destination / name)
    shutil.copytree(ROOT / "ffi/include", package / "include")
    zip_tree(package, dist / "oscillux-windows.zip")


def wasm(stage, dist):
    version = subprocess.check_output(["wasm-bindgen", "--version"], text=True).strip()
    if version != "wasm-bindgen " + BINDGEN:
        raise RuntimeError("wasm-bindgen CLI must match pinned " + BINDGEN)
    library = build("wasm32-unknown-unknown", "oscillux-wasm")
    package = stage / "npm"
    # The name and producers sections are debug metadata, about 6 KiB of the gzip budget.
    run("wasm-bindgen", "--target", "web", "--out-name", "oscillux", "--out-dir", package,
        "--remove-name-section", "--remove-producers-section", library / "oscillux_wasm.wasm")
    legal(package)
    shutil.copyfile(ROOT / "ffi/include/oscillux.h", package / "oscillux.h")
    write_json(package / "package.json", {"name": "@oscillux/core", "version": crate_version(), "type": "module", "main": "oscillux.js", "types": "oscillux.d.ts", "license": SPDX, "sideEffects": False})
    npm_tar(package, dist / "oscillux-wasm.tgz")
    data = (package / "oscillux_bg.wasm").read_bytes()
    size = wasm_size(data)
    # The CD+G renderer is a WASI command that servers run (conformance/cdg-present/README.md).
    render = build("wasm32-wasip1", "oscillux-cdg-render") / "oscillux-cdg-render.wasm"
    shutil.copyfile(render, dist / "oscillux-cdg-render.wasm")
    size["cdgRenderBytes"] = render.stat().st_size
    return size


def wasm_size(data):
    compressed = len(gzip.compress(data, mtime=0))
    if compressed > 102400:
        raise RuntimeError(f"WASM gzip budget exceeded: {compressed} > 102400 bytes")
    return {"bytes": len(data), "gzipBytes": compressed, "gzipBudgetBytes": 102400}


def build_receipt(targets):
    def output(*command):
        return subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True).stdout.strip()
    receipt = {"sourceRevision": output("git", "rev-parse", "HEAD"),
               "sourceDirty": bool(output("git", "status", "--porcelain", "--untracked-files=no")),
               "rustc": output("rustc", "--version"), "cargo": output("cargo", "--version"),
               "python": sys.version, "host": platform.platform()}
    if receipt["sourceDirty"]:
        raise RuntimeError("commit source changes before producing a revision-bound artifact manifest")
    if "apple" in targets:
        receipt["xcode"] = output("xcodebuild", "-version")
        receipt["appleSdks"] = {sdk: output("xcrun", "--sdk", sdk, "--show-sdk-version") for sdk in ("macosx", "iphoneos", "iphonesimulator", "appletvos", "appletvsimulator")}
    if "android" in targets:
        receipt["ndk"] = (Path(os.environ["ANDROID_NDK_HOME"]) / "source.properties").read_text().strip()
        receipt["javac"] = output("javac", "-version")
    if "wasm" in targets:
        receipt["wasmBindgen"] = output("wasm-bindgen", "--version")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--targets", default="apple,android,windows,wasm")
    args = parser.parse_args()
    targets = args.targets.split(",")
    if len(set(targets)) != len(targets) or any(t not in ("apple", "android", "windows", "wasm") for t in targets):
        parser.error("select unique comma-separated apple,android,windows,wasm targets")
    # A failed build must not leave an older manifest claiming success.
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    (dist / "manifest.json").unlink(missing_ok=True)
    os.environ["CARGO_TARGET_DIR"] = str(ROOT / "target/artifacts")
    os.environ["ZERO_AR_DATE"] = "1"
    # Panic locations embed source paths. Remap the home, then Cargo's registry and git
    # checkouts, then this checkout: rustc applies the last matching prefix.
    cargo_home = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")).resolve()
    remaps = ((Path.home(), "/home"), (cargo_home, "/cargo"), (ROOT, "/oscillux"))
    os.environ.pop("RUSTFLAGS", None)
    os.environ["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join(
        ["--remap-path-prefix=" + str(path) + "=" + alias for path, alias in remaps] + ["-C", "debuginfo=0"])
    rustc = Path(subprocess.check_output(["rustup", "which", "rustc"], text=True).strip())
    os.environ["DYLD_LIBRARY_PATH"] = str(rustc.parent.parent / "lib")
    (ROOT / "target").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="packaging-", dir=ROOT / "target") as tmp:
        stage = Path(tmp)
        outputs = stage / "dist"
        outputs.mkdir()
        details = {}
        for target in targets:
            work = stage / target
            work.mkdir()
            result = globals()[target](work, outputs)
            if result:
                details[target] = result
        check_host_paths(sorted(outputs.iterdir()))
        manifest = {"schemaVersion": 1, "selectedTargets": targets, "license": SPDX, "details": details, "artifacts": [], "build": build_receipt(targets)}
        for file in sorted(outputs.iterdir()):
            data = file.read_bytes()
            manifest["artifacts"].append({"file": file.name, "sha256": hashlib.sha256(data).hexdigest(), "sizeBytes": len(data)})
            shutil.copyfile(file, dist / file.name)
        write_json(dist / "manifest.json", manifest)
        print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

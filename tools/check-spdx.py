#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Fail unless every source file declares the project licence in its header.

Checked: *.rs, *.h, *.sh, *.py, *.toml, *.mjs, *.swift, *.glsl and Makefile, tracked or
untracked (ignored files and target/ are skipped). The identifier must appear within the first
HEADER_LINES lines.

A member crate manifest (a Cargo.toml below the root) may instead declare the licence through
cargo's own SPDX field, `license.workspace = true` or `license = "<identifier>"`.
"""

import os
import subprocess
import sys

IDENTIFIER = "AGPL-3.0-only"
MARKER = "SPDX-License-Identifier:"
HEADER_LINES = 5
SUFFIXES = (".rs", ".h", ".sh", ".py", ".toml", ".mjs", ".swift", ".glsl")
NAMES = ("Makefile",)
SKIP_PREFIXES = ("target/",)
MANIFEST_FIELDS = ("license.workspace = true", 'license = "' + IDENTIFIER + '"')


def candidate_paths():
    listing = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    paths = [p for p in listing.split("\0") if p]
    return sorted(p for p in paths if is_source(p) and os.path.isfile(p))


def is_source(path):
    if path.startswith(SKIP_PREFIXES):
        return False
    name = os.path.basename(path)
    return name in NAMES or name.endswith(SUFFIXES)


def declared_identifier(lines):
    header = [line for line in lines[:HEADER_LINES] if MARKER in line]
    if not header:
        return None
    value = header[0].split(MARKER, 1)[1]
    return value.replace("*/", "").strip()


def is_member_manifest(path):
    return os.path.basename(path) == "Cargo.toml" and "/" in path


def manifest_declares(lines):
    return any(line.strip() in MANIFEST_FIELDS for line in lines)


def problem(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()
    found = declared_identifier(lines)
    if found == IDENTIFIER:
        return None
    if found is not None:
        return "wrong identifier '" + found + "'"
    if is_member_manifest(path) and manifest_declares(lines):
        return None
    return "missing identifier"


def main():
    paths = candidate_paths()
    failures = [(p, problem(p)) for p in paths]
    failures = [(p, why) for p, why in failures if why]
    for path, why in failures:
        print("spdx: " + path + ": " + why, file=sys.stderr)
    if failures:
        print("spdx: FAIL, expected " + MARKER + " " + IDENTIFIER, file=sys.stderr)
        return 1
    print("spdx: ok, " + str(len(paths)) + " files")
    return 0


if __name__ == "__main__":
    sys.exit(main())

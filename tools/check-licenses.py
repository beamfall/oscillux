#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Fail unless every third-party dependency is licensed under the allow-list.

Reads `cargo metadata --offline` (all targets, no network fetch). Each dependency's SPDX
expression must be satisfiable using allowed licences only: `A OR B` needs one allowed side,
`A AND B` needs both. Legacy `A/B` is read as `A OR B`. `WITH` exceptions and a missing
`license` field fail closed.
"""

import json
import re
import subprocess
import sys

ALLOWED = {
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "Zlib",
    "Unicode-3.0",
    "Unicode-DFS-2016",
}
TOKEN = re.compile(r"\(|\)|[A-Za-z0-9.+-]+")


def metadata():
    output = subprocess.run(
        ["cargo", "metadata", "--offline", "--format-version", "1"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(output)


def third_party(meta):
    members = set(meta["workspace_members"])
    return [p for p in meta["packages"] if p["id"] not in members]


def tokens(expression):
    expression = expression.replace("/", " OR ")
    if TOKEN.sub("", expression).strip():
        raise ValueError("invalid SPDX character")
    return TOKEN.findall(expression)


def parse_or(toks):
    value = parse_and(toks)
    while toks and toks[0] == "OR":
        toks.pop(0)
        value = parse_and(toks) or value
    return value


def parse_and(toks):
    value = parse_term(toks)
    while toks and toks[0] == "AND":
        toks.pop(0)
        value = parse_term(toks) and value
    return value


def parse_term(toks):
    head = toks.pop(0)
    if head == "(":
        value = parse_or(toks)
        if toks.pop(0) != ")":
            raise ValueError("missing closing parenthesis")
        return value
    if head in ("AND", "OR", "WITH", ")"):
        raise ValueError("expected licence identifier")
    if toks and toks[0] == "WITH":
        toks.pop(0)
        if toks.pop(0) in ("AND", "OR", "WITH", "(", ")"):
            raise ValueError("expected exception identifier")
        return False
    return head in ALLOWED


def allowed(expression):
    try:
        toks = tokens(expression)
        value = parse_or(toks)
        return value and not toks
    except (IndexError, ValueError):
        return False


def problem(package):
    expression = package.get("license")
    if not expression:
        return "no SPDX license field"
    if not allowed(expression):
        return "license '" + expression + "' is not on the allow-list"
    return None


def main():
    packages = third_party(metadata())
    failures = [(p, problem(p)) for p in packages]
    failures = [(p, why) for p, why in failures if why]
    for package, why in failures:
        print("licenses: " + package["name"] + " " + package["version"] + ": " + why, file=sys.stderr)
    if failures:
        print("licenses: FAIL, allowed: " + ", ".join(sorted(ALLOWED)), file=sys.stderr)
        return 1
    print("licenses: ok, " + str(len(packages)) + " third-party packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())

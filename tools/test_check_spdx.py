# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise the SPDX header check: the project identifier passes, any other fails."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_spdx", Path(__file__).with_name("check-spdx.py"))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SpdxChecks(unittest.TestCase):
    def problem(self, name, text):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            Path(path).write_text(text)
            cwd = os.getcwd()
            os.chdir(root)
            try:
                return CHECK.problem(name)
            finally:
                os.chdir(cwd)

    def test_identifier_is_agpl_only(self):
        self.assertEqual(CHECK.IDENTIFIER, "AGPL-3.0-only")

    def test_header_in_every_comment_style_passes(self):
        for name, text in (
            ("a.rs", "// SPDX-License-Identifier: AGPL-3.0-only\nfn main() {}\n"),
            ("a.py", "#!/usr/bin/env python3\n# SPDX-License-Identifier: AGPL-3.0-only\n"),
            ("a.h", "/* SPDX-License-Identifier: AGPL-3.0-only */\n"),
            ("Makefile", "# SPDX-License-Identifier: AGPL-3.0-only\n"),
        ):
            self.assertIsNone(self.problem(name, text), name)

    def test_other_identifiers_fail(self):
        for identifier in ("CC-BY-NC-4.0", "AGPL-3.0-or-later", "AGPL-3.0", "MIT"):
            text = "// SPDX-License-Identifier: " + identifier + "\n"
            self.assertEqual(self.problem("a.rs", text), "wrong identifier '" + identifier + "'")

    def test_missing_or_late_header_fails(self):
        self.assertEqual(self.problem("a.rs", "fn main() {}\n"), "missing identifier")
        late = "\n" * CHECK.HEADER_LINES + "// SPDX-License-Identifier: AGPL-3.0-only\n"
        self.assertEqual(self.problem("a.rs", late), "missing identifier")

    def test_member_manifest_may_use_cargo_field(self):
        self.assertIsNone(self.problem("crates/x/Cargo.toml", '[package]\nlicense.workspace = true\n'))
        self.assertIsNone(self.problem("crates/x/Cargo.toml", '[package]\nlicense = "AGPL-3.0-only"\n'))
        old = '[package]\nlicense = "CC-BY-NC-4.0"\n'
        self.assertEqual(self.problem("crates/x/Cargo.toml", old), "missing identifier")
        self.assertEqual(self.problem("Cargo.toml", '[package]\nlicense.workspace = true\n'), "missing identifier")


if __name__ == "__main__":
    unittest.main()

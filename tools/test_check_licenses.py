# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise licence validation even when the workspace has no dependencies."""

import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "check_licenses", Path(__file__).with_name("check-licenses.py")
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class LicenseChecks(unittest.TestCase):
    def test_permitted_choices_and_conjunctions(self):
        for expression in (
            "MIT",
            "Apache-2.0",
            "MIT/Apache-2.0",
            "GPL-3.0 OR MIT",
            "(MIT OR Apache-2.0) AND BSD-3-Clause",
            "  MIT \t AND Unicode-3.0  ",
        ):
            with self.subTest(expression=expression):
                self.assertTrue(CHECK.allowed(expression))

    def test_disallowed_and_malformed_expressions_fail_closed(self):
        for expression in (
            "GPL-3.0",
            "MIT AND GPL-3.0",
            "MIT WITH Unknown-exception",
            "MIT!",
            "MIT OR Apache-2.0!",
            "MIT | GPL-3.0",
            "(MIT GPL-3.0",
            "MIT OR )",
            "MIT OR WITH",
            "MIT OR GPL-3.0 WITH",
            "MIT OR GPL-3.0 WITH )",
            "(MIT",
            "MIT AND",
            "",
        ):
            with self.subTest(expression=expression):
                self.assertFalse(CHECK.allowed(expression))

    def test_dependency_with_malformed_license_fails_gate_entry_point(self):
        metadata = {
            "workspace_members": [],
            "packages": [{"id": "dep", "name": "dep", "version": "1", "license": "MIT!"}],
        }
        error = io.StringIO()
        with patch.object(CHECK, "metadata", return_value=metadata):
            with contextlib.redirect_stderr(error):
                self.assertEqual(CHECK.main(), 1)
        self.assertIn("MIT!", error.getvalue())


if __name__ == "__main__":
    unittest.main()

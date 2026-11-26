"""Run the LuCI view harness (tests/luci_check.js) under Node.

The harness loads the real view source against minimal LuCI stubs and checks
the UCI option bindings, the pairing/control widget re-render behaviour and the
exec command lines against the rpcd ACL. It is skipped when Node is unavailable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import unittest

import support

HARNESS = support.REPO_ROOT / "tests" / "luci_check.js"
NODE = shutil.which("node") or shutil.which("nodejs")


@unittest.skipUnless(NODE, "node not available")
@unittest.skipUnless(HARNESS.exists(), "luci_check.js not present")
class LuCIViewHarnessTests(unittest.TestCase):
    def test_view_harness_passes(self):
        result = subprocess.run(
            [NODE, str(HARNESS)],
            cwd=str(support.REPO_ROOT),
            capture_output=True,
            text=True,
            env=dict(os.environ),
            timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("luci_check.js OK", result.stdout)


if __name__ == "__main__":
    unittest.main()

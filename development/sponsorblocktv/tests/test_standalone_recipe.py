from pathlib import Path
import unittest

PACKAGE = Path(__file__).resolve().parents[3] / "utils/sponsorblocktv"

class StandaloneRecipeTests(unittest.TestCase):
    def test_source_is_local(self):
        recipe = (PACKAGE / "Makefile").read_text(encoding="utf-8")
        for field in ("PKG_SOURCE:=", "PKG_SOURCE_URL:=", "PKG_HASH:=", "UPSTREAM_VERSION"):
            self.assertNotIn(field, recipe)
        self.assertIn("define Build/Prepare", recipe)
        self.assertIn("$(CP) ./LICENSE.md ./NOTICE.md", recipe)
        self.assertFalse((PACKAGE / "UPSTREAM_VERSION").exists())
        self.assertEqual((PACKAGE / "VERSION").read_text().strip(), "0.1.0")
        self.assertIn("GNU GENERAL PUBLIC LICENSE", (PACKAGE / "LICENSE.md").read_text())
        self.assertTrue((PACKAGE / "NOTICE.md").is_file())

if __name__ == "__main__":
    unittest.main()

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

class BrandingTests(unittest.TestCase):
    def test_only_external_api_uses_upstream_name(self):
        view = ROOT / "luci/luci-app-sponsorblocktv/htdocs/luci-static/resources/view/sponsorblocktv.js"
        catalog = ROOT / "luci/luci-i18n-sponsorblocktv-vi/htdocs/luci-static/resources/sponsorblocktv/i18n/vi.json"
        for line in view.read_text(encoding="utf-8").splitlines():
            if re.search(r"SponsorBlock(?!TV)", line):
                self.assertIn("SponsorBlock API", line)
        for key, value in json.loads(catalog.read_text(encoding="utf-8")).items():
            for text in (key, value):
                if re.search(r"SponsorBlock(?!TV)", text):
                    self.assertTrue("SponsorBlock API" in text or "API SponsorBlock" in text, text)

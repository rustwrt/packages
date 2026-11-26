import unittest
from pathlib import Path

class OffsetUnitsTests(unittest.TestCase):
    def test_single_conversion(self):
        root=Path(__file__).resolve().parents[1]/'../../utils/sponsorblocktv/files/ucode'
        launcher=(root/'sponsorblocktv-run').read_text(encoding='utf-8')
        runtime=(root/'lib/runtime.uc').read_text(encoding='utf-8')
        self.assertNotIn('d.offset = (d.offset || 0) / 1000', launcher)
        self.assertIn('self.offset = (device.offset || 0) / 1000.0',runtime)

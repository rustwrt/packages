from pathlib import Path
import unittest
class PairArgumentSourceTests(unittest.TestCase):
    def test_fixture_uses_actual_parser(self):
        root=Path(__file__).resolve().parents[1]
        cli=(root/'../../utils/sponsorblocktv/files/ucode/sponsorblocktv-pair').read_text(encoding='utf-8')
        parser=cli[cli.index('function parse_args'):cli.index('// --- main')]
        self.assertIn(parser,(root/'tests/pair_args_r31_check.uc').read_text(encoding='utf-8'))

    def test_launcher_fixture_uses_actual_functions(self):
        root=Path(__file__).resolve().parents[1]
        cli=(root/'../../utils/sponsorblocktv/files/ucode/sponsorblocktv-run').read_text(encoding='utf-8')
        funcs=cli[cli.index('function parse_args'):cli.index('function validate_config')]
        self.assertIn(funcs,(root/'tests/config_launch_r46_check.uc').read_text(encoding='utf-8'))

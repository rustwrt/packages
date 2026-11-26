import ast
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

class CastLanPathTest(unittest.TestCase):
    def test_minimal_process_environment_retains_extra_lans(self):
        source = Path(__file__).resolve().parents[1] / '../../utils/sponsorblocktv/files/ucode/sponsorblocktv-cast-bridge'
        node = next(x for x in ast.parse(source.read_text(encoding='utf-8')).body
                    if isinstance(x, ast.FunctionDef) and x.name == '_lan_statuses')
        ns = {'json': json, 'subprocess': subprocess}
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), ns)
        config = "firewall.@zone[0].name='lan'\nfirewall.@zone[0].network='lan' 'tvlan'\n"
        statuses = {'interface': [{'interface': 'lan', 'up': True}, {'interface': 'tvlan', 'up': True}, {'interface': 'wan', 'up': True}]}
        def output(args, **kwargs):
            if args == ['/sbin/uci','-q','show','firewall']:
                return config
            if args == ['/bin/ubus','call','network.interface','dump']:
                return json.dumps(statuses)
            raise AssertionError('Lookup must not rely on PATH: '+str(args))
        with patch.object(subprocess, 'check_output', side_effect=output):
            self.assertEqual([x['interface'] for x in ns['_lan_statuses']()], ['lan','tvlan'])

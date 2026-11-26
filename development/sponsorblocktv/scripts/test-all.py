"""Repeatable KHAIPHANPC test runner. Never modifies production TV settings."""
import argparse
import json
import re
import secrets
import shlex
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
       '-o', 'ConnectTimeout=5', 'root@192.168.1.1']
SCP = ['scp', '-O', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes']
parser = argparse.ArgumentParser()
parser.add_argument('--network', action='store_true', help='live public YouTube metadata')
parser.add_argument('--discovery', action='store_true', help='real LAN scan (no adding)')
args = parser.parse_args()
report = []
def check(name, argv, timeout=120, validate=None):
    try:
        r = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=timeout)
        output = r.stdout + r.stderr
        ok = r.returncode == 0 and (validate is None or validate(r.stdout))
    except Exception as e:
        output, ok = str(e), False
    report.append(dict(name=name, status='PASS' if ok else 'FAIL', output=output))
    print(name, report[-1]['status'], flush=True)
    if not ok: print(output[-2000:], flush=True)
    return ok
def remote(cmd, timeout=20):
    return subprocess.check_output(SSH+[cmd], text=True, encoding='utf-8',
                                   timeout=timeout).strip()
check('Python suite', [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'tests'])
check('LuCI', ['node', 'tests/luci_check.js'])
check('LuCI i18n', ['node', 'tests/luci_i18n_check.js'])
check('WSL ucode + loopback', ['wsl','-d','Ubuntu-26.04','-e','bash','-lc',
    'cd /mnt/d/REPO/RustWRT/packages/development/sponsorblocktv && bash scripts/test-host-ucode.sh'], 300)
check('Router dependency verification', SSH+['/usr/sbin/sponsorblocktv-deps'])
check('Router native TLS memory and isolation',[sys.executable,'scripts/test-router-tls.py'],150)
stage = None
stores = []
try:
    stage = remote('mktemp -d /tmp/sponsorblocktv-test.XXXXXX')
    if not re.fullmatch(r'/tmp/sponsorblocktv-test\.[A-Za-z0-9]+',stage):
        stage = None
        raise RuntimeError('Invalid temporary directory')
    names = ['stats_r80_check.uc', 'device_policy_store_r53_check.uc',
             'next_r88_check.uc', 'discovery_r43_check.uc', 'discovery_r44_check.uc', 'queue_r93_check.uc', 'memory_http_check.uc', 'live_full_check.uc', 'ad_latency_r55_check.uc']
    if args.network: names.append('whitelist_network_r57.uc')
    subprocess.run(SCP+['tests/'+n for n in names]+['root@192.168.1.1:'+stage+'/'],
                   cwd=ROOT, check=True,timeout=30)
    remote('cd '+shlex.quote(stage)+'; ln -s /usr/lib/sponsorblocktv lib; mkdir -p /tmp/sponsorblocktv')
    for name in names:
        prefix = 'cd '+shlex.quote(stage)+'; '
        arg = ''
        if name in ('stats_r80_check.uc','device_policy_store_r53_check.uc'):
            store = remote('mktemp -d /tmp/sponsorblocktv/test.XXXXXX')
            if not re.fullmatch(r'/tmp/sponsorblocktv/test\.[A-Za-z0-9]+',store):
                raise RuntimeError('Invalid store')
            stores.append(store)
            prefix += 'export SB_TEST_STATS_DIR='+shlex.quote(store)+'; '
            arg = ' '+shlex.quote(store)
        check('Router '+name,SSH+[prefix+'ucode -g 1000 '+shlex.quote(name)+arg],60)
    if args.discovery:
        scan=secrets.token_hex(16)
        def validate_scan(out):
            d=json.loads(out)
            return d.get('scan_id')==scan and not d.get('pending') and not d.get('error') and bool(d.get('devices') or d.get('unpaired'))
        check('Real LAN discovery',SSH+['/usr/sbin/sponsorblocktv-discover --scan '+scan],60,validate_scan)
except Exception as e:
    report.append(dict(name='Router test setup',status='FAIL',output=str(e)))
finally:
    for d in stores+([stage] if stage else []):
        try: remote('rm -rf -- '+shlex.quote(d))
        except Exception as e: print('Cleanup failed:',d,str(e))
for name, enabled in [('Public network metadata',args.network),('LAN discovery',args.discovery)]:
    if not enabled: report.append(dict(name=name,status='SKIP',output='Optional; enable flag'))
path=ROOT/'build'/'test-reports'/datetime.now().strftime('%Y%m%d-%H%M%S.json')
path.parent.mkdir(parents=True,exist_ok=True)
path.write_text(json.dumps(report,ensure_ascii=True,indent=2),encoding='utf-8')
counts={s:sum(x['status']==s for x in report) for s in ('PASS','FAIL','SKIP')}
print(counts,'report:',path)
sys.exit(bool(counts['FAIL']))

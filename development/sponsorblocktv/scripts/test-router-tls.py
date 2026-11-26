"""Run the native HTTPS lifecycle regression on the configured test router."""
import argparse
import re
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
       '-o', 'ConnectTimeout=5', 'root@192.168.1.1']
SCP = ['scp', '-O', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes']
parser = argparse.ArgumentParser()
parser.add_argument('--source', action='store_true', help='test project source, not installed library')
args = parser.parse_args()
def remote(cmd):
    return subprocess.check_output(SSH + [cmd], text=True, timeout=20).strip()
stage = remote('mktemp -d /tmp/sponsorblocktv-test.XXXXXX')
if not re.fullmatch(r'/tmp/sponsorblocktv-test\.[A-Za-z0-9]+', stage):
    raise SystemExit('Invalid fixture directory')
try:
    with tempfile.TemporaryDirectory(prefix='tls-', dir=ROOT/'build') as tmp:
        tmp = Path(tmp)
        wsl = '/mnt/' + tmp.drive[0].lower() + tmp.as_posix()[2:]
        subprocess.run(['wsl','-e','openssl','req','-x509','-newkey','rsa:2048','-nodes',
                        '-keyout',wsl+'/key.pem','-out',wsl+'/cert.pem','-days','1',
                        '-subj','/CN=localhost'],check=True,capture_output=True,timeout=30)
        files = [ROOT/'tests/http_tls_pool_check.uc',ROOT/'tests/http_tls_fixture.py',
                 tmp/'cert.pem',tmp/'key.pem']
        subprocess.run(SCP + [str(f) for f in files] + ['root@192.168.1.1:'+stage+'/'],
                       check=True,timeout=30)
        if args.source:
            remote('mkdir '+shlex.quote(stage+'/lib'))
            subprocess.run(SCP + [str(ROOT/'../../utils/sponsorblocktv/files/ucode/lib'/n)
                for n in ('http.uc','util.uc')] + ['root@192.168.1.1:'+stage+'/lib/'],
                check=True,timeout=30)
        else:
            remote('ln -s /usr/lib/sponsorblocktv '+shlex.quote(stage+'/lib'))
        cmd = 'cd '+shlex.quote(stage)+r"""; chmod 600 key.pem; python3 http_tls_fixture.py port cert.pem key.pem & server=$!; trap 'kill "$server" 2>/dev/null' EXIT; for i in 1 2 3 4 5; do [ -s port ] && break; sleep 1; done; [ -s port ] && ucode -g 1000 http_tls_pool_check.uc "$(cat port)" """
        subprocess.run(SSH+[cmd],check=True,timeout=100)
finally:
    remote('rm -rf -- '+shlex.quote(stage))

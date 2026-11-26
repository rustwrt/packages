#!/usr/bin/env python3
"""Read WARP endpoint choices from Cloudflare without displaying credentials."""
import argparse, json, re, subprocess, sys, tomllib

parser=argparse.ArgumentParser()
parser.add_argument('account_file', help='Existing wgcf TOML account file')
args=parser.parse_args()
try:
    with open(args.account_file,'rb') as f: data=tomllib.load(f)
    device=data.get('device_id'); token=data.get('access_token')
    if not isinstance(device,str) or not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',device):
        raise ValueError('invalid device ID')
    if not isinstance(token,str) or not re.fullmatch(r'[A-Za-z0-9._~+/=-]{8,4096}',token):
        raise ValueError('invalid access token')
    config='\n'.join([
        'url = "https://api.cloudflareclient.com/v0a5641/reg/'+device+'"',
        'header = "Authorization: Bearer '+token+'"',
        'header = "Accept: application/json"',
        'user-agent = "luci-proto-warp-test/0.1"',
        'noproxy = "*"',
        ''
    ])
    data=None; token=None
    response=subprocess.run(['curl','--silent','--connect-timeout','10','--max-time','25','--config','-','--write-out','\n%{http_code}'],input=config,text=True,capture_output=True,timeout=35)
    config=None
    if response.returncode!=0: raise ValueError('TLS or network request failed')
    body,code=response.stdout.rsplit('\n',1)
    if code!='200': raise ValueError('HTTP '+code if re.fullmatch(r'\d{3}',code) else 'invalid HTTP response')
    obj=json.loads(body); ep=obj['config']['peers'][0]['endpoint']
    v4=ep.get('v4'); v6=ep.get('v6'); ports=ep.get('ports',[])
    if not isinstance(v4,str) or not re.fullmatch(r'[0-9.:]{3,32}',v4): raise ValueError('invalid IPv4 endpoint')
    if v6 is not None and (not isinstance(v6,str) or not re.fullmatch(r'[0-9A-Fa-f:\[\].]{2,80}',v6)): raise ValueError('invalid IPv6 endpoint')
    if not isinstance(ports,list) or not ports or len(ports)>32 or any(type(p) is not int or not 1<=p<=65535 for p in ports): raise ValueError('invalid port list')
    print(json.dumps({'v4':v4,'v6':v6,'ports':ports},sort_keys=True))
except (OSError,KeyError,IndexError,TypeError,ValueError,subprocess.TimeoutExpired) as exc:
    print('API endpoint check failed: '+str(exc),file=sys.stderr)
    sys.exit(1)

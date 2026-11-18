#!/usr/bin/env python3
"""Regression test production ucode with isolated paths, real wg keys and mock HTTP."""
import json, os, pathlib, re, subprocess, tempfile

source = pathlib.Path(__file__).resolve().parents[1] / "cloudflare-warp/files/usr/lib/warp/warp-reg.uc"
ucode = os.environ.get("UCODE", "ucode")
args = [ucode]
if os.getenv("UCODE_MODULES"):
    args += ["-L", os.environ["UCODE_MODULES"]]
original = source.read_text()
with tempfile.TemporaryDirectory(prefix="warp-ucode-test-") as temp:
    d = pathlib.Path(temp)
    (d/"run").mkdir()
    (d/"etc/accounts").mkdir(parents=True)
    (d/"bin").mkdir()
    script = d/"warp-reg.uc"
    # Test-only path substitution; the installed helper uses fixed root-only paths.
    adapted = original.replace("/tmp/warp", str(d/"run")).replace("/etc/warp-reg", str(d/"etc"))
    adapted = adapted.replace(r"^\/tmp\/warp\/[.]request[.]", "^" + str(d/"run").replace("/",r"\/") + r"\/[.]request[.]")
    script.write_text(adapted)
    mock = d/"bin/curl"
    mock.write_text("""#!/usr/bin/env python3
import os,sys,json,pathlib
d=pathlib.Path(os.environ["MOCK_ROOT"])
state=d/"state.json"
id="12345678-1234-1234-1234-123456789abc"
cfg={}
for line in sys.stdin:
    k,v=line.strip().split(" = ",1); cfg[k]=json.loads(v)
method=cfg.get("request","GET")
mode=os.getenv("MOCK_FAILURE","")
data=json.loads(cfg.get("data","null"))
assert cfg["url"].startswith("https://api.cloudflareclient.com/")
assert cfg["noproxy"]=="*"
if method=="POST":
    assert data["tos"].endswith("Z") and data["key_type"]=="curve25519"
    assert not list((d/"run").glob(".request.*/private.key"))
    state.write_text(json.dumps({"key":data["key"],"posts":1}))
    result={"id":id,"token":"synthetic-token"}
    code="201"
else:
    s=json.loads(state.read_text())
    if method=="PATCH":
        s["key"]=data["key"]; state.write_text(json.dumps(s))
        code="204"; result={}
    else:
        code="200"
        result={"id":id,"key":s["key"],"enabled":True,"account":{"id":id},
          "config":{"interface":{"addresses":{"v4":"192.0.2.1","v6":"2001:db8::1"}},
          "peers":[{"public_key":"A"*43+"=","endpoint":{"v4":"192.0.2.2:0","ports":[2408]}}],
          "client_id":"AAAA"}}
        if mode=="bad-key": result["key"]="invalid"
pathlib.Path(sys.argv[sys.argv.index("--output")+1]).write_text(json.dumps(result))
print(code,end="")
""")
    # curl config repeats header; only last header retained by the mock (not production).
    mock.chmod(0o755)
    env=dict(os.environ,PATH=str(d/"bin")+":"+os.environ["PATH"],MOCK_ROOT=temp)
    def invoke(argv,success=True):
        p=subprocess.run(args+[str(script)]+argv,env=env,capture_output=True,text=True,timeout=30)
        assert (p.returncode==0)==success, (argv,p.returncode,p.stderr)
        return p.stdout
    invoke(["register","../unsafe"],False)
    invoke(["register","sample","bad;device"],False)
    invoke(["fresh-session","fresh-warpa","warpa","eth0","123"])
    path=d/"run/session-warpa/session.json"
    data=json.loads(path.read_text())
    assert data["endpoint"]=="192.0.2.2:2408" and data["ipv6"]=="2001:db8::1"
    assert data["account_mode"]=="fresh" and data["device_id_masked"]=="1234...9abc"
    assert (d/"run/session-warpa/private.key").stat().st_mode & 0o077 == 0
    assert (d/"run/session-warpa/owner").read_text()=="123"
    assert json.loads((d/"etc/binding-warpa.json").read_text())["account"].startswith("auto-")
    invoke(["fresh-session","fresh-warpa","warpa","eth0","124"],False)
    invoke(["clear","fresh-warpa","warpa"])
    assert not path.exists()
    before=(d/"etc/fresh-attempts.json").read_bytes()
    invoke(["fresh-session","fresh-warpa","warpa","eth0","125"])
    assert (d/"etc/fresh-attempts.json").read_bytes()==before
    invoke(["clear","fresh-warpa","warpa"])
    env["MOCK_FAILURE"]="bad-key"
    invoke(["fresh-session","fresh-warpa","warpa","eth0","126"],False)
    assert not (d/"run/session-warpa").exists()
    assert not (d/"run/account-fresh-warpa.lease").exists()
    assert not list((d/"run").glob(".request.*"))
print("PASS: fresh registration, persistent reuse, real WireGuard keys, API validation, lock ownership and failed-session cleanup")

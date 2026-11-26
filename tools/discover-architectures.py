"""Discover public upstream IPK variants. Output is evidence, never approval."""
import base64, concurrent.futures, gzip, hashlib, io, json, os, re
from pathlib import Path
from urllib.request import Request, urlopen
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

ROOT = Path(__file__).resolve().parent
LIMIT = 4 * 1024 * 1024
ARCH = re.compile(r"[a-z0-9][a-z0-9_-]{0,95}")
NAME = re.compile(r"[A-Za-z0-9_.+~-]{1,200}\.ipk")
SHA = re.compile(r"[a-f0-9]{64}")

def get(url, limit=LIMIT, github=False):
    headers = {"User-Agent": "rustwrt-architecture-discovery"}
    if github and os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    with urlopen(Request(url, headers=headers), timeout=25) as response:
        data = response.read(limit+1)
    if len(data) > limit:
        raise ValueError("Response exceeds limit")
    return data

def fields(block):
    result = {}
    for line in block.splitlines():
        if not line or line.startswith((" ", "\t")):
            continue
        k, v = line.split(": ", 1)
        if k in result:
            raise ValueError("Duplicate field")
        result[k] = v
    return result

def signed(job):
    repo, template, arch = job
    url = template["base_url"].replace("{architecture}", arch)
    result = {"repo": repo, "architecture": arch, "base_url": url}
    try:
        key = base64.b64decode(template["public_key"], validate=True)
        sig = base64.b64decode(get(url+"Packages.sig", 4096).decode().strip().splitlines()[-1], validate=True)
        with gzip.GzipFile(fileobj=io.BytesIO(get(url+"Packages.gz"))) as f:
            raw = f.read(LIMIT+1)
        if len(raw)>LIMIT or len(key)!=42 or len(sig)!=74 or key[:2]!=b"Ed" or key[:10]!=sig[:10]:
            raise ValueError("Invalid usign index")
        Ed25519PublicKey.from_public_bytes(key[10:]).verify(sig[10:],raw)
        entries=[]; seen=set()
        for block in raw.decode().strip().split("\n\n"):
            e=fields(block)
            name=e["Filename"]
            if not NAME.fullmatch(name) or name in seen or not SHA.fullmatch(e["SHA256sum"]) or not 0<int(e["Size"])<=64*1024*1024:
                raise ValueError("Invalid asset metadata")
            seen.add(name)
            entries.append({k:e[k] for k in ("Package","Version","Architecture","Filename","Size","SHA256sum","Depends","Provides","Conflicts") if k in e})
        return dict(result,status="verified_index",index_sha256=hashlib.sha256(raw).hexdigest(),candidates=entries)
    except Exception as exc:
        return dict(result,status="unavailable",reason=type(exc).__name__)

def release(repo):
    try:
        url="https://api.github.com/repos/"+repo+"/releases/latest"
        data=json.loads(get(url,github=True))
        entries=[]
        for a in data["assets"]:
            if a["name"].endswith(".ipk"):
                entries.append({k:a.get(k) for k in ("name","size","digest","browser_download_url")})
        return {"repo":repo,"status":"listed","tag":data["tag_name"],"candidates":entries}
    except Exception as exc:
        return {"repo":repo,"status":"unavailable","reason":type(exc).__name__}

def main():
    config=json.loads((ROOT/"architecture-sources.json").read_text(encoding="utf-8"))
    fw=config["firmware"]
    page=get("https://downloads.openwrt.org/releases/"+fw+"/packages/").decode()
    arches=sorted({a for a in re.findall(r'href="([^"/]+)/"',page) if ARCH.fullmatch(a)})
    if not arches:
        raise RuntimeError("Official architecture inventory unavailable")
    jobs=[(r["repo"],t,a) for r in config["repositories"] for t in r.get("source_templates",[]) for a in arches if t["architectures"]=="*" or a in t["architectures"]]
    if len(jobs)>2048:
        raise ValueError("Too many jobs")
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        indexes=list(pool.map(signed,jobs))
        releases=list(pool.map(release,[r["repo"] for r in config["repositories"]]))
    out={"schema":1,"approval":False,"firmware":fw,"architectures":arches,"sources":indexes,"releases":releases}
    Path("architecture-candidates.json").write_text(json.dumps(out,indent=2)+"\n",encoding="utf-8")
    count=sum(x["status"]=="verified_index" for x in indexes)
    print("Verified signed indexes:",count,"/",len(indexes))
    print("Release listings:",sum(x["status"]=="listed" for x in releases),"/",len(releases))
    if not count:
        raise RuntimeError("No verified signed indexes; inspect report")

if __name__=="__main__":
    main()

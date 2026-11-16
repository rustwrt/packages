#!/usr/bin/env python3
"""Import only package sources from an explicitly selected committed WARP revision."""
import argparse, io, json, re, shutil, subprocess, tarfile, tempfile
from pathlib import Path

root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument("source",type=Path)
p.add_argument("revision")
args=p.parse_args()
source=args.source.resolve()
assert re.fullmatch(r"[0-9a-f]{40}",args.revision), "Full commit SHA required"
def git(*argv):
 return subprocess.check_output(["git","-c","safe.directory="+str(source),"-C",str(source),*argv])
assert git("rev-parse",args.revision+"^{commit}").decode().strip()==args.revision
mapping={"cloudflare-warp":"net/cloudflare-warp","luci-proto-warp":"luci/luci-proto-warp"}
with tempfile.TemporaryDirectory() as tmp:
 stage=Path(tmp)
 for name,target in mapping.items():
  paths=[name+"/Makefile",name+"/files"]
  if name=="luci-proto-warp": paths.append(name+"/po")
  with tarfile.open(fileobj=io.BytesIO(git("archive",args.revision,*paths))) as archive:
   for member in archive.getmembers():
    rel=Path(member.name)
    if rel.is_absolute() or ".." in rel.parts or not (member.isdir() or member.isfile()):
     raise ValueError("Unsafe source member")
    if member.isfile():
     assert not rel.name.endswith((".bak",".ipk",".apk",".key",".lmo"))
     dest=stage/target/Path(*rel.parts[1:])
     dest.parent.mkdir(parents=True,exist_ok=True)
     dest.write_bytes(archive.extractfile(member).read())
     dest.chmod(member.mode & 0o777)
  assert (stage/target/"Makefile").is_file()
 for target in mapping.values():
  dest=root/target
  if dest.exists(): shutil.rmtree(dest)
  dest.parent.mkdir(parents=True,exist_ok=True)
  shutil.copytree(stage/target,dest)
 provenance=root/"provenance.json"
 records=json.loads(provenance.read_text()) if provenance.exists() else {"schema_version":1,"projects":{}}
 records["projects"]["warp"]={"repository":"rustwrt/luci-proto-warp","revision":args.revision,"directories":list(mapping.values())}
 provenance.write_text(json.dumps(records,indent=2)+"\n")
print("Imported WARP source",args.revision)

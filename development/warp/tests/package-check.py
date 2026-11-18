#!/usr/bin/env python3
"""Validate native IPK control metadata, runtime payload and scripts."""
import importlib.util,io,pathlib,sys,tarfile
root=pathlib.Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("metadata",root/"tools/build-test-apk.py")
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
out=pathlib.Path(sys.argv[1])
for name in builder.NAMES:
 paths=list(out.glob(f"{name}_0.3.0-*2_all.ipk"))
 assert len(paths)==1,paths
 path=paths[0]
 with tarfile.open(path,"r:*") as outer:
  parts={m.name.removeprefix("./"):outer.extractfile(m).read() for m in outer if m.isfile()}
 assert parts["debian-binary"]==b"2.0\n"
 with tarfile.open(fileobj=io.BytesIO(parts["control.tar.gz"])) as t:
  members={m.name.removeprefix("./"):m for m in t if m.isfile()}
  control=t.extractfile(members["control"]).read().decode()
  assert "postinst" in members and "prerm" in members
  if name=="luci-proto-warp":
   script=t.extractfile(members["postinst-pkg"]).read().decode()
   assert 'IPKG_INSTROOT' in script
   assert '/tmp/luci-modulecache/' in script
   assert '/etc/init.d/rpcd reload' in script
   assert 'network get_proto_handlers' in script
   assert '/etc/init.d/network restart' not in script
 fields=dict(x.split(": ",1) for x in control.splitlines() if ": " in x)
 assert path.name == f"{name}_{fields['Version']}_all.ipk"
 assert fields["Package"]==name and fields["Version"] in ("0.3.0-2","0.3.0-r2") and fields["Architecture"]=="all",fields
 package,_,deps,_=builder.definition(name)
 actual={x.strip().split()[0] for x in fields["Depends"].split(",")}
 assert set(d for d in deps if not d.startswith("!"))<=actual,fields
 assert "lua" not in actual and "lua-cjson" not in actual
 with tarfile.open(fileobj=io.BytesIO(parts["data.tar.gz"])) as t:
  members={m.name.removeprefix("./"):m for m in t if m.isfile()}
  assert all(m.uid==0 and m.gid==0 for m in members.values())
  assert not any(m.issym() or m.islnk() for m in t.getmembers())
  if name=="luci-i18n-warp-vi":
   assert members["usr/lib/lua/luci/i18n/warp.vi.lmo"].size>0
   assert not any(x.startswith("etc/uci-defaults/") for x in members)
  else:
   for f in (package/"files").rglob("*"):
    if f.is_file():
     rel=f.relative_to(package/"files").as_posix()
     assert t.extractfile(members[rel]).read()==f.read_bytes(),rel
     assert members[rel].mode==(0o755 if rel in builder.EXEC else 0o644),rel
 print("PASS:",path.name)

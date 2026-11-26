import gzip,urllib.request,pathlib
base='https://downloads.openwrt.org/releases/24.10.4/packages/x86_64/base/'
raw=urllib.request.urlopen(base+'Packages.gz',timeout=25).read()
records=gzip.decompress(raw).decode().split('\n\n')
record=next((x for x in records if x.startswith('Package: umdns\n')),None)
if not record: raise RuntimeError('umdns package not found')
print(record)
filename=next(x.split(': ',1)[1] for x in record.splitlines() if x.startswith('Filename: '))
out=pathlib.Path('/tmp/sponsorblocktv-pkgs')
out.mkdir(exist_ok=True)
(out/filename).write_bytes(urllib.request.urlopen(base+filename,timeout=25).read())
print('DOWNLOADED',out/filename)

#!/bin/sh
# Build and sign an index from the IPKs in a release directory.
set -eu
if [ "$#" != 4 ]; then
    echo "Usage: $0 SDK FEED_DIRECTORY PRIVATE_KEY PUBLIC_KEY" >&2
    exit 2
fi
sdk=$(realpath "$1")
feed=$(realpath "$2")
key=$(realpath "$3")
public=$(realpath "$4")
cd "$feed"
sign="$sdk/staging_dir/host/bin/usign"
MKHASH="$sdk/staging_dir/host/bin/mkhash" "$sdk/scripts/ipkg-make-index.sh" . >Packages.new
# Reject ambiguous candidates and verify that every indexed download matches its IPK.
python3 - <<'PYINDEX'
from pathlib import Path
import hashlib
import re

seen = set()
files = set()
for stanza in Path("Packages.new").read_text().strip().split("\n\n"):
    fields = dict(re.findall(r"^(\S+): (.+)$", stanza, re.M))
    name = fields["Package"]
    filename = fields["Filename"]
    path = Path(filename)
    if name in seen or path.name != filename or not path.is_file():
        raise SystemExit(f"Invalid feed entry for {name}: {filename}")
    if path.stat().st_size != int(fields["Size"]) or hashlib.sha256(path.read_bytes()).hexdigest() != fields["SHA256sum"]:
        raise SystemExit(f"Metadata mismatch for {filename}")
    seen.add(name)
    files.add(path)
if not seen or files != set(Path(".").glob("*.ipk")):
    raise SystemExit("Index does not cover all IPKs")
PYINDEX
"$sign" -S -m Packages.new -s "$key" -x Packages.sig.new
"$sign" -V -m Packages.new -p "$public" -x Packages.sig.new
gzip -nc Packages.new >Packages.gz.new
cp "$public" feed.pub.new
for file in Packages Packages.gz Packages.sig feed.pub; do mv "$file.new" "$file"; done

#!/bin/sh
# Build either native format from a fresh matching OpenWrt SDK.
set -eu
test "$#" -ge 2 && test "$#" -le 3 || { echo "usage: $0 SDK NEW_OUTPUT [auto|both]" >&2; exit 2; }
test "$(id -u)" != 0 || { echo "Use an unprivileged SDK build user" >&2; exit 1; }
mode="${3:-auto}"
case "$mode" in auto|both) ;; *) exit 2;; esac
src=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sdk=$(realpath "$1")
output=$(realpath -m "$2")
test -f "$sdk/rules.mk"
test ! -e "$sdk/package/warp-project"
test ! -e "$output"
cd "$sdk"
mkdir -p package/warp-project
for package in cloudflare-warp luci-proto-warp; do
 mkdir "package/warp-project/$package"
 cp "$src/$package/Makefile" "package/warp-project/$package/"
 cp -r "$src/$package/files" "package/warp-project/$package/"
done
cp -r "$src/luci-proto-warp/po" package/warp-project/luci-proto-warp/
./scripts/feeds update -a
./scripts/feeds install -a
printf '\nCONFIG_ALL_NONSHARED=n\nCONFIG_ALL_KMODS=n\nCONFIG_ALL=n\nCONFIG_LUCI_LANG_vi=y\nCONFIG_PACKAGE_cloudflare-warp=m\nCONFIG_PACKAGE_luci-proto-warp=m\nCONFIG_PACKAGE_luci-i18n-warp-vi=m\n' >> .config
make defconfig
for package in cloudflare-warp luci-proto-warp luci-i18n-warp-vi; do
 grep -Eq "^CONFIG_PACKAGE_$package=[my]$" .config || { echo "Not selected: $package" >&2; exit 1; }
done
make package/warp-project/cloudflare-warp/compile -j2 V=s
make package/warp-project/luci-proto-warp/compile -j2 V=s
collect() {
 format="$1"; dest="$2"
 mkdir -p "$dest"
 for package in cloudflare-warp luci-proto-warp luci-i18n-warp-vi; do
  if [ "$format" = apk ]; then pattern="$package-0.3.0-r2.apk"; else pattern="${package}_0.3.0-*2_all.ipk"; fi
  found=$(find bin/packages -type f -name "$pattern")
  test -n "$found" && test "$(printf '%s\n' "$found" | grep -c .)" = 1
  cp "$found" "$dest/"
 done
}
if grep -q '^CONFIG_USE_APK=y$' .config; then native=apk; else native=ipk; fi
if [ "$mode" = auto ]; then
 collect "$native" "$output"
else
 test "$native" = apk || { echo 'both requires an APK SDK with IPK packaging support' >&2; exit 1; }
 test -x scripts/ipkg-build
 collect apk "$output/apk"
 # Repackage only WARP via native IPK branch; prerequisites already built.
 # Bypass the global APK dependency metadata when selecting only the IPK
 # packaging code. Invoke native SDK package targets directly.
 (
  export TOPDIR="$sdk" SDK=1 INCLUDE_DIR="$sdk/include" LC_ALL=C LANG=C
  export PATH="$sdk/staging_dir/host/bin:$sdk/staging_dir/hostpkg/bin:$PATH"
  for p in cloudflare-warp luci-proto-warp; do
   make -r -C "package/warp-project/$p" BUILD_SUBDIR="package/warp-project/$p" CONFIG_USE_APK= clean
   make -r -C "package/warp-project/$p" BUILD_SUBDIR="package/warp-project/$p" CONFIG_USE_APK= compile V=s
  done
 )
 collect ipk "$output/ipk"
 python3 "$src/tests/package-check.py" "$output/ipk"
fi
printf '%s\n' 'Native SDK package build complete.'

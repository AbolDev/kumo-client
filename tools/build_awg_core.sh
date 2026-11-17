#!/usr/bin/env bash
# Builds kumo-awg, the program that carries AmneziaWG servers on a computer: sing-box with an endpoint of type "amneziawg"
# (tools/libbox_patch/amneziawg). The cores of the computers are the official sing-box releases, which have no such endpoint, so
# the core sends what goes through such a server to the local SOCKS port of this program, as it does for Xray (see
# lib/core/desktop_vpn.dart). It runs `kumo-awg run -c config.json` like sing-box.
#
#   bash tools/build_awg_core.sh <goos> <goarch> <output file>
#   bash tools/build_awg_core.sh darwin universal macos/core/kumo-awg      (Intel and Apple silicon in one file; needs lipo)
set -euo pipefail

goos="${1:?goos: windows, linux or darwin}"
goarch="${2:?goarch: amd64, arm64 or (darwin) universal}"
out="${3:?the output file}"
SING_BOX="${SING_BOX:-1.13.21}"

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$out")"
abs="$(cd "$(dirname "$out")" && (pwd -W 2>/dev/null || pwd))/$(basename "$out")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --depth 1 --branch "v$SING_BOX" https://github.com/SagerNet/sing-box.git "$tmp/sb"
bash "$root/tools/libbox_patch/apply_amneziawg.sh" "$tmp/sb"

build() { # goarch, file
  (cd "$tmp/sb" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$1" GOTOOLCHAIN=auto go build -trimpath -buildvcs=false \
    -tags "with_gvisor,badlinkname,tfogo_checklinkname0" \
    -ldflags "-s -w -buildid= -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$SING_BOX" \
    -o "$2" ./cmd/sing-box)
}

if [ "$goarch" = universal ]; then
  [ "$goos" = darwin ] || { echo "universal is for darwin only" >&2; exit 1; }
  build amd64 "$tmp/awg-amd64"
  build arm64 "$tmp/awg-arm64"
  lipo -create "$tmp/awg-amd64" "$tmp/awg-arm64" -output "$abs"
else
  build "$goarch" "$abs"
fi
chmod +x "$abs" 2>/dev/null || true
ls -l "$abs"
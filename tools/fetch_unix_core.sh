#!/usr/bin/env bash
# Downloads the official sing-box and Xray-core builds for Linux or macOS and puts them in
# <platform>/core, from where the build copies them next to the program.
#
#   kumo-core    sing-box (TUN, routing, all protocols except XHTTP and the like)
#   kumo-xray    Xray-core (XHTTP, mKCP, VLESS encryption ... and the chosen default core)
#   libcronet.so NaiveProxy support on Linux (macOS builds have none)
#
# Usage: tools/fetch_unix_core.sh linux|macos
set -euo pipefail

os="${1:?usage: fetch_unix_core.sh linux|macos}"
SING_BOX="${SING_BOX:-1.13.21}"
XRAY="${XRAY:-v26.10.21}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/$os/core"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"

get() { curl -fsSL --retry 3 "$1" -o "$2"; }
box_url() { echo "https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX/sing-box-$SING_BOX-$1.tar.gz"; }
xray_url() { echo "https://github.com/XTLS/Xray-core/releases/download/$XRAY/Xray-$1.zip"; }

if [ "$os" = linux ]; then
  get "$(box_url linux-amd64)" "$tmp/box.tgz"
  tar -xzf "$tmp/box.tgz" -C "$tmp"
  cp "$tmp"/sing-box-*/sing-box "$out/kumo-core"
  cp "$tmp"/sing-box-*/libcronet.so "$out/libcronet.so" 2>/dev/null || true

  get "$(xray_url linux-64)" "$tmp/xray.zip"
  unzip -q -o "$tmp/xray.zip" xray -d "$tmp/xray"
  cp "$tmp/xray/xray" "$out/kumo-xray"
else
  # One universal binary (Intel + Apple silicon) for each core.
  for arch in amd64 arm64; do
    get "$(box_url darwin-$arch)" "$tmp/box-$arch.tgz"
    mkdir -p "$tmp/box-$arch"
    tar -xzf "$tmp/box-$arch.tgz" -C "$tmp/box-$arch"
  done
  lipo -create "$tmp"/box-amd64/sing-box-*/sing-box "$tmp"/box-arm64/sing-box-*/sing-box -output "$out/kumo-core"

  get "$(xray_url macos-64)" "$tmp/xray-64.zip"
  get "$(xray_url macos-arm64-v8a)" "$tmp/xray-arm.zip"
  unzip -q -o "$tmp/xray-64.zip" xray -d "$tmp/xray-64"
  unzip -q -o "$tmp/xray-arm.zip" xray -d "$tmp/xray-arm"
  lipo -create "$tmp/xray-64/xray" "$tmp/xray-arm/xray" -output "$out/kumo-xray"
fi

chmod +x "$out"/kumo-core "$out"/kumo-xray
ls -l "$out"

#!/usr/bin/env bash
# Builds kumo-slip, the program that carries the DNS tunnels (DNSTT, NoizDNS, VayDNS), the SSH tunnels and their transports:
# the command line client of SlipNet (https://github.com/anonvector/SlipNet, AGPL-3.0), built as it is, from a pinned commit.
# It is given a `slipnet://` link and opens a local SOCKS5 port:  kumo-slip --port 1080 --dns 1.1.1.1 'slipnet://...'
#
#   bash tools/build_slip.sh <goos> <goarch> <output file>
#   bash tools/build_slip.sh android arm64 out/libslip.so      (needs ANDROID_NDK_HOME; goarch arm64, arm or amd64)
set -euo pipefail

goos="${1:?goos: windows, linux, darwin or android}"
goarch="${2:?goarch: amd64, arm64 or arm}"
out="${3:?the output file}"
SLIPNET_COMMIT="${SLIPNET_COMMIT:-2ed00fd0072ad0b558e30ec6b5e8b30948f98894}"
SLIPNET_DIR="${SLIPNET_DIR:-}"

mkdir -p "$(dirname "$out")"
abs="$(cd "$(dirname "$out")" && (pwd -W 2>/dev/null || pwd))/$(basename "$out")"

if [ -z "$SLIPNET_DIR" ]; then
  SLIPNET_DIR="$(mktemp -d)/SlipNet"
  git clone --filter=blob:none --no-checkout https://github.com/anonvector/SlipNet.git "$SLIPNET_DIR"
  git -C "$SLIPNET_DIR" checkout --quiet "$SLIPNET_COMMIT"
  git -C "$SLIPNET_DIR" submodule update --init --depth 1 dnstt noizdns vaydns vaydns-mobile
fi

cd "$SLIPNET_DIR/cli"
# The list of resolvers is embedded in the program (the Makefile copies it the same way).
cp ../app/src/main/res/raw/resolvers.txt resolvers.txt
rm -f key_generated.go

export GOTOOLCHAIN=auto
flags=(-trimpath -buildvcs=false -ldflags "-s -w -buildid= -X main.version=kumo")
if [ "$goos" = android ]; then
  BIN="${ANDROID_NDK_HOME:?ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
  case "$goarch" in
    arm64) cc=aarch64-linux-android23-clang; arm= ;;
    arm) cc=armv7a-linux-androideabi23-clang; arm=7 ;;
    amd64) cc=x86_64-linux-android23-clang; arm= ;;
    *) echo "android: arm64, arm or amd64" >&2; exit 1 ;;
  esac
  CGO_ENABLED=1 CC="$BIN/$cc" GOOS=android GOARCH="$goarch" GOARM="$arm" go build "${flags[@]}" -o "$abs" .
else
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build "${flags[@]}" -o "$abs" .
fi
chmod +x "$abs" 2>/dev/null || true
ls -l "$abs"

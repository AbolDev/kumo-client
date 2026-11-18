#!/usr/bin/env bash
# Builds kumo-dns, the program that carries the DNS tunnels (DNSTT, VayDNS, NoizDNS, Soar) and the SSH tunnels for Kumo
# (tools/dnstunnels/main.go). It is made of the projects of those tunnels, each from a pinned commit:
#   VayDNS    github.com/net2share/vaydns       CC0       (it speaks the wire format of DNSTT too: that is what DNSTT is run with)
#   NoizDNS   github.com/anonvector/noizdns     AGPL-3.0  (with the dnstt it is made on: github.com/anonvector/dnstt, AGPL-3.0)
#   Soar      github.com/getlantern/soar        Apache-2.0
# It runs `kumo-dns run -c config.json` like Xray, and opens a local SOCKS5 port.
#
#   bash tools/build_dnstunnels.sh <goos> <goarch> <output file>
#   bash tools/build_dnstunnels.sh android arm64 out/libkumodns.so      (needs ANDROID_NDK_HOME; goarch arm64, arm or amd64)
set -euo pipefail

goos="${1:?goos: windows, linux, darwin or android}"
goarch="${2:?goarch: amd64, arm64 or arm}"
out="${3:?the output file}"
VAYDNS_COMMIT="${VAYDNS_COMMIT:-a0ff70110d5e96686ab8f4c8e1c44cd09be07a75}"
NOIZDNS_COMMIT="${NOIZDNS_COMMIT:-f76c585093c7c31e9be6c10a1b425be033eb4938}"
DNSTT_COMMIT="${DNSTT_COMMIT:-fcb87c37a1b36ef7cde08918deafd13fd5ebe6ff}"
SOAR_VERSION="${SOAR_VERSION:-latest}"
KCP_FORK="${KCP_FORK:-github.com/net2share/kcp-go/v5@v5.0.0-20260325165956-416ba9d3856d}"

root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$(dirname "$out")"
abs="$(cd "$(dirname "$out")" && (pwd -W 2>/dev/null || pwd))/$(basename "$out")"

# The sources are fetched once (DNSTUNNELS_SRC) when several programs are built one after the other.
src="${DNSTUNNELS_SRC:-}"
if [ -z "$src" ]; then
  src="$(mktemp -d)"
fi
fetch() { # name url commit
  if [ ! -d "$src/$1/.git" ]; then
    git clone --filter=blob:none --no-checkout "$2" "$src/$1"
    git -C "$src/$1" checkout --quiet "$3"
  fi
}
fetch vaydns https://github.com/net2share/vaydns.git "$VAYDNS_COMMIT"
fetch noizdns https://github.com/anonvector/noizdns.git "$NOIZDNS_COMMIT"
fetch dnstt https://github.com/anonvector/dnstt.git "$DNSTT_COMMIT"

work="$src/build-$goos-$goarch"
rm -rf "$work"
mkdir -p "$work"
cp "$root/tools/dnstunnels/main.go" "$work/main.go"
cd "$work"
cat > go.mod <<EOF
module kumodns

go 1.24

require (
	github.com/net2share/vaydns v0.0.0
	noizdns v0.0.0
	www.bamsoftware.com/git/dnstt.git v0.0.0
)

replace github.com/net2share/vaydns => $src/vaydns
replace noizdns => $src/noizdns
replace www.bamsoftware.com/git/dnstt.git => $src/dnstt
replace github.com/xtaci/kcp-go/v5 => ${KCP_FORK%@*} ${KCP_FORK#*@}
EOF

export GOTOOLCHAIN=auto GOFLAGS=-mod=mod
go get "github.com/getlantern/soar@$SOAR_VERSION" github.com/coder/websocket golang.org/x/crypto/ssh
go mod tidy

flags=(-trimpath -buildvcs=false -ldflags "-s -w -buildid=")
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

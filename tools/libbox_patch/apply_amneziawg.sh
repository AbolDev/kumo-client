#!/usr/bin/env bash
# Adds AmneziaWG to a sing-box source tree (the one libbox is built from): a WireGuard endpoint that runs on the reference
# amneziawg-go, as an endpoint of type "amneziawg". See tools/libbox_patch/amneziawg/README.md.
#
#   bash tools/libbox_patch/apply_amneziawg.sh <sing-box source directory>
set -euo pipefail

sb="${1:?the sing-box source directory}"
here="$(cd "$(dirname "$0")" && pwd)"
# The release of amneziawg-go that was tested (its module is a v3 one; its go.mod asks for Go 1.25).
AWG="${AWG:-v3.1.20261116}"

mkdir -p "$sb/transport/amneziawg" "$sb/protocol/amneziawg"
cp "$here"/amneziawg/transport/*.go "$sb/transport/amneziawg/"
cp "$here"/amneziawg/protocol/*.go "$sb/protocol/amneziawg/"
cp "$here/amneziawg/include_amneziawg.go.txt" "$sb/include/amneziawg.go"

# The registry of endpoints knows the new type.
if ! grep -q registerAmneziaWGEndpoint "$sb/include/registry.go"; then
  sed -i 's/^\([[:space:]]*\)registerWireGuardEndpoint(registry)$/&\n\1registerAmneziaWGEndpoint(registry)/' "$sb/include/registry.go"
  grep -q registerAmneziaWGEndpoint "$sb/include/registry.go" || { echo "could not register the endpoint in include/registry.go" >&2; exit 1; }
fi

# The module, at a release. Nothing else of go.mod may change: sing-box links into golang.org/x/net (a newer one does not
# link), so the versions it asks for stay.
net_before="$(cd "$sb" && go list -m -f '{{.Version}}' golang.org/x/net)"
(cd "$sb" && go get "github.com/amnezia-vpn/amneziawg-go/v3@$AWG")
net_after="$(cd "$sb" && go list -m -f '{{.Version}}' golang.org/x/net)"
if [ "$net_before" != "$net_after" ]; then
  echo "golang.org/x/net changed from $net_before to $net_after: sing-box would not link" >&2
  exit 1
fi
echo "AmneziaWG $AWG added to $sb (golang.org/x/net stays $net_after)"
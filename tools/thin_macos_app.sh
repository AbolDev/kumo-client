#!/usr/bin/env bash
# Makes a one-architecture copy of a universal macOS app: every universal Mach-O file in it is cut
# down to [arch], and the copy is signed again (ad hoc).
#
# Usage: tools/thin_macos_app.sh <universal.app> <copy.app> <arm64|x86_64>
set -euo pipefail

src="${1:?source .app}"
dst="${2:?destination .app}"
arch="${3:?arm64 or x86_64}"

rm -rf "$dst"
ditto "$src" "$dst"
find "$dst" -type f | while IFS= read -r f; do
  if file "$f" | grep -q "universal binary"; then
    mode="$(stat -f %Lp "$f")"
    lipo -thin "$arch" "$f" -output "$f.thin"
    mv "$f.thin" "$f"
    chmod "$mode" "$f"
  fi
done
codesign --force --deep --sign - "$dst"

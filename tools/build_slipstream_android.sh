#!/usr/bin/env bash
# Builds slipstream-client for Android (github.com/Mygod/slipstream-rust: Rust, with picoquic and OpenSSL built from source by the
# project's own build script for the phone's CPU). The program is named libslipstream.so so that Android lets the app run it.
#
#   bash tools/build_slipstream_android.sh <rust target> <abi> <source dir> <output file>
#   bash tools/build_slipstream_android.sh aarch64-linux-android arm64-v8a slipstream out/arm64-v8a/libslipstream.so
#
# Needs ANDROID_NDK_HOME, rustup with the target added, cmake, perl.
set -euo pipefail

target="${1:?rust target}"
abi="${2:?abi}"
src="${3:?source dir}"
out="${4:?output file}"
api="${ANDROID_API:-23}"

NDK="${ANDROID_NDK_HOME:?ANDROID_NDK_HOME}"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
case "$target" in
  aarch64-linux-android) clang="aarch64-linux-android$api-clang" ;;
  armv7-linux-androideabi) clang="armv7a-linux-androideabi$api-clang" ;;
  x86_64-linux-android) clang="x86_64-linux-android$api-clang" ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac
upper="$(echo "$target" | tr 'a-z-' 'A-Z_')"
export "CARGO_TARGET_${upper}_LINKER=$BIN/$clang"
export "CC_$(echo "$target" | tr '-' '_')=$BIN/$clang"
export "AR_$(echo "$target" | tr '-' '_')=$BIN/llvm-ar"
export ANDROID_ABI="$abi" ANDROID_PLATFORM="android-$api" ANDROID_NDK_HOME="$NDK"
export RUST_ANDROID_GRADLE_CC="$BIN/$clang" RUST_ANDROID_GRADLE_AR="$BIN/llvm-ar"

# OpenSSL's makefile calls the tools by the names of the old gcc toolchains (aarch64-linux-android-ranlib ...): the NDK has the
# LLVM ones, so a folder of links under those names comes first in the path.
shim="$(mktemp -d)"
for name in ar ranlib strip nm objcopy objdump readelf; do
  for triple in aarch64-linux-android arm-linux-androideabi armv7a-linux-androideabi armv7-linux-androideabi x86_64-linux-android; do
    ln -sf "$BIN/llvm-$name" "$shim/$triple-$name"
  done
done
export PATH="$shim:$BIN:$PATH"
mkdir -p "$(dirname "$out")"
abs="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
cd "$src"
# OpenSSL is built from source for the phone (the project's feature for it); picoquic by its own script.
cargo build -p slipstream-client --release --target "$target" --features openssl-vendored
cp "target/$target/release/slipstream-client" "$abs"
"$BIN/llvm-strip" "$abs" || true
chmod +x "$abs"
ls -l "$abs"

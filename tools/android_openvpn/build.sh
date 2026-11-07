#!/usr/bin/env bash
# Builds the OpenVPN program for Android (as the file libopenvpn.so, run as a program by the app) from
# the official source of OpenVPN with OpenSSL, LZO and LZ4 linked in. OpenVPN has the Android parts built
# into its own source (TARGET_ANDROID); only the build is done here, nothing of it is changed.
#
# Usage: build.sh <android ndk (linux)> <folder with the source files> <output folder> [abi ...]
# The source files and their SHA-256 are in sha256.txt (next to this script). The result is
# <output>/<abi>/libopenvpn.so for each abi (default: arm64-v8a armeabi-v7a x86_64).
set -euo pipefail

NDK=$(realpath "$1"); SRC=$(realpath "$2"); OUT=$(realpath -m "$3"); shift 3
ABIS=("$@"); [ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64-v8a armeabi-v7a x86_64)
HERE=$(cd "$(dirname "$0")" && pwd)
API=23
JOBS=$(nproc)
WORK=${WORK:-$(mktemp -d)}
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin

( cd "$SRC" && grep -E ' (openvpn|openssl|lzo|lz4)-' "$HERE/sha256.txt" | sha256sum -c - ) >&2

for abi in "${ABIS[@]}"; do
  case $abi in
    arm64-v8a)   TRIPLE=aarch64-linux-android;  CCT=aarch64-linux-android$API;    SSL=android-arm64 ;;
    armeabi-v7a) TRIPLE=arm-linux-androideabi;  CCT=armv7a-linux-androideabi$API;  SSL=android-arm ;;
    x86_64)      TRIPLE=x86_64-linux-android;   CCT=x86_64-linux-android$API;      SSL=android-x86_64 ;;
    *) echo "unknown abi $abi" >&2; exit 1 ;;
  esac
  B=$WORK/$abi; PREFIX=$B/prefix; rm -rf "$B"; mkdir -p "$PREFIX/lib" "$PREFIX/include"
  export CC=$TC/$CCT-clang AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib STRIP=$TC/llvm-strip
  export ANDROID_NDK_ROOT=$NDK PATH=$TC:$PATH
  # OpenVPN's configure insists on pkg-config being there, but every library is given to it by hand
  # below: this stands in for it (and finds nothing).
  mkdir -p "$B/bin"
  printf '#!/bin/sh\ncase "$1" in --version) echo 0.29.2;; --atleast-pkgconfig-version) exit 0;; *) exit 1;; esac\n' > "$B/bin/pkg-config"
  chmod +x "$B/bin/pkg-config"; export PATH=$B/bin:$PATH

  echo "== $abi: openssl" >&2
  tar -xzf "$SRC"/openssl-*.tar.gz -C "$B" && cd "$B"/openssl-*
  ./Configure $SSL -D__ANDROID_API__=$API no-shared no-tests no-ssl3 no-comp no-engine no-dso no-legacy \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" >/dev/null
  make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null
  [ -f "$PREFIX/lib/libcrypto.a" ] || PREFIX_LIB=lib64
  cd "$B"

  echo "== $abi: lzo" >&2
  tar -xzf "$SRC"/lzo-*.tar.gz -C "$B" && cd "$B"/lzo-*
  ./configure --host=$TRIPLE --prefix="$PREFIX" --disable-shared --enable-static >/dev/null
  make -j"$JOBS" >/dev/null && make install >/dev/null
  cd "$B"

  echo "== $abi: lz4" >&2
  tar -xzf "$SRC"/lz4-*.tar.gz -C "$B" && cd "$B"/lz4-*
  "$CC" -O2 -fPIC -c lib/lz4.c -o "$B/lz4.o"
  "$AR" rcs "$PREFIX/lib/liblz4.a" "$B/lz4.o"
  cp lib/lz4.h "$PREFIX/include/"
  cd "$B"

  echo "== $abi: openvpn" >&2
  tar -xzf "$SRC"/openvpn-*.tar.gz -C "$B" && cd "$B"/openvpn-*
  LIBDIR=$PREFIX/${PREFIX_LIB:-lib}
  ./configure --host=$TRIPLE --prefix="$B/install" \
    --disable-plugins --disable-debug --disable-dco --disable-systemd --disable-selinux \
    --disable-unit-tests --disable-pkcs11 --disable-plugin-auth-pam --disable-plugin-down-root \
    --enable-lzo --enable-lz4 --with-crypto-library=openssl \
    ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
    IFCONFIG=/system/bin/ifconfig ROUTE=/system/bin/route IPROUTE=/system/bin/ip NETSTAT=/system/bin/netstat \
    CFLAGS="-O2 -fPIE -DTARGET_ANDROID" LDFLAGS="-pie" \
    OPENSSL_CFLAGS="-I$PREFIX/include" OPENSSL_LIBS="-L$LIBDIR -lssl -lcrypto" \
    LZO_CFLAGS="-I$PREFIX/include" LZO_LIBS="-L$LIBDIR -llzo2" \
    LZ4_CFLAGS="-I$PREFIX/include" LZ4_LIBS="-L$LIBDIR -llz4" \
    LIBCAPNG_CFLAGS="-DOVPN_ANDROID_NO_CAPNG" LIBCAPNG_LIBS="-lm" >&2
  # On Android the tunnel is opened by the app (VpnService), not by OpenVPN: it is Android, not Linux.
  sed -i -e 's/^#define TARGET_LINUX 1$/\/* TARGET_LINUX is not set on Android *\//' -e 's/^#define HAVE_LIBCAPNG 1$/\/* no libcap-ng on Android *\//' -e 's/^#define ENABLE_FEATURE_TUN_PERSIST 1$/\/* no persistent tunnels on Android *\//' config.h
  make -j"$JOBS" -C src/compat >&2
  make -j"$JOBS" -C src/openvpn >&2
  mkdir -p "$OUT/$abi"
  "$STRIP" -o "$OUT/$abi/libopenvpn.so" src/openvpn/openvpn
  echo "== $abi: done ($(stat -c %s "$OUT/$abi/libopenvpn.so") bytes)" >&2
  unset PREFIX_LIB
done

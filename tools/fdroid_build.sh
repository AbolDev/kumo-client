#!/usr/bin/env bash
# Builds the native parts of the Android app from source, for the F-Droid recipe (and its test):
#   libbox.aar (sing-box) and the Xray executables, placed where the Gradle build looks for them.
#
# Usage: tools/fdroid_build.sh <go source dir> <sing-box source dir> <Xray-core source dir> <Android NDK dir>
# The Go source dir must hold the Go release to build with; a Go from the system (GOROOT_BOOTSTRAP,
# /usr/lib/go by default) builds it first.
set -euo pipefail

GO_SRC=$(realpath "$1")
SB=$(realpath "$2")
XRAY=$(realpath "$3")
NDK=$(realpath "$4")
APP=$(pwd)
SING_BOX_VERSION=$(cd "$SB" && git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
SING_BOX_VERSION=${SING_BOX_VERSION:-1.13.21}

export GOROOT_BOOTSTRAP=${GOROOT_BOOTSTRAP:-/usr/lib/go}
(cd "$GO_SRC/src" && ./make.bash)
export GOROOT="$GO_SRC"
export PATH="$GO_SRC/bin:$PATH"
# the Go release in the source dir is the one to use: no toolchain is downloaded
export GOTOOLCHAIN=local
export ANDROID_NDK_HOME="$NDK"
go version

# ---- libbox.aar: sing-box for Android, with this project's patch
cp "$APP"/tools/libbox_patch/*.go "$SB/experimental/libbox/"
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
export PATH="$(go env GOPATH)/bin:$PATH"
(cd "$SB" && gomobile bind -v -o libbox.aar \
  -target android/arm64,android/arm,android/amd64 -androidapi 23 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=$SING_BOX_VERSION -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0" \
  -tags "with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard,with_dhcp,badlinkname,tfogo_checklinkname0" \
  ./experimental/libbox)
mkdir -p "$APP/android/app/libs"
cp "$SB/libbox.aar" "$APP/android/app/libs/libbox.aar"

# ---- Xray, one executable per CPU, named libxray.so so that Android lets the app run it
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
build_xray() { # abi goarch compiler [goarm]
  mkdir -p "$APP/android/app/src/main/jniLibs/$1"
  (cd "$XRAY" && GOOS=android CGO_ENABLED=1 GOARCH=$2 GOARM=${4:-} CC="$BIN/$3" \
    go build -o "$APP/android/app/src/main/jniLibs/$1/libxray.so" \
    -trimpath -buildvcs=false \
    -ldflags "-s -w -buildid= -checklinkname=0 -X github.com/xtls/xray-core/core.build=kumo" ./main)
}
build_xray arm64-v8a arm64 aarch64-linux-android23-clang
build_xray armeabi-v7a arm armv7a-linux-androideabi23-clang 7
build_xray x86_64 amd64 x86_64-linux-android23-clang
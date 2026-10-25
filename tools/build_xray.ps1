# Builds the Xray-core executable for Android arm64 from the official XTLS/Xray-core source.
# Kumo runs it as a separate process (never as a library: two gomobile cores cannot share one app)
# and only for XHTTP configs, which sing-box cannot handle.
#
# Output: android/app/src/main/jniLibs/arm64-v8a/libxray.so
# (it is an executable; the "lib*.so" name makes Android extract it into the app's native library
#  directory, the one place an app is still allowed to execute files from).
param(
    [string]$Version = "v26.10.21"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$src = "$root\third_party\xray-core"

if (-not (Test-Path $src)) {
    git clone --depth 1 --branch $Version https://github.com/XTLS/Xray-core.git $src
}

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = Get-ChildItem "$sdk\ndk" | Sort-Object Name -Descending | Select-Object -First 1
$bin = "$($ndk.FullName)\toolchains\llvm\prebuilt\windows-x86_64\bin"

$env:GOPROXY = "https://goproxy.cn,direct"   # proxy.golang.org returns 403 from Iran
$env:GOTOOLCHAIN = "go1.27.3"                 # go.mod asks for "go 1.27", which has no toolchain of its own
$env:GOOS = "android"
$env:GOARCH = "arm64"
$env:CGO_ENABLED = "1"                        # android needs the NDK linker (PIE executable)
$env:CC = "$bin\aarch64-linux-android23-clang.cmd"

$out = "$root\android\app\src\main\jniLibs\arm64-v8a"
New-Item -ItemType Directory -Force $out | Out-Null

Push-Location $src
try {
    go build -o "$out\libxray.so" -trimpath -buildvcs=false `
        -ldflags "-s -w -buildid= -checklinkname=0 -X github.com/xtls/xray-core/core.build=kumo" `
        ./main
    if ($LASTEXITCODE -ne 0) { throw "go build failed ($LASTEXITCODE)" }
    $size = [math]::Round((Get-Item "$out\libxray.so").Length / 1MB, 1)
    Write-Host "OK -> $out\libxray.so ($size MB)"
} finally {
    Pop-Location
}

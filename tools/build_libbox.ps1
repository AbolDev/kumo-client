# Builds libbox.aar (sing-box core for Android) from the official SagerNet/sing-box source.
# Prerequisites: Go, Android SDK + NDK (r27+), Android Studio's JBR (javac), git.
#   third_party/sing-box must be checked out at the tag matching $Version.
param(
    [string]$Version = "1.13.21",
    [string]$Targets = "android/arm64"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { "$env:LOCALAPPDATA\Android\Sdk" }
$ndk = Get-ChildItem "$sdk\ndk" | Sort-Object Name -Descending | Select-Object -First 1
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_NDK_HOME = $ndk.FullName
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
$env:GOPROXY = "https://goproxy.cn,direct"   # proxy.golang.org returns 403 from Iran
$env:GOTOOLCHAIN = "auto"
$env:PATH = "$env:JAVA_HOME\bin;$(go env GOPATH)\bin;$env:PATH"

# gomobile fork used by sing-box (version pinned in sing-box's go.mod)
if (-not (Get-Command gomobile -ErrorAction SilentlyContinue)) {
    go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
    go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
}

$ldflags = "-X github.com/sagernet/sing-box/constant.Version=$Version " +
           "-X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0"
# No naive/tailscale/wireguard: they pull extra native deps and we only need proxy protocols.
$tags = "with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard,with_dhcp,badlinkname,tfogo_checklinkname0"

Push-Location "$root\third_party\sing-box"
try {
    # Kumo's own additions to libbox (real-delay test)
    Copy-Item "$root\tools\libbox_patch\*.go" "$root\third_party\sing-box\experimental\libbox\" -Force
    $bindArgs = @(
        "bind", "-v",
        "-o", "libbox.aar",
        "-target", $Targets,
        "-androidapi", "23",
        "-javapkg=io.nekohasekai",
        "-libname=box",
        "-trimpath", "-buildvcs=false",
        "-ldflags", $ldflags,
        "-tags", $tags,
        "./experimental/libbox"
    )
    & gomobile @bindArgs
    if ($LASTEXITCODE -ne 0) { throw "gomobile bind failed ($LASTEXITCODE)" }
    New-Item -ItemType Directory -Force "$root\android\app\libs" | Out-Null
    Copy-Item libbox.aar "$root\android\app\libs\libbox.aar" -Force
    Write-Host "OK -> android/app/libs/libbox.aar"
} finally {
    Pop-Location
}

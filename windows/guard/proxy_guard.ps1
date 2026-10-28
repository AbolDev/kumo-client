# Started by Kumo while the system proxy points at its own port. When Kumo ends in any way (closed,
# crashed, killed) this takes the proxy away from the Windows settings, so that the internet does not
# stay pointed at a port nobody listens on until Kumo is opened again. A proxy that belongs to another
# program is left alone. The full previous setting is put back by Kumo at its next start.
param(
    [Parameter(Mandatory = $true)][int]$AppPid,
    [Parameter(Mandatory = $true)][int]$Port,
    # (tests point this at a key of their own)
    [string]$Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
)
$ErrorActionPreference = 'SilentlyContinue'

Wait-Process -Id $AppPid

$server = (Get-ItemProperty -Path $Key).ProxyServer
if ($server -match "(^|[=;\s])(127\.0\.0\.1|localhost):$Port(;|$)") {
    Set-ItemProperty -Path $Key -Name ProxyEnable -Value 0 -Type DWord
    Remove-ItemProperty -Path $Key -Name ProxyServer
}

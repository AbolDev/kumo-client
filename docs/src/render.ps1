# Renders docs/images/banner.png and docs/images/devices.png from docs/src/showcase.html with
# headless Chrome (or Edge). Needs network once for the Roboto font.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$page = (Resolve-Path "$here\showcase.html").Path.Replace('\', '/')
$out = Join-Path (Split-Path -Parent $here) 'images'
New-Item -ItemType Directory -Force $out | Out-Null
$browser = @(
  'C:\Program Files\Google\Chrome\Application\chrome.exe',
  'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

function Render($mode, $w, $h, $file, $transparent) {
  $args = @('--headless=new', '--disable-gpu', '--hide-scrollbars', "--window-size=$w,$h",
    '--virtual-time-budget=8000', "--screenshot=$out\$file", "file:///$page#$mode")
  if ($transparent) { $args = @('--default-background-color=00000000') + $args }
  & $browser @args | Out-Null
}
Render 'banner' 1774 887 'banner.png' $false
Render 'devices' 1260 800 'devices.png' $true

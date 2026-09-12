#Requires -Version 5.1
<#
.SYNOPSIS
  Ship the captive-portal files to the Pi and run setup.sh over SSH.
.DESCRIPTION
  Windows-native: uses the OpenSSH ssh/scp bundled with Windows 10/11.
  Reads portal.env for the Pi target (PI_HOST/PI_USER), stages the payload with
  LF line endings, scp's it to the Pi, then runs `sudo ./setup.sh`.

  RUN THIS OVER ETHERNET. setup.sh takes wlan0 away from NetworkManager; if the
  Pi is reached over the Wi-Fi you're repurposing, you'll lose it mid-run.
.PARAMETER Rollback
  Run `sudo ./setup.sh rollback` on the Pi instead of install.
.PARAMETER PiHost
  Override PI_HOST from portal.env.
.PARAMETER PiUser
  Override PI_USER from portal.env.
.EXAMPLE
  .\deploy.ps1
.EXAMPLE
  .\deploy.ps1 -PiHost 192.168.1.42 -PiUser pi
.EXAMPLE
  .\deploy.ps1 -Rollback
#>
[CmdletBinding()]
param(
  [switch]$Rollback,
  [switch]$PageOnly,
  [string]$PiHost,
  [string]$PiUser
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir 'portal.env'

function Fail($msg) { Write-Error $msg; exit 1 }

# --- Preflight: OpenSSH client present? ---
foreach ($cmd in 'ssh','scp') {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Fail "'$cmd' not found. Install the Windows OpenSSH Client:
  Settings > System > Optional features > Add > OpenSSH Client
  (or: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0)"
  }
}

if (-not (Test-Path $envFile)) {
  Fail "portal.env not found. Copy portal.env.example to portal.env and edit it:`n  Copy-Item portal.env.example portal.env"
}

# --- Parse portal.env (KEY=VALUE, ignore comments/blank) ---
$cfg = @{}
foreach ($line in Get-Content $envFile) {
  $t = $line.Trim()
  if ($t -eq '' -or $t.StartsWith('#')) { continue }
  $kv = $t -split '=', 2
  if ($kv.Count -eq 2) {
    # strip inline comment + surrounding whitespace/quotes
    $val = ($kv[1] -replace '\s+#.*$', '').Trim().Trim('"').Trim("'")
    $cfg[$kv[0].Trim()] = $val
  }
}

if (-not $PiHost) { $PiHost = $cfg['PI_HOST'] }
if (-not $PiUser) { $PiUser = $cfg['PI_USER'] }
if (-not $PiHost) { Fail 'PI_HOST not set (portal.env or -PiHost).' }
if (-not $PiUser) { Fail 'PI_USER not set (portal.env or -PiUser).' }

$target    = "$PiUser@$PiHost"
$remoteDir = "/home/$PiUser/pi-captive-portal"

Write-Host "Target : $target" -ForegroundColor Cyan
Write-Host "Remote : $remoteDir" -ForegroundColor Cyan

if ($Rollback) {
  Write-Host "`nRolling back on the Pi..." -ForegroundColor Yellow
  & ssh $target "sudo bash '$remoteDir/setup.sh' rollback"
  if ($LASTEXITCODE -ne 0) { Fail "Rollback failed (exit $LASTEXITCODE)." }
  Write-Host "Rollback complete." -ForegroundColor Green
  exit 0
}

# --- LF-normalizing scp helper: stage www/, ship, sudo-install into web root ---
function Push-WebContent {
  $wwwSrc = Join-Path $scriptDir 'www'
  if (-not (Test-Path $wwwSrc)) { Fail "Missing 'www' — nothing to push." }

  $wstage = Join-Path ([System.IO.Path]::GetTempPath()) ("picp_www_" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $wstage -Force | Out-Null
  try {
    $textExt = '.html','.css','.js','.txt','.svg'
    Get-ChildItem -Path $wwwSrc -File | ForEach-Object {
      $dst = Join-Path $wstage $_.Name
      if ($textExt -contains $_.Extension.ToLower()) {
        $raw = [System.IO.File]::ReadAllText($_.FullName)
        $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        [System.IO.File]::WriteAllText($dst, $lf, (New-Object System.Text.UTF8Encoding($false)))
      } else {
        Copy-Item $_.FullName $dst -Force
      }
    }

    Write-Host "Pushing web content -> /var/www/portal ..." -ForegroundColor Cyan
    $remoteTmp = "/tmp/portal_www"
    & ssh $target "rm -rf '$remoteTmp' && mkdir -p '$remoteTmp'"
    if ($LASTEXITCODE -ne 0) { Fail "Could not prep $remoteTmp on the Pi." }
    & scp -q (Join-Path $wstage '*') "${target}:${remoteTmp}/"
    if ($LASTEXITCODE -ne 0) { Fail "scp of web content failed (exit $LASTEXITCODE)." }
    # nginx serves static files — no reload needed for content changes.
    & ssh $target "sudo mkdir -p /var/www/portal && sudo cp -f $remoteTmp/* /var/www/portal/ && sudo chmod 644 /var/www/portal/* && rm -rf '$remoteTmp'"
    if ($LASTEXITCODE -ne 0) { Fail "Installing web content on the Pi failed (exit $LASTEXITCODE)." }
  }
  finally {
    Remove-Item -Path $wstage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($PageOnly) {
  Push-WebContent
  Write-Host "`nPage updated. Reload http://$($cfg['PORTAL_IP'])/portal on a client." -ForegroundColor Green
  exit 0
}

# --- Stage payload with LF line endings so bash on the Pi is happy ---
$items = @('setup.sh','portal.env','config','www')
foreach ($i in $items) {
  if (-not (Test-Path (Join-Path $scriptDir $i))) { Fail "Missing '$i' — nothing to deploy." }
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("picp_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  # Text extensions to normalize; everything else copied byte-for-byte.
  $textExt = '.sh','.env','.conf','.tmpl','.html','.network','.md'
  foreach ($i in $items) {
    $src = Join-Path $scriptDir $i
    Copy-Item -Path $src -Destination $stage -Recurse -Force
  }
  Get-ChildItem -Path $stage -Recurse -File | ForEach-Object {
    if ($textExt -contains $_.Extension.ToLower()) {
      $raw = [System.IO.File]::ReadAllText($_.FullName)
      $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
      # write UTF-8 without BOM
      [System.IO.File]::WriteAllText($_.FullName, $lf, (New-Object System.Text.UTF8Encoding($false)))
    }
  }

  Write-Host "`nStaged $($items.Count) items with LF endings." -ForegroundColor DarkGray

  # --- Ship it: fresh remote dir, scp payload ---
  Write-Host "Creating remote dir + copying files..." -ForegroundColor Cyan
  & ssh $target "rm -rf '$remoteDir' && mkdir -p '$remoteDir'"
  if ($LASTEXITCODE -ne 0) { Fail "Could not prepare $remoteDir on the Pi." }

  foreach ($i in $items) {
    & scp -q -r (Join-Path $stage $i) "${target}:${remoteDir}/"
    if ($LASTEXITCODE -ne 0) { Fail "scp of '$i' failed (exit $LASTEXITCODE)." }
  }
}
finally {
  Remove-Item -Path $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Run setup.sh on the Pi ---
Write-Host "`nRunning setup.sh on the Pi (sudo)..." -ForegroundColor Cyan
Write-Host "  (you may be prompted for the Pi's sudo password)" -ForegroundColor DarkGray
& ssh -t $target "chmod +x '$remoteDir/setup.sh' && sudo bash '$remoteDir/setup.sh' install"
if ($LASTEXITCODE -ne 0) { Fail "setup.sh failed (exit $LASTEXITCODE)." }

Write-Host "`nDeploy complete." -ForegroundColor Green
Write-Host "SSID '$($cfg['SSID'])' should be live; portal at http://$($cfg['PORTAL_IP'])/portal" -ForegroundColor Green

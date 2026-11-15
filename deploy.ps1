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

  Run with NO arguments for an interactive menu.
.PARAMETER Rollback
  Run `sudo ./setup.sh rollback` on the Pi instead of install.
.PARAMETER PageOnly
  Push only www/* to /var/www/portal (fast page iteration, no reinstall).
.PARAMETER Guestbook
  Push only guestbook/* to /opt/guestbook and restart the service.
.PARAMETER PullGuestbook
  Export all guestbook posts from the Pi to a local CSV.
.PARAMETER PullJson
  Export all guestbook posts (incl. captured meta) from the Pi to a local JSON.
.PARAMETER PullProbes
  Export captured Wi-Fi probe-request data from the Pi to a local CSV.
.PARAMETER PullAll
  Pull both datasets in one go: guestbook JSON + probes CSV (ignores -OutFile,
  uses default timestamped names for each).
.PARAMETER PullGuestbookPurge
  Download the guestbook (JSON, incl. meta) AND THEN erase the entries on the Pi.
  Destructive: stops the guestbook, exports from the DB, verifies the local file,
  deletes all entries (visit counter kept), then restarts the service. The Pi is
  only cleared after a good local download; on any failure nothing is deleted.
.PARAMETER OutFile
  Destination for a single -Pull* export (default: <dataset>-<timestamp>.<ext>).
.PARAMETER PiHost
  Override PI_HOST from portal.env.
.PARAMETER PiUser
  Override PI_USER from portal.env.
.EXAMPLE
  .\deploy.ps1                       # interactive menu
.EXAMPLE
  .\deploy.ps1 -PageOnly
.EXAMPLE
  .\deploy.ps1 -PullGuestbook -OutFile posts.csv
.EXAMPLE
  .\deploy.ps1 -PullJson -OutFile posts.json
.EXAMPLE
  .\deploy.ps1 -PullProbes -OutFile probes.csv
.EXAMPLE
  .\deploy.ps1 -PullAll
.EXAMPLE
  .\deploy.ps1 -PullGuestbookPurge -OutFile posts-final.json   # download, then wipe the Pi
.EXAMPLE
  .\deploy.ps1 -Rollback
#>
[CmdletBinding()]
param(
  [switch]$Rollback,
  [switch]$PageOnly,
  [switch]$Guestbook,
  [switch]$PullGuestbook,
  [switch]$PullJson,
  [switch]$PullProbes,
  [switch]$PullAll,
  [switch]$PullGuestbookPurge,
  [string]$OutFile,
  [string]$PiHost,
  [string]$PiUser
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile   = Join-Path $scriptDir 'portal.env'

function Fail($msg) { Write-Error $msg; exit 1 }

# --- Interactive menu when run with no arguments ------------------------------
if ($PSBoundParameters.Count -eq 0) {
  Write-Host ""
  Write-Host "  pi-captive-portal deploy" -ForegroundColor Cyan
  Write-Host "  ========================" -ForegroundColor Cyan
  Write-Host "  1) Full deploy        (install / reconfigure on the Pi)"
  Write-Host "  2) Push page only     (www/* -> /var/www/portal)"
  Write-Host "  3) Push guestbook     (guestbook/* -> /opt/guestbook + restart)"
  Write-Host "  4) Pull guestbook CSV (export posts -> local CSV)"
  Write-Host "  5) Pull guestbook JSON (export posts + meta -> local JSON)"
  Write-Host "  6) Pull probe data    (export probe-requests -> local CSV)"
  Write-Host "  7) Pull ALL data      (guestbook JSON + probes CSV)"
  Write-Host "  8) Pull + PURGE gbook (download JSON, then ERASE entries on the Pi)"
  Write-Host "  9) Rollback           (undo portal, hand wlan0 back)"
  Write-Host "  Q) Quit"
  Write-Host ""
  switch (Read-Host "  Choose") {
    '1'     { }                      # full deploy is the default path
    '2'     { $PageOnly = $true }
    '3'     { $Guestbook = $true }
    '4'     { $PullGuestbook = $true }
    '5'     { $PullJson = $true }
    '6'     { $PullProbes = $true }
    '7'     { $PullAll = $true }
    '8'     { $PullGuestbookPurge = $true }
    '9'     { $Rollback = $true }
    'q'     { Write-Host "  Bye." -ForegroundColor DarkGray; exit 0 }
    default { Fail "Unknown choice." }
  }
}

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

# --- Quick-push the guestbook app + restart its service (no full reinstall) ---
function Push-Guestbook {
  $gbSrc = Join-Path $scriptDir 'guestbook'
  if (-not (Test-Path $gbSrc)) { Fail "Missing 'guestbook' — nothing to push." }

  $gstage = Join-Path ([System.IO.Path]::GetTempPath()) ("picp_gb_" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $gstage -Force | Out-Null
  try {
    Copy-Item -Path $gbSrc -Destination $gstage -Recurse -Force
    $textExt = '.py','.service','.txt','.html','.css','.js'
    Get-ChildItem -Path $gstage -Recurse -File | ForEach-Object {
      if ($textExt -contains $_.Extension.ToLower()) {
        $raw = [System.IO.File]::ReadAllText($_.FullName)
        $lf  = $raw -replace "`r`n", "`n" -replace "`r", "`n"
        [System.IO.File]::WriteAllText($_.FullName, $lf, (New-Object System.Text.UTF8Encoding($false)))
      }
    }

    Write-Host "Pushing guestbook app -> /opt/guestbook ..." -ForegroundColor Cyan
    $remoteTmp = "/tmp/portal_gb"
    & ssh $target "rm -rf '$remoteTmp' && mkdir -p '$remoteTmp'"
    if ($LASTEXITCODE -ne 0) { Fail "Could not prep $remoteTmp on the Pi." }
    & scp -q -r (Join-Path $gstage 'guestbook/*') "${target}:${remoteTmp}/"
    if ($LASTEXITCODE -ne 0) { Fail "scp of guestbook failed (exit $LASTEXITCODE)." }
    # Sync app + templates (not the service unit — install.sh owns that), fix perms, restart.
    & ssh $target @"
sudo mkdir -p /opt/guestbook &&
sudo cp -f $remoteTmp/app.py $remoteTmp/requirements.txt /opt/guestbook/ &&
sudo rm -rf /opt/guestbook/templates &&
sudo cp -rf $remoteTmp/templates /opt/guestbook/ &&
sudo chown -R root:root /opt/guestbook &&
sudo chmod -R u=rwX,go=rX /opt/guestbook &&
sudo systemctl restart guestbook &&
rm -rf $remoteTmp
"@
    if ($LASTEXITCODE -ne 0) { Fail "Installing guestbook on the Pi failed (exit $LASTEXITCODE)." }
  }
  finally {
    Remove-Item -Path $gstage -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Guestbook) {
  Push-Guestbook
  Write-Host "`nGuestbook updated. Reload http://$($cfg['PORTAL_IP'])/guestbook on a client." -ForegroundColor Green
  exit 0
}

# --- Data-pull helpers (guestbook CSV/JSON, probe CSV) ------------------------
# Each connects to the Pi, exports to a temp file there, scp's it back, cleans up.
function Export-GuestbookCsv([string]$Out) {
  # Read via sqlite3 (through WAL) as the guestbook account, not root, so any
  # -wal/-shm file it creates stays owned by the service. Write a temp CSV.
  # Passed over stdin to avoid PowerShell/remote quoting pain.
  $py = @'
import sqlite3, csv
DB = "/var/lib/portal/guestbook.db"
OUT = "/tmp/guestbook_export.csv"
con = sqlite3.connect(DB)
with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(["id", "created_at", "name", "message"])
    for row in con.execute("SELECT id, created_at, name, message FROM entries ORDER BY id"):
        w.writerow(row)
print(con.execute("SELECT COUNT(*) FROM entries").fetchone()[0])
'@
  Write-Host "Exporting guestbook entries on the Pi..." -ForegroundColor Cyan
  $count = ($py | & ssh $target "sudo rm -f /tmp/guestbook_export.csv && cd / && sudo -u guestbook python3 -I - && sudo chmod 644 /tmp/guestbook_export.csv") | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0) { Fail "Export on the Pi failed (exit $LASTEXITCODE). Is the guestbook installed?" }
  & scp -q "${target}:/tmp/guestbook_export.csv" $Out
  if ($LASTEXITCODE -ne 0) { Fail "scp of the export failed (exit $LASTEXITCODE)." }
  & ssh $target "rm -f /tmp/guestbook_export.csv" | Out-Null
  Write-Host "Pulled $count guestbook entries -> $Out" -ForegroundColor Green
}

function Export-GuestbookJson([string]$Out) {
  Write-Host "Fetching guestbook JSON from the Pi..." -ForegroundColor Cyan
  # curl the dump on the Pi via localhost (always allowed, whatever nginx allows
  # for client networks), then scp the file back verbatim so PowerShell never
  # re-encodes the JSON.
  & ssh $target "curl -fsS http://127.0.0.1/guestbook/dump -o /tmp/guestbook_dump.json"
  if ($LASTEXITCODE -ne 0) { Fail "Fetching the dump on the Pi failed (exit $LASTEXITCODE). Is the guestbook installed?" }
  & scp -q "${target}:/tmp/guestbook_dump.json" $Out
  if ($LASTEXITCODE -ne 0) { Fail "scp of the JSON dump failed (exit $LASTEXITCODE)." }
  & ssh $target "rm -f /tmp/guestbook_dump.json" | Out-Null
  Write-Host "Saved guestbook JSON -> $Out" -ForegroundColor Green
}

function Export-ProbeData([string]$Out) {
  # Export the probe DB (probes JOIN devices) to a temp CSV on the Pi via sqlite3.
  # Degrades gracefully if probe logging was never enabled (no DB / no tables).
  $py = @'
import sqlite3, csv, os
DB = "/var/lib/portal-probe/probes.db"
OUT = "/tmp/probes_export.csv"
cols = ["mac", "vendor", "randomized", "ssid", "count",
        "first_seen", "last_seen", "last_signal"]
rows, devices = [], 0
if os.path.exists(DB):
    con = sqlite3.connect(DB)
    have = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if "probes" in have and "devices" in have:
        rows = list(con.execute("""
            SELECT p.mac, d.vendor, d.randomized, p.ssid, p.count,
                   p.first_seen, p.last_seen, d.last_signal
            FROM probes p LEFT JOIN devices d ON d.mac = p.mac
            ORDER BY p.last_seen DESC, p.mac"""))
        devices = con.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
with open(OUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow(cols)
    w.writerows(rows)
print(devices)
'@
  Write-Host "Exporting probe data on the Pi..." -ForegroundColor Cyan
  $count = ($py | & ssh $target "sudo rm -f /tmp/probes_export.csv && cd / && if id -u portal-probe >/dev/null 2>&1; then sudo -u portal-probe python3 -I -; else sudo python3 -I -; fi && sudo chmod 644 /tmp/probes_export.csv") | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0) { Fail "Probe export on the Pi failed (exit $LASTEXITCODE)." }
  & scp -q "${target}:/tmp/probes_export.csv" $Out
  if ($LASTEXITCODE -ne 0) { Fail "scp of the probe export failed (exit $LASTEXITCODE)." }
  & ssh $target "rm -f /tmp/probes_export.csv" | Out-Null
  if ([int]$count -eq 0) {
    Write-Host "Pulled probe data -> $Out (0 devices — is probe logging enabled with a monitor radio?)" -ForegroundColor Yellow
  } else {
    Write-Host "Pulled probes for $count devices -> $Out" -ForegroundColor Green
  }
}

# --- Download the guestbook, THEN erase it on the Pi -------------------------
# Safe ordering: stop the service (no new signs mid-export), export straight from
# the DB (the HTTP /dump needs the service up, so we read sqlite3 directly and
# mirror its JSON shape), verify the local file, and ONLY then delete. The
# service is always restarted (success or failure); on any error nothing is
# purged and the local download is kept.
function Export-GuestbookPurge([string]$Out) {
  Write-Host "Stopping guestbook (halting new writes)..." -ForegroundColor Cyan
  & ssh $target "sudo systemctl stop guestbook"
  if ($LASTEXITCODE -ne 0) { Fail "Could not stop the guestbook service; nothing exported or deleted." }

  $purgeFailed = $false
  try {
    # Export every entry incl. parsed meta — same shape as /guestbook/dump.
    $pyDump = @'
import sqlite3, json
DB  = "/var/lib/portal/guestbook.db"
OUT = "/tmp/guestbook_dump.json"
con = sqlite3.connect(DB); con.row_factory = sqlite3.Row
rows = []
for r in con.execute("SELECT id, created_at, name, message, meta FROM entries ORDER BY id"):
    row = {"id": r["id"], "created_at": r["created_at"], "name": r["name"], "message": r["message"]}
    try:    row["meta"] = json.loads(r["meta"]) if r["meta"] else None
    except Exception: row["meta"] = None
    rows.append(row)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=2)
print(len(rows))
'@
    Write-Host "Exporting entries from the DB..." -ForegroundColor Cyan
    $count = ($pyDump | & ssh $target "sudo rm -f /tmp/guestbook_dump.json && cd / && sudo -u guestbook python3 -I - && sudo chmod 644 /tmp/guestbook_dump.json") | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "Export on the Pi failed (exit $LASTEXITCODE). Nothing deleted." }
    & scp -q "${target}:/tmp/guestbook_dump.json" $Out
    if ($LASTEXITCODE -ne 0) { throw "scp of the export failed (exit $LASTEXITCODE). Nothing deleted." }
    # The dump is owned by the guestbook account, so needs sudo to remove.
    & ssh $target "sudo rm -f /tmp/guestbook_dump.json" | Out-Null

    # Guard: never purge unless we have a real local file in hand.
    if (-not (Test-Path $Out) -or (Get-Item $Out).Length -eq 0) {
      throw "Local export '$Out' missing or empty. Refusing to purge the Pi."
    }
    $n = 0; [void][int]::TryParse(($count | Out-String).Trim(), [ref]$n)

    if ($n -eq 0) {
      Write-Host "Exported 0 entries — nothing to purge." -ForegroundColor Yellow
    } else {
      $pyPurge = @'
import sqlite3
con = sqlite3.connect("/var/lib/portal/guestbook.db")
n = con.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
con.execute("DELETE FROM entries")
try:    con.execute("DELETE FROM sqlite_sequence WHERE name='entries'")
except Exception: pass
con.commit()
con.execute("VACUUM"); con.commit()
print(n)
'@
      Write-Host "Purging $n entries on the Pi (visit counter kept)..." -ForegroundColor Yellow
      $deleted = ($pyPurge | & ssh $target "cd / && sudo -u guestbook python3 -I -") | Select-Object -Last 1
      if ($LASTEXITCODE -ne 0) { throw "Purge failed (exit $LASTEXITCODE). Your download is safe at $Out." }
      Write-Host "Deleted $deleted entries on the Pi." -ForegroundColor Green
    }
  }
  catch {
    $purgeFailed = $true
    Write-Host $_.Exception.Message -ForegroundColor Red
  }
  finally {
    Write-Host "Restarting guestbook..." -ForegroundColor Cyan
    & ssh $target "sudo systemctl start guestbook" | Out-Null
  }
  if ($purgeFailed) { exit 1 }
  Write-Host "Saved $Out; the Pi's guestbook is now cleared." -ForegroundColor Green
}

# --- Pull dispatch ------------------------------------------------------------
if ($PullGuestbookPurge) {
  if (-not $OutFile) { $OutFile = Join-Path $scriptDir ("guestbook-final-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)) }
  Export-GuestbookPurge $OutFile
  exit 0
}
if ($PullGuestbook) {
  if (-not $OutFile) { $OutFile = Join-Path $scriptDir ("guestbook-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)) }
  Export-GuestbookCsv $OutFile
  exit 0
}
if ($PullJson) {
  if (-not $OutFile) { $OutFile = Join-Path $scriptDir ("guestbook-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)) }
  Export-GuestbookJson $OutFile
  exit 0
}
if ($PullProbes) {
  if (-not $OutFile) { $OutFile = Join-Path $scriptDir ("probes-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)) }
  Export-ProbeData $OutFile
  exit 0
}
if ($PullAll) {
  if ($OutFile) { Write-Host "-OutFile is ignored with -PullAll; each dataset gets a default name." -ForegroundColor DarkGray }
  $ts = "{0:yyyyMMdd-HHmmss}" -f (Get-Date)
  Export-GuestbookJson (Join-Path $scriptDir "guestbook-$ts.json")
  Export-ProbeData     (Join-Path $scriptDir "probes-$ts.csv")
  Write-Host "`nPulled all data." -ForegroundColor Green
  exit 0
}

# --- Stage payload with LF line endings so bash on the Pi is happy ---
$items = @('setup.sh','portal.env','config','www','guestbook','ssid','probe','health')
# ssids.txt (bait pool) is optional + git-ignored; ship it only when present.
if (Test-Path (Join-Path $scriptDir 'ssids.txt')) { $items += 'ssids.txt' }
foreach ($i in $items) {
  if (-not (Test-Path (Join-Path $scriptDir $i))) { Fail "Missing '$i' — nothing to deploy." }
}

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("picp_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
  # Text extensions to normalize; everything else copied byte-for-byte.
  $textExt = '.sh','.env','.conf','.tmpl','.html','.network','.md','.py','.service','.timer','.txt'
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

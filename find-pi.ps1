#Requires -Version 5.1
<#
.SYNOPSIS
  Find a Raspberry Pi on the local network.
.DESCRIPTION
  Three ways, best-first:
    1. mDNS  — resolve raspberrypi.local / pi.local (works if avahi is up).
    2. Sweep — async-ping every host in the local /24 to populate the ARP cache.
    3. ARP   — match cached MACs against known Raspberry Pi OUI prefixes.
  Then TCP-probes port 22 on each candidate so you know which is SSH-ready.

  Read-only: it changes nothing on your machine or the Pi.
.PARAMETER Names
  mDNS names to try (default: raspberrypi, pi).
.PARAMETER Quiet
  Print only the best host (for scripting: $pi = .\find-pi.ps1 -Quiet).
.EXAMPLE
  .\find-pi.ps1
.EXAMPLE
  $pi = .\find-pi.ps1 -Quiet ; ssh "pi@$pi"
#>
[CmdletBinding()]
param(
  [string[]]$Names = @('raspberrypi','pi'),
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# Raspberry Pi OUIs (first 3 MAC octets), lower-case, dash-separated.
$piOUIs = @(
  'b8-27-eb',  # Pi 1/2/3 (built-in)
  'dc-a6-32',  # Pi 4 / CM4 / 400
  'e4-5f-01',  # Pi 4 / Zero 2 W / Pico W
  '28-cd-c1',  # Pi (newer)
  '2c-cf-67',  # Pi 5 / newer
  'd8-3a-dd'   # Pi 5 / newer
)

function Note($m) { if (-not $Quiet) { Write-Host $m } }

$found = [System.Collections.Generic.List[object]]::new()
function Add-Candidate($ip, $mac, $how) {
  if ($ip -and -not ($found | Where-Object { $_.IP -eq $ip })) {
    $found.Add([pscustomobject]@{ IP = $ip; MAC = $mac; How = $how; SSH = $null })
  }
}

# --- 1. mDNS ------------------------------------------------------------------
Note "Trying mDNS ($($Names -join ', '))..."
foreach ($n in $Names) {
  try {
    $addrs = [System.Net.Dns]::GetHostAddresses("$n.local") |
             Where-Object { $_.AddressFamily -eq 'InterNetwork' }   # IPv4 only
    foreach ($a in $addrs) { Add-Candidate $a.IPAddressToString $null "mDNS $n.local" }
  } catch { }   # name doesn't resolve — fine, fall through to the sweep
}

# --- 2. Subnet sweep to warm the ARP cache ------------------------------------
# Pick the "real" local IPv4: has a default gateway, isn't loopback/APIPA/CGNAT.
$local = Get-NetIPConfiguration |
  Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address.IPAddress -notlike '169.254.*' } |
  Select-Object -First 1

if ($local) {
  $myIp = $local.IPv4Address.IPAddress
  $base = ($myIp -split '\.')[0..2] -join '.'      # assume a /24
  Note "Sweeping $base.0/24 (my IP $myIp)..."

  # Async ICMP across the /24 — much faster than sequential ping.
  $pings = foreach ($i in 1..254) {
    (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$base.$i", 400)
  }
  [System.Threading.Tasks.Task]::WaitAll($pings)
} else {
  Note "Could not determine a local IPv4 with a gateway — skipping sweep."
}

# --- 3. Match ARP cache against Pi OUIs ---------------------------------------
Note "Scanning ARP cache for Raspberry Pi MACs..."
foreach ($line in (arp -a)) {
  if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})') {
    $ip  = $matches[1]
    $mac = $matches[2].ToLower()
    if ($piOUIs -contains $mac.Substring(0,8)) { Add-Candidate $ip $mac "ARP (Pi OUI)" }
  }
}

# Fill MACs we don't have yet from the ARP table (e.g. mDNS hits).
$arpMap = @{}
foreach ($line in (arp -a)) {
  if ($line -match '(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})') {
    $arpMap[$matches[1]] = $matches[2].ToLower()
  }
}
foreach ($c in $found) { if (-not $c.MAC -and $arpMap.ContainsKey($c.IP)) { $c.MAC = $arpMap[$c.IP] } }

# --- 4. TCP-probe port 22 on each candidate -----------------------------------
foreach ($c in $found) {
  $t = New-Object System.Net.Sockets.TcpClient
  try {
    $ok = $t.ConnectAsync($c.IP, 22).Wait(700)
    $c.SSH = [bool]($ok -and $t.Connected)
  } catch { $c.SSH = $false } finally { $t.Close() }
}

# --- Report -------------------------------------------------------------------
if ($found.Count -eq 0) {
  if ($Quiet) { exit 1 }
  Write-Host "`nNo Raspberry Pi found." -ForegroundColor Yellow
  Write-Host "Is it powered on and connected (Ethernet for deploy)? Give it ~60s after boot."
  exit 1
}

# Prefer an SSH-reachable host; among those, an mDNS hit; else first.
$best = $found | Sort-Object `
  @{ Expression = { -not $_.SSH } }, `
  @{ Expression = { -not ($_.How -like 'mDNS*') } } |
  Select-Object -First 1

if ($Quiet) { $best.IP; exit 0 }

Write-Host "`nCandidates:" -ForegroundColor Cyan
$found | Sort-Object How | Format-Table -AutoSize `
  @{L='IP';E={$_.IP}},
  @{L='MAC';E={$_.MAC}},
  @{L='Found via';E={$_.How}},
  @{L='SSH:22';E={ if ($_.SSH) {'open'} else {'closed'} }}

Write-Host "Best guess: " -NoNewline
Write-Host $best.IP -ForegroundColor Green -NoNewline
Write-Host "  ->  ssh pi@$($best.IP)"

# Shared helpers for setup.ps1 / uninstall.ps1 / windows-setup.ps1 (dot-sourced, not run).
# Installs go on the drive this kit sits on ($Drive, e.g. X:): Ubuntu, WSL swap, Tailscale, $OffloadDir.
# Kit on the system drive (C:) = the usual Windows places, as before.
$Drive = Split-Path -Qualifier $PSScriptRoot
$OnSystemDrive = $Drive -eq $env:SystemDrive
$OffloadDir = if ($OnSystemDrive) { Join-Path $env:LOCALAPPDATA 'OffloadPC' } else { "$Drive\OffloadPC" }
function Ensure-OffloadDir { New-Item -ItemType Directory -Force -Path $OffloadDir | Out-Null }

# Which roles are installed on this PC ("offload", "me") - so uninstall knows when it's the last one.
function Get-Roles {
  $f = Join-Path $OffloadDir 'roles.txt'
  if (Test-Path $f) { @(Get-Content $f | Where-Object { $_ }) } else { @() }
}
function Add-Role([string]$r) {
  Ensure-OffloadDir
  @(@(Get-Roles) + $r | Select-Object -Unique) | Set-Content (Join-Path $OffloadDir 'roles.txt')
}
function Remove-Role([string]$r) {
  $left = @(Get-Roles | Where-Object { $_ -ne $r })
  $f = Join-Path $OffloadDir 'roles.txt'
  if ($left.Count) { $left | Set-Content $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
  return $left.Count
}

# Change only some keys in [wsl2] of %USERPROFILE%\.wslconfig. "memory" keeps the larger value
# (a PC can be both roles). The original file is backed up once so uninstall can restore it.
function Update-WslConfig([hashtable]$Set) {
  Ensure-OffloadDir
  if (-not $OnSystemDrive) {   # otherwise WSL puts its swap file in %TEMP% on C:
    New-Item -ItemType Directory -Force "$Drive\WSL" | Out-Null
    $Set['swapFile'] = "$Drive\\WSL\\swap.vhdx"
  }
  $path = Join-Path $env:USERPROFILE '.wslconfig'
  $backup = Join-Path $OffloadDir 'wslconfig.original'
  $created = Join-Path $OffloadDir 'wslconfig.created'
  if (-not (Test-Path $backup) -and -not (Test-Path $created)) {
    if (Test-Path $path) { Copy-Item $path $backup } else { New-Item $created -ItemType File | Out-Null }
  }
  $lines = if (Test-Path $path) { @(Get-Content $path) } else { @() }
  $out = New-Object System.Collections.Generic.List[string]
  $done = @{}
  $inWsl2 = $false; $seenWsl2 = $false
  $flush = { foreach ($k in $Set.Keys) { if (-not $done[$k]) { $out.Add("$k=$($Set[$k])"); $done[$k] = $true } } }
  foreach ($l in $lines) {
    if ($l -match '^\s*\[(.+)\]\s*$') {
      if ($inWsl2) { & $flush }
      $inWsl2 = ($Matches[1].Trim() -eq 'wsl2'); if ($inWsl2) { $seenWsl2 = $true }
      $out.Add($l); continue
    }
    if ($inWsl2 -and $l -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.*?)\s*$') {
      $k = $Matches[1]; $v = $Matches[2]
      if ($Set.ContainsKey($k)) {
        $new = $Set[$k]
        if ($k -eq 'memory' -and $v -match '^\d+GB$' -and $new -match '^\d+GB$' -and [int]($v -replace 'GB') -gt [int]($new -replace 'GB')) { $new = $v }
        $out.Add("$k=$new"); $done[$k] = $true; continue
      }
    }
    $out.Add($l)
  }
  if ($inWsl2) { & $flush }
  if (-not $seenWsl2) { $out.Add('[wsl2]'); & $flush }
  Set-Content -Path $path -Value $out -Encoding ascii
  Write-Host "Updated $path ($(($Set.Keys | ForEach-Object { "$_=$($Set[$_])" }) -join ', '))"
}

function Restore-WslConfig {
  $path = Join-Path $env:USERPROFILE '.wslconfig'
  $backup = Join-Path $OffloadDir 'wslconfig.original'
  $created = Join-Path $OffloadDir 'wslconfig.created'
  if (Test-Path $backup) { Copy-Item $backup $path -Force; Remove-Item $backup; Write-Host "Restored original .wslconfig" }
  elseif (Test-Path $created) { Remove-Item $path -ErrorAction SilentlyContinue; Remove-Item $created; Write-Host "Removed .wslconfig (it didn't exist before)" }
}

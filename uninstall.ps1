# Uninstaller. Don't run directly - double-click one of:
#   UNINSTALL-processingoffloadPC.cmd   (on a nuclear powerplant, e.g. the PC you borrowed)
#   UNINSTALL-my-PC.cmd                 (on your laptop / desktop)
# Every step says what it does. Deleting Ubuntu or WSL itself is asked separately (default: keep).
param([ValidateSet('offload', 'me')][string]$Role = 'offload')
$ErrorActionPreference = 'Continue'
$Distro = 'Ubuntu-24.04'
$Kit = $PSScriptRoot

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Role', $Role)
  exit
}
. "$Kit\common.ps1"
$env:WSL_UTF8 = '1'
function Clean($out) { (($out -replace "`0", '') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function YesNo($q) { (Read-Host "$q [y/N]") -match '^[Yy]' }
function Done($t) { Write-Host "OK  $t" -ForegroundColor Green }
$hasDistro = (Clean (wsl.exe -l -q 2>$null)) -contains $Distro
$user = if ($hasDistro) { Clean (wsl.exe -d $Distro -u root --exec bash -c "getent passwd 1000 | cut -d: -f1") } else { '' }

$what = if ($Role -eq 'offload') { 'the Computing Power Network powerplant (agent, guardian, ROS containers, power settings)' } else { 'the Computing Power Network client (shortcuts, VS Code extension, Claude skill)' }
Write-Host "This removes $what from this PC." -ForegroundColor Cyan
if (-not (YesNo "Continue?")) { Write-Host "Nothing changed."; exit 0 }

if ($Role -eq 'offload') {
  # 1. Windows agent + scheduled tasks
  Stop-ScheduledTask -TaskName 'OffloadPC agent' -ErrorAction SilentlyContinue
  foreach ($t in 'OffloadPC agent', 'OffloadPC scheduled wake', 'Keep WSL Ubuntu running') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
  }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*OffloadPC\agent.ps1*' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
  Remove-Item (Join-Path $OffloadDir 'agent.ps1') -ErrorAction SilentlyContinue
  Done "Windows agent and scheduled tasks removed"

  # 2. Original power settings
  $orig = Join-Path $OffloadDir 'original-power.json'
  if (Test-Path $orig) {
    $o = Get-Content $orig -Raw | ConvertFrom-Json
    if ($null -ne $o.StandbyAC) { powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $o.StandbyAC }
    if ($null -ne $o.RtcWakeAC) { powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE $o.RtcWakeAC }
    powercfg /setactive SCHEME_CURRENT
    foreach ($w in @($o.Wol)) {
      if ($w.Name -and $w.WakeOnMagicPacket -in 'Enabled', 'Disabled') {
        Set-NetAdapterPowerManagement -Name $w.Name -WakeOnMagicPacket $w.WakeOnMagicPacket -ErrorAction SilentlyContinue
      }
    }
    Remove-Item $orig, (Join-Path $OffloadDir 'powerplant.json') -ErrorAction SilentlyContinue
    Done "Original sleep timer, wake timers and Wake-on-LAN settings restored"
  }

  # 3. Inside Ubuntu: stop ROS, guardian, Tailscale; give back access to Windows drives
  if ($hasDistro -and $user) {
    wsl.exe -d $Distro -u root --exec bash -c @"
systemctl disable --now offload-guardian.service 2>/dev/null; rm -f /etc/systemd/system/offload-guardian.service
cd /home/$user/ros2-remote/docker 2>/dev/null && docker compose down 2>/dev/null
tailscale logout 2>/dev/null; systemctl disable --now tailscaled 2>/dev/null
rm -rf /home/$user/.offload-agent
python3 - <<'EOF'
import configparser
p='/etc/wsl.conf'; c=configparser.ConfigParser(); c.optionxform=str; c.read(p)
for s,k in [('automount','enabled'),('automount','mountFsTab'),('interop','enabled'),('interop','appendWindowsPath')]:
    if c.has_section(s): c.remove_option(s,k)
with open(p,'w') as f: c.write(f)
EOF
"@ 2>$null
    Done "ROS containers, guardian and Tailscale stopped inside Ubuntu; privacy settings removed"
  }
} else {
  # 1. Shortcuts inside Ubuntu
  if ($hasDistro -and $user) {
    wsl.exe -d $Distro --exec bash -c "sed -i '/# >>> ros2-remote >>>/,/# <<< ros2-remote <<</d' ~/.bashrc; rm -f ~/.offloadpc-*" 2>$null
    Done "ROS shortcuts removed from Ubuntu (~/.bashrc)"
  }
  # 2. VS Code extension
  if (Get-Command code -ErrorAction SilentlyContinue) {
    code --uninstall-extension robobadgers.badgerlabs-offloading-pp *> $null
    Done "BadgerLabsOffloadingPP VS Code extension removed"
  }
  # 3. Claude skill
  Remove-Item (Join-Path $env:USERPROFILE '.claude\skills\computing-power-network') -Recurse -Force -ErrorAction SilentlyContinue
  Done "Claude skill removed"
  # 4. Tailscale for Windows
  if (YesNo "Uninstall Tailscale from Windows too?") {
    winget uninstall -e --id Tailscale.Tailscale
  }
}

# Shared: .wslconfig and our folder, once no role is left on this PC
$left = Remove-Role $Role
if ($left -eq 0) {
  Restore-WslConfig
  Remove-Item $OffloadDir -Recurse -Force -ErrorAction SilentlyContinue
  Done "Removed $OffloadDir"
} else {
  Write-Host "The other role is still installed on this PC, so .wslconfig stays."
}

# Optional: delete Ubuntu / WSL completely
if ($hasDistro) {
  Write-Host "`nUbuntu 24.04 still exists (with ROS 2 and anything stored in it)." -ForegroundColor Yellow
  if ($left -gt 0) { Write-Host "NOTE: the other role on this PC uses it too." -ForegroundColor Yellow }
  if (YesNo "Delete Ubuntu 24.04 and EVERYTHING inside it? (cannot be undone)") {
    wsl.exe --unregister $Distro
    Done "Ubuntu 24.04 deleted"
    if (YesNo "Remove WSL from Windows completely? (only if nothing else on this PC uses WSL)") {
      wsl.exe --uninstall
      dism.exe /online /disable-feature /featurename:VirtualMachinePlatform /norestart | Out-Null
      dism.exe /online /disable-feature /featurename:Microsoft-Windows-Subsystem-Linux /norestart | Out-Null
      Done "WSL removed - restart the PC to finish"
    }
  }
}

Write-Host "`nUninstall finished." -ForegroundColor Green
if ($Role -eq 'offload') {
  Write-Host "Last step for whoever set it up: remove this PC from https://login.tailscale.com/admin/machines"
}

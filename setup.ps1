# One-click setup. Don't run directly - double-click one of:
#   SETUP-processingoffloadPC.cmd   (on the processing offload PC: does the heavy computing)
#   SETUP-my-PC.cmd           (on your laptop / desktop: light work + screen)
# Safe to run again: finished steps are skipped. If it asks for a reboot, reboot and run it again.
param([ValidateSet('offload', 'me')][string]$Role = 'me')

# 'Continue', not 'Stop': in Windows PowerShell 5.1 any text a program (wsl.exe, winget) writes to
# stderr counts as an error and would abort the script. Each step checks $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$Distro = 'Ubuntu-24.04'
$Kit = $PSScriptRoot

# --- Run as administrator (re-launch elevated if needed) ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList @(
    '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Role', $Role)
  exit
}

. "$Kit\common.ps1"
function Step($n, $text) { Write-Host "`n=== [$n/5] $text ===" -ForegroundColor Cyan }
function Fail($text) { Write-Host "`n$text" -ForegroundColor Yellow; exit 1 }
function Clean($out) { (($out -replace "`0", '') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$env:WSL_UTF8 = '1'   # make wsl.exe print normal text instead of UTF-16
function Get-Distros { Clean (wsl.exe -l -q 2>$null) }
# Returns e.g. "WSL version: 2.6.1.0" for the real WSL, nothing for the built-in stub / not installed.
function Get-WslVersion {
  $v = Clean (wsl.exe --version 2>$null)
  if ($LASTEXITCODE -eq 0 -and ($v -join ' ') -match '\d+\.\d+\.\d+') { $v | Select-Object -First 1 }
}
function Get-WslUser { Clean (wsl.exe -d $Distro -u root --exec bash -c "getent passwd 1000 | cut -d: -f1") }
# Runs a command in Ubuntu as the normal user, attached to this console (so sudo / login prompts work).
# Read the result from $LASTEXITCODE afterwards. --exec = no extra shell, so quoting stays intact.
function WslBash($cmd) { wsl.exe -d $Distro --exec bash -lc $cmd }

$title = if ($Role -eq 'offload') { "processing offload PC (heavy computing)" } else { "Your PC (light work + screen)" }
Write-Host "ROS 2 offload setup: $title" -ForegroundColor Green

# 1. Check hardware / Windows
Step 1 "Checking this PC"
& "$Kit\check-specs.ps1"

# 2. WSL 2 + Ubuntu 24.04
Step 2 "WSL 2 + Ubuntu 24.04"
$cpu0 = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not ($cpu0.VirtualizationFirmwareEnabled -or (Get-CimInstance Win32_ComputerSystem).HypervisorPresent)) {
  Fail "Virtualization is OFF in the BIOS. Restart, enter BIOS (Del/F2), enable Intel VT-x / AMD SVM, then run again."
}

# 2a. Windows features WSL 2 needs
$needReboot = $false
foreach ($feature in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
  $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
  if ($state -ne 'Enabled') {
    Write-Host "Turning on Windows feature: $feature ..."
    dism.exe /online /enable-feature /featurename:$feature /all /norestart
    if ($LASTEXITCODE -eq 3010) { $needReboot = $true }
    elseif ($LASTEXITCODE -ne 0) { Fail "Could not turn on $feature (code $LASTEXITCODE)." }
    else { $needReboot = $true }
  } else { Write-Host "OK  $feature" }
}

# 2b. Current WSL from Microsoft (the built-in wsl.exe is only a stub that can't run Ubuntu)
if (-not (Get-WslVersion)) {
  Write-Host "Installing the latest WSL ..."
  wsl.exe --install --no-distribution
  if (-not (Get-WslVersion)) {
    Write-Host "Trying the backup method (winget) ..."
    winget install -e --id Microsoft.WSL --accept-source-agreements --accept-package-agreements
  }
} else {
  Write-Host "Updating WSL ..."
  wsl.exe --update
}
if ($needReboot) { Fail "Windows features for WSL were turned on. REBOOT the PC, then double-click the same SETUP file again." }
$wslVer = Get-WslVersion
if (-not $wslVer) { Fail "WSL did not install. REBOOT the PC and run again; if it still fails, run 'wsl --install' in an admin PowerShell." }
Write-Host "OK  $wslVer"
wsl.exe --set-default-version 2 | Out-Null

# 2c. Ubuntu 24.04, as WSL 2
if ((Get-Distros) -notcontains $Distro) {
  Write-Host "Installing $Distro ..."
  wsl.exe --install -d $Distro --no-launch
  if ((Get-Distros) -notcontains $Distro) {
    Write-Host "Trying direct download instead of the Microsoft Store ..."
    wsl.exe --install -d $Distro --no-launch --web-download
  }
  if ((Get-Distros) -notcontains $Distro) { Fail "Ubuntu did not install. REBOOT the PC and run again." }
}
$line = Clean (wsl.exe -l -v) | Where-Object { $_ -match [regex]::Escape($Distro) }
if ($line -match '\s1$') {
  Write-Host "Converting $Distro from WSL 1 to WSL 2 ..."
  wsl.exe --set-version $Distro 2
}
Write-Host "OK  Ubuntu 24.04 on WSL 2"

# 3. Linux user account (created on Ubuntu's first interactive start)
Step 3 "Ubuntu user account"
if (-not (Get-WslUser)) {
  Write-Host "Ubuntu will now ask you to create a username and password (any; remember them)." -ForegroundColor Yellow
  Write-Host "When you then see a prompt like  name@PC:~`$  type  exit  and press Enter." -ForegroundColor Yellow
  wsl.exe -d $Distro
  if (-not (Get-WslUser)) { Fail "No Ubuntu user was created. Run this SETUP file again." }
}
Write-Host "Ubuntu user: $(Get-WslUser)"

$WslUser = Get-WslUser

# 4. Windows-side settings (RAM for WSL, Tailscale / agent, power)
Step 4 "Windows settings"
if ($Role -eq 'offload') {
  # Name + "whose PC is this?" (asked once, remembered for reruns)
  Ensure-OffloadDir
  $answersFile = Join-Path $OffloadDir 'powerplant.json'
  if (Test-Path $answersFile) {
    $answers = Get-Content $answersFile -Raw | ConvertFrom-Json
  } else {
    Write-Host "Name for this nuclear powerplant on your network:" -ForegroundColor Yellow
    Write-Host "  just Enter = processingoffloadpc   or a short name, e.g. 4090 or desktop -> processingoffloadpc-4090"
    $short = ((Read-Host "Name") -replace '[^A-Za-z0-9-]', '').ToLower()
    $name = if ($short) { "processingoffloadpc-$short" } else { 'processingoffloadpc' }
    Write-Host "`nWhose PC is this?" -ForegroundColor Yellow
    Write-Host "  1 = someone else's (privacy: no access to their files; your jobs pause while they use the PC)"
    Write-Host "  2 = mine (full access, no auto-pause)"
    $own = Read-Host "1 or 2 [1]"
    $answers = [pscustomobject]@{ Name = $name; Privacy = ($own -ne '2') }
    $answers | ConvertTo-Json | Set-Content $answersFile -Encoding utf8
  }
  Write-Host "Powerplant: $($answers.Name)   privacy mode: $(if ($answers.Privacy) { 'ON' } else { 'OFF' })"
  & "$Kit\processingoffloadPC\windows-setup.ps1" -WslUser $WslUser -Distro $Distro
} else {
  & "$Kit\your-pc\windows-setup.ps1"
}

# 5. Copy kit into Ubuntu (through wsl.exe - no Windows drive access needed) and install there
Step 5 "Installing inside Ubuntu (asks for your Ubuntu password; takes 10-30 min)"
WslBash 'mkdir -p ~/ros2-remote'
Push-Location $Kit
cmd.exe /c "tar --exclude=.git -cf - . | wsl.exe -d $Distro --exec tar -C /home/$WslUser/ros2-remote -xf -"
$copyRc = $LASTEXITCODE
Pop-Location
WslBash "find ~/ros2-remote -name '*.sh' -exec sed -i 's/\r`$//' {} +"
if ($copyRc -ne 0) { Fail "Could not copy the kit into Ubuntu." }

if ($Role -eq 'offload') {
  $envs = "POWERPLANT_NAME=$($answers.Name) PRIVACY=$(if ($answers.Privacy) { 1 } else { 0 })"
  WslBash "$envs bash ~/ros2-remote/processingoffloadPC/setup-wsl.sh"
  if ($LASTEXITCODE -ne 0) {                          # e.g. systemd had to be enabled -> restart WSL, retry once
    wsl.exe --shutdown
    WslBash "$envs bash ~/ros2-remote/processingoffloadPC/setup-wsl.sh"
    if ($LASTEXITCODE -ne 0) { Fail "Ubuntu setup failed (see messages above). Fix it and run this SETUP file again." }
  }
  Write-Host "`nRestarting Ubuntu with the new settings and starting the Windows agent ..."
  wsl.exe --shutdown
  Start-ScheduledTask -TaskName 'OffloadPC agent'
  $alive = { WslBash 'h=$(cat ~/.offload-agent/heartbeat 2>/dev/null); [ -n "$h" ] && [ $(( $(date +%s) - h )) -lt 20 ]'; $LASTEXITCODE -eq 0 }
  $ok = $false; for ($i = 0; $i -lt 20 -and -not $ok; $i++) { Start-Sleep 3; $ok = & $alive }
  if (-not $ok) {
    Write-Host "Agent didn't start hidden - switching to the fallback launcher ..."
    & "$Kit\processingoffloadPC\windows-setup.ps1" -WslUser $WslUser -Distro $Distro -AgentOnly -FallbackLauncher
    Start-ScheduledTask -TaskName 'OffloadPC agent'
    for ($i = 0; $i -lt 20 -and -not $ok; $i++) { Start-Sleep 3; $ok = & $alive }
  }
  if ($ok) { Write-Host "OK  Windows agent running" } else { Write-Host "WARNING: Windows agent not running - power commands won't work. Log out and in, then run this again." -ForegroundColor Yellow }

  Write-Host "`nBuilding and starting the ROS 2 containers (first time downloads ~5 GB)..."
  WslBash 'cd ~/ros2-remote/docker && sudo docker compose up -d --build && sudo docker compose ps'
  if ($LASTEXITCODE -ne 0) { Fail "Starting containers failed. Run this SETUP file again." }
  Add-Role 'offload'
  Write-Host "`nDONE. This PC now runs ROS 2 in the background as '$($answers.Name)'." -ForegroundColor Green
  Write-Host "Keep it on and logged in (locking the screen is fine). You can close this window."
  WslBash 'grep -o "^NTFY_TOPIC=[^ ]*" ~/.offload-agent/guardian.conf | sed "s/NTFY_TOPIC=/Phone notifications: ntfy app -> subscribe to /"'
} else {
  WslBash 'bash ~/ros2-remote/your-pc/setup-ros-client.sh'
  if ($LASTEXITCODE -ne 0) { Fail "Ubuntu setup failed (see messages above). Run this SETUP file again." }
  Add-Role 'me'

  # VS Code extensions (only if VS Code is installed; failures are not fatal)
  if (Get-Command code -ErrorAction SilentlyContinue) {
    Write-Host "`nInstalling VS Code extensions ..."
    $exts = 'ms-vscode-remote.remote-wsl', 'ms-vscode-remote.remote-ssh', 'ms-vscode-remote.remote-containers',
            'Ranch-Hand-Robotics.rde-ros-2', 'ms-python.python', 'ms-vscode.cpptools', 'ms-vscode.cmake-tools'
    foreach ($ext in $exts) {
      code --install-extension $ext --force *> $null
      if ($LASTEXITCODE -eq 0) { Write-Host "OK  $ext" } else { Write-Host "--  $ext (install it later from the Extensions panel)" }
    }
    $vsix = Get-ChildItem "$Kit\vscode-extension\*.vsix" -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($vsix) {
      code --install-extension $vsix.FullName --force *> $null
      if ($LASTEXITCODE -eq 0) { Write-Host "OK  BadgerLabsOffloadingPP ($($vsix.Name))" }
    }
  } else {
    Write-Host "`nVS Code not found - skipping VS Code extensions (see README > VS Code)."
  }

  Write-Host "`nDONE. Open 'Ubuntu 24.04' from the Start menu and test:" -ForegroundColor Green
  Write-Host "  start-nuclear-powerplant   (start ROS on the offload PC + open a shell there)"
  Write-Host "  ros2 topic list            (topics from both PCs)"
  Write-Host "  show-running-processes     (what's running there? safe to power off?)"
  Write-Host "  sleep-nuclear-powerplant   (sleep it; --after-finish = sleep when your work is done)"
  Write-Host "  list-powerplants / use-powerplant NAME   (choose which PC does the heavy work)"
  Write-Host "In VS Code: click the powerplant (green/red dot) in the status bar, bottom left."
  Write-Host "Make sure Tailscale (tray icon) is signed in with the same account as the offload PC."
}

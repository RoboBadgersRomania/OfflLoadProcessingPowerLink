# Windows side of a processing offload PC ("nuclear powerplant"). Run as ADMIN (setup.ps1 does this).
#   powershell -ExecutionPolicy Bypass -File .\processingoffloadPC\windows-setup.ps1 -WslUser <ubuntu user>
# Everything here is undone by UNINSTALL-processingoffloadPC.cmd (original settings are saved first).
param(
  [string]$WslUser,
  [string]$Distro = 'Ubuntu-24.04',
  [switch]$AgentOnly,          # only (re)register the agent task
  [switch]$FallbackLauncher    # start the agent via "powershell -WindowStyle Hidden" instead of conhost --headless
)
. "$PSScriptRoot\..\common.ps1"
Ensure-OffloadDir
if (-not $WslUser) { $WslUser = Read-Host 'Your Ubuntu username on this PC' }

if (-not $AgentOnly) {
  # 0. Remember the original power settings once (uninstall restores them)
  $orig = Join-Path $OffloadDir 'original-power.json'
  function Get-PowerIndexAC($sub, $setting) {
    $m = [regex]::Matches((powercfg /query SCHEME_CURRENT $sub $setting | Out-String), '(?m):\s*0x([0-9a-fA-F]+)\s*$')
    if ($m.Count -ge 2) { [Convert]::ToInt32($m[$m.Count - 2].Groups[1].Value, 16) } else { $null }
  }
  if (-not (Test-Path $orig)) {
    $wol = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
      $pm = Get-NetAdapterPowerManagement -Name $_.Name -ErrorAction SilentlyContinue
      if ($pm) { [pscustomobject]@{ Name = $_.Name; WakeOnMagicPacket = [string]$pm.WakeOnMagicPacket } }
    })
    [pscustomobject]@{
      StandbyAC = Get-PowerIndexAC SUB_SLEEP STANDBYIDLE
      RtcWakeAC = Get-PowerIndexAC SUB_SLEEP RTCWAKE
      Wol       = $wol
    } | ConvertTo-Json -Depth 4 | Set-Content $orig -Encoding utf8
    Write-Host "Saved original power settings (uninstall restores them)"
  }

  # 1. WSL resources: most of the RAM (leave 16 GB for Windows), never idle-stop the VM
  $ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  Update-WslConfig @{ memory = "$([math]::Max(8, $ramGB - 16))GB"; swap = '16GB'; vmIdleTimeout = '-1' }

  # 2. Don't sleep on its own (it sleeps when you send sleep-nuclear-powerplant)
  powercfg /change standby-timeout-ac 0
  Write-Host "Automatic sleep on AC power disabled"

  # 3. Remote power: allow scheduled wake-ups, and Wake-on-LAN on the network card
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
  powercfg /setactive SCHEME_CURRENT
  Write-Host "Wake timers allowed (sleep-nuclear-powerplant HH:MM)"
  Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object {
    try {
      Set-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
      powercfg /deviceenablewake "$($_.InterfaceDescription)" 2>$null | Out-Null
      Write-Host "Wake-on-LAN enabled on '$($_.Name)'  MAC $($_.MacAddress)"
    } catch { Write-Host "Wake-on-LAN not supported on '$($_.Name)' (fine; scheduled wake still works)" }
  }
}

# 4. Windows agent: hidden, starts at logon. Keeps Ubuntu running, runs ONLY the allowed power
#    requests from Ubuntu, reports keyboard/mouse idle time, MAC and specs. (see agent.ps1)
Copy-Item "$PSScriptRoot\agent.ps1" (Join-Path $OffloadDir 'agent.ps1') -Force
Unregister-ScheduledTask -TaskName 'Keep WSL Ubuntu running' -Confirm:$false -ErrorAction SilentlyContinue
$ps = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$OffloadDir\agent.ps1`" -Distro $Distro -User $WslUser"
if ($FallbackLauncher) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-WindowStyle Hidden " + ($ps -replace '^powershell\.exe ', ''))
} else {
  $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless $ps"
}
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'OffloadPC agent' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered hidden Windows agent (task 'OffloadPC agent')"

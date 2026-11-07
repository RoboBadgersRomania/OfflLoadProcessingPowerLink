# Run in an ADMIN PowerShell on the processing offload PC, AFTER `wsl --install -d Ubuntu-24.04` + reboot
# and after Ubuntu has been opened once (username/password created).
#   powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1

# 1. WSL resources: give WSL most of the RAM (leave 16 GB for Windows), never idle-stop the VM.
$ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$wslRam = [math]::Max(8, $ramGB - 16)
$wslconfig = @"
[wsl2]
memory=${wslRam}GB
swap=16GB
vmIdleTimeout=-1
"@
Set-Content -Path "$env:USERPROFILE\.wslconfig" -Value $wslconfig -Encoding ascii
Write-Host "Wrote $env:USERPROFILE\.wslconfig"

# 2. Start Ubuntu at logon and keep it running (Docker + Tailscale stay up).
$action  = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d Ubuntu-24.04 --exec sleep infinity"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "Keep WSL Ubuntu running" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task 'Keep WSL Ubuntu running'"

# 3. Don't let the PC sleep while plugged in (screen can still turn off).
powercfg /change standby-timeout-ac 0
Write-Host "Sleep on AC power disabled (it only sleeps when you send offloadpc-sleep)"

# 4. Remote power control: allow scheduled wake-ups, and Wake-on-LAN on the wired network card.
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP RTCWAKE 1
powercfg /setactive SCHEME_CURRENT
Write-Host "Wake timers allowed (offloadpc-sleep-until)"
Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object {
  try {
    Set-NetAdapterPowerManagement -Name $_.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
    powercfg /deviceenablewake "$($_.InterfaceDescription)" 2>$null | Out-Null
    Write-Host "Wake-on-LAN enabled on '$($_.Name)'  MAC $($_.MacAddress)"
  } catch { Write-Host "Wake-on-LAN not supported on '$($_.Name)' (fine; use scheduled wake instead)" }
}

wsl --shutdown
Write-Host "WSL restarted with new settings. Open Ubuntu again and run processingoffloadPC/setup-wsl.sh"

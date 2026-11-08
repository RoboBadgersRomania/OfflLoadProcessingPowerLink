# OffloadPC Windows agent: the ONLY bridge from Ubuntu (WSL) to Windows on a processing offload PC.
#
# In privacy mode Ubuntu can't run Windows programs or read Windows files. Instead it drops a
# one-line request into ~/.offload-agent/cmd, and this agent runs it ONLY if it's on this list:
#   ping | sleep | sleep-until HH:MM | wake-at HH:MM | wake-weekly Mon,Tue HH:MM | clear-wake-weekly
#   | off | restart | cancel
# The agent also keeps Ubuntu running and writes, every 2 s:
#   idle       seconds since the PC owner last used keyboard/mouse
#   heartbeat  unix time (proves the agent is alive)
#   mac        network card MAC address(es), for Wake-on-LAN
#
# Started hidden at logon by the scheduled task "OffloadPC agent" (conhost --headless).
param(
  [string]$Distro = 'Ubuntu-24.04',
  [string]$User,
  [string]$Dir,          # override the exchange folder (testing)
  [switch]$NoWsl         # don't start/keep WSL running (testing)
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
if (-not $Dir) { $Dir = "\\wsl.localhost\$Distro\home\$User\.offload-agent" }

# Only one agent per Windows session
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\OffloadPCAgent', [ref]$created)
if (-not $created) { exit 0 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class BadgerIdle {
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static uint Seconds() { LII l = new LII(); l.cbSize = 8; GetLastInputInfo(ref l); return ((uint)Environment.TickCount - l.dwTime) / 1000; }
}
"@

$script:keep = $null
$script:sleepAt = $null

# Short hardware summary, e.g. "GTX 1080 | i7-9700K | 16 GB DDR4 3333MHz" (shown in the powerplant picker)
function Get-Specs {
  $vcs = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
  $gpu = ($vcs | Where-Object { $_.Name -match 'NVIDIA|Radeon|Arc' } | Select-Object -First 1).Name
  if (-not $gpu) { $gpu = ($vcs | Select-Object -First 1).Name }
  $gpu = ($gpu -replace '\((R|TM)\)', '' -replace 'NVIDIA|GeForce|AMD|Radeon(?= RX)|Intel', '' -replace '\s+', ' ').Trim()

  $cpuName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
  $cpu = switch -Regex ($cpuName) {
    '(i[3579]-\w+)'                 { $Matches[1]; break }
    'Core\(TM\) (Ultra \d+ \w+)'    { $Matches[1]; break }
    '(Ryzen( Threadripper)? \d* ?\w+)' { $Matches[1]; break }
    default { (($cpuName -replace '\((R|TM)\)', '' -replace 'CPU|Processor|@.*$|\d+-Core', '' -replace '\s+', ' ').Trim()) }
  }

  $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
  $gb = [math]::Round((($mods | Measure-Object Capacity -Sum).Sum) / 1GB)
  $types = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
  $type = $types[[int]($mods | Select-Object -First 1).SMBIOSMemoryType]
  $speed = ($mods | Select-Object -First 1).ConfiguredClockSpeed
  if (-not $speed) { $speed = ($mods | Select-Object -First 1).Speed }
  $ram = "$gb GB" + $(if ($type) { " $type" }) + $(if ($speed) { " ${speed}MHz" })
  "$gpu | $cpu | $ram"
}
$script:specs = Get-Specs

function Ensure-Wsl {
  if ($NoWsl) { return }
  if (-not $script:keep -or $script:keep.HasExited) {
    $script:keep = Start-Process wsl.exe -ArgumentList @('-d', $Distro, '--exec', 'sleep', 'infinity') -WindowStyle Hidden -PassThru
  }
}

function Schedule-Wake([string]$hhmm) {
  $at = [datetime]::Today.Add([timespan]$hhmm)
  if ($at -lt (Get-Date)) { $at = $at.AddDays(1) }
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit'
  $s = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries
  Register-ScheduledTask -TaskName 'OffloadPC scheduled wake' -Action $a -Trigger (New-ScheduledTaskTrigger -Once -At $at) -Settings $s -Force | Out-Null
  'wake scheduled for ' + $at.ToString('ddd HH:mm')
}

function Invoke-Request([string]$line) {
  $parts = @($line.Trim() -split '\s+')
  $cmd = $parts[0]
  $arg = if ($parts.Count -gt 1) { $parts[1] } else { '' }
  $timeOk = $arg -match '^([01]?\d|2[0-3]):[0-5]\d$'
  switch ($cmd) {
    'ping'        { return 'ok' }
    'sleep'       { $script:sleepAt = (Get-Date).AddSeconds(4); return 'ok sleeping in 4 s' }
    'sleep-until' {
      if (-not $timeOk) { return 'error: time must be HH:MM' }
      $r = Schedule-Wake $arg; $script:sleepAt = (Get-Date).AddSeconds(4); return "ok $r, sleeping in 4 s"
    }
    'wake-at'     { if (-not $timeOk) { return 'error: time must be HH:MM' }; return 'ok ' + (Schedule-Wake $arg) }
    'wake-weekly' {   # wake-weekly Mon,Tue,Wed 22:00  (start of an availability window)
      $days = @($arg -split ',' | Where-Object { $_ })
      $t = if ($parts.Count -gt 2) { $parts[2] } else { '' }
      $map = @{ Mon = 'Monday'; Tue = 'Tuesday'; Wed = 'Wednesday'; Thu = 'Thursday'; Fri = 'Friday'; Sat = 'Saturday'; Sun = 'Sunday' }
      if (-not $days.Count -or ($days | Where-Object { -not $map.ContainsKey($_) }) -or $t -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        return 'error: usage wake-weekly Mon,Tue HH:MM'
      }
      $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ($days | ForEach-Object { $map[$_] }) -At ([datetime]::Today.Add([timespan]$t))
      $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit'
      $s = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries
      Register-ScheduledTask -TaskName "OffloadPC schedule wake $($days -join ',') $($t -replace ':', '')" -Action $a -Trigger $trigger -Settings $s -Force | Out-Null
      return "ok wakes $($days -join ',') at $t"
    }
    'clear-wake-weekly' {
      Get-ScheduledTask -TaskName 'OffloadPC schedule wake*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
      return 'ok cleared'
    }
    'off'         {
      & shutdown.exe /s /t 60 /c 'Remote shutdown (offloadpc-off). Cancel: shutdown /a' 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return 'ok shutting down in 60 s' } else { return "error: shutdown failed ($LASTEXITCODE)" }
    }
    'restart'     {
      & shutdown.exe /r /t 60 /c 'Remote restart (offloadpc-restart). Cancel: shutdown /a' 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return 'ok restarting in 60 s' } else { return "error: restart failed ($LASTEXITCODE)" }
    }
    'cancel'      {
      & shutdown.exe /a 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return 'ok cancelled' } else { return 'ok nothing to cancel' }
    }
    default       { return "error: '$cmd' is not allowed (allowed: ping sleep sleep-until wake-at wake-weekly clear-wake-weekly off restart cancel)" }
  }
}

$lastMac = [datetime]::MinValue
while ($true) {
  Ensure-Wsl
  if (Test-Path -LiteralPath $Dir) {
    try {
      [IO.File]::WriteAllText((Join-Path $Dir 'idle'), [string][BadgerIdle]::Seconds())
      [IO.File]::WriteAllText((Join-Path $Dir 'heartbeat'), [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
      if (((Get-Date) - $lastMac).TotalMinutes -ge 10) {
        $mac = (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' |
                ForEach-Object { "$($_.Name): $($_.MacAddress)" }) -join "`n"
        [IO.File]::WriteAllText((Join-Path $Dir 'mac'), [string]$mac)
        [IO.File]::WriteAllText((Join-Path $Dir 'specs'), [string]$script:specs)
        $lastMac = Get-Date
      }
      $cmdFile = Join-Path $Dir 'cmd'
      if (Test-Path -LiteralPath $cmdFile) {
        $line = [IO.File]::ReadAllText($cmdFile)
        Remove-Item -LiteralPath $cmdFile -Force
        try { $result = Invoke-Request $line } catch { $result = "error: $($_.Exception.Message)" }
        $tmp = Join-Path $Dir 'result.tmp'
        $dst = Join-Path $Dir 'result'
        [IO.File]::WriteAllText($tmp, [string]$result)
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        [IO.File]::Move($tmp, $dst)
      }
    } catch { }
  }
  if ($script:sleepAt -and (Get-Date) -ge $script:sleepAt) {
    $script:sleepAt = $null
    [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)
  }
  Start-Sleep -Seconds 2
}

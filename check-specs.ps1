# Run in a normal PowerShell on the processing offload PC (no admin needed). Read-only - changes nothing.
#   powershell -ExecutionPolicy Bypass -File .\check-specs.ps1
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs  = Get-CimInstance Win32_ComputerSystem
$mb  = Get-CimInstance Win32_BaseBoard

"Windows : $($os.Caption) build $($os.BuildNumber)"
"CPU     : $($cpu.Name.Trim())  ($($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads)"
"RAM     : {0:N0} GB" -f ($cs.TotalPhysicalMemory / 1GB)
"Board   : $($mb.Manufacturer) $($mb.Product)"
Get-CimInstance Win32_VideoController | ForEach-Object { "GPU     : $($_.Name)  driver $($_.DriverVersion)" }
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  "NVIDIA  : " + (nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader)
}
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
  "Disk {0} : {1:N0} GB free of {2:N0} GB" -f $_.DeviceID, ($_.FreeSpace/1GB), ($_.Size/1GB)
}
# When a hypervisor (WSL/Hyper-V) is already running, Windows reports VT as False - treat that as on.
$vt = $cpu.VirtualizationFirmwareEnabled -or $cs.HypervisorPresent
"Virtualization in BIOS: $vt"
$wslv = ''
$oldPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # WSL "not installed" text must not abort
try { $wslv = ((wsl.exe --version 2>$null | Select-Object -First 1) -replace "`0", "") } catch { $wslv = '' }
$ErrorActionPreference = $oldPref
if ($wslv -match 'not installed') { $wslv = '' }
"WSL     : " + $(if ($wslv) { $wslv } else { "not installed yet (fine - step A2 installs it)" })
$global:LASTEXITCODE = 0

""
"--- Ready check ---"
if ([int]$os.BuildNumber -lt 19045) { "X  Windows too old: need Windows 10 22H2 or Windows 11" } else { "OK Windows version" }
if ($vt -eq $false) { "X  Turn on virtualization (Intel VT-x / AMD SVM) in BIOS" } else { "OK Virtualization" }
$c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$(Split-Path -Qualifier $PSScriptRoot)'"   # setup installs on the kit's drive
if ($c.FreeSpace/1GB -lt 60) { "X  Free up space on $($c.DeviceID) (need ~60 GB for WSL + ROS image)" } else { "OK Disk space on $($c.DeviceID)" }

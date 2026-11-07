# Run on YOUR laptop / desktop in an ADMIN PowerShell, after `wsl --install -d Ubuntu-24.04` + reboot
# and after Ubuntu has been opened once (username/password created).
#   powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1

# 1. WSL settings: mirrored networking so Ubuntu uses Windows' Tailscale connection directly.
$ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$wslRam = [math]::Max(4, $ramGB - 4)     # leave 4 GB for Windows
$path = "$env:USERPROFILE\.wslconfig"
if (Test-Path $path) {
  Copy-Item $path "$path.backup" -Force
  Write-Host "Existing .wslconfig backed up to $path.backup"
}
$wslconfig = @"
[wsl2]
memory=${wslRam}GB
swap=8GB
networkingMode=mirrored
dnsTunneling=true
"@
Set-Content -Path $path -Value $wslconfig -Encoding ascii
Write-Host "Wrote $path (WSL RAM: ${wslRam} GB, mirrored networking)"

# 2. Tailscale for Windows (sign in with the SAME account as on the offload PC).
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue)) {
  winget install -e --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements
  Write-Host "Tailscale installed: sign in from its tray icon."
} else {
  Write-Host "Tailscale already installed."
}

wsl --shutdown
Write-Host "Done. Open Ubuntu and run:  bash your-pc/setup-ros-client.sh"

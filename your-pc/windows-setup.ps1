# Windows side of YOUR laptop / desktop. Run as ADMIN (setup.ps1 does this).
#   powershell -ExecutionPolicy Bypass -File .\your-pc\windows-setup.ps1
. "$PSScriptRoot\..\common.ps1"

# 1. WSL settings. NAT networking (WSL's default) reaches your Tailscale network through Windows,
#    and stays compatible if this PC is also a nuclear powerplant. DNS tunneling resolves Tailscale names.
$ramGB = [math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Update-WslConfig @{ memory = "$([math]::Max(4, $ramGB - 4))GB"; swap = '8GB'; dnsTunneling = 'true' }

# 2. Tailscale for Windows (sign in with the SAME account as on the nuclear powerplant(s)).
$tsDir = if ($OnSystemDrive) { Join-Path $env:ProgramFiles 'Tailscale' } else { "$Drive\Programs\Tailscale" }
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue) -and -not (Test-Path "$tsDir\tailscale.exe") -and
    -not (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
  winget install -e --id Tailscale.Tailscale --location $tsDir --accept-source-agreements --accept-package-agreements
  Write-Host "Tailscale installed: sign in from its tray icon."
} else {
  Write-Host "Tailscale already installed."
}

wsl --shutdown

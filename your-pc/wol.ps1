# Send a Wake-on-LAN magic packet from this Windows PC to every local network it's on.
# Works when this PC is on the same LAN / Wi-Fi as the PC to wake (Tailscale can't carry it).
#   powershell -ExecutionPolicy Bypass -File wol.ps1 -Mac 04-D4-C4-04-8D-96
param([Parameter(Mandatory)][string]$Mac)
$hex = $Mac -replace '[:-]', ''
if ($hex -notmatch '^[0-9a-fA-F]{12}$') { Write-Error "Not a MAC address: $Mac"; exit 1 }
$macBytes = [byte[]]::new(6)
for ($i = 0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
$packet = [byte[]]::new(102)
for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
for ($r = 0; $r -lt 16; $r++) { [Array]::Copy($macBytes, 0, $packet, 6 + $r * 6, 6) }

$targets = @([Net.IPAddress]::Broadcast)
foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
  if ($nic.OperationalStatus -ne 'Up') { continue }
  foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
    $a = $u.Address
    if ($a.AddressFamily -ne 'InterNetwork') { continue }
    $s = $a.ToString()
    if ($s.StartsWith('127.') -or $s.StartsWith('100.') -or $s.StartsWith('169.254.')) { continue }   # loopback / Tailscale / link-local
    $ip = $a.GetAddressBytes(); $mask = $u.IPv4Mask.GetAddressBytes()
    $b = [byte[]]::new(4)
    for ($k = 0; $k -lt 4; $k++) { $b[$k] = $ip[$k] -bor (255 -bxor $mask[$k]) }
    $targets += [Net.IPAddress]::new($b)
  }
}
$udp = New-Object Net.Sockets.UdpClient
$udp.EnableBroadcast = $true
$sent = 0
foreach ($t in ($targets | Select-Object -Unique)) {
  foreach ($port in 7, 9) {
    try { [void]$udp.Send($packet, $packet.Length, (New-Object Net.IPEndPoint($t, $port))); $sent++ } catch { }
  }
}
$udp.Close()
"sent $sent magic packets to: $(($targets | Select-Object -Unique | ForEach-Object { $_.ToString() }) -join ', ')"

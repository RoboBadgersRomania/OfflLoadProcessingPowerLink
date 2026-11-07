#!/usr/bin/env bash
# Remote power control for the processing offload PC.
# Runs INSIDE WSL on the offload PC and controls Windows through WSL interop.
# From your PC use the shortcuts (set up by your-pc/setup-ros-client.sh):
#   offloadpc-status              is it on? GPU load/temperature
#   offloadpc-sleep               sleep now (Windows stays logged in -> everything resumes on wake)
#   offloadpc-sleep-until 22:30   sleep now and wake up automatically at 22:30
#   offloadpc-off                 shut down in 60 s   (cancel with offloadpc-cancel)
#   offloadpc-restart             restart in 60 s     (cancel with offloadpc-cancel)
#   offloadpc-cancel              cancel a pending shutdown/restart
#   offloadpc-mac                 network card MAC address (for Wake-on-LAN)
set -uo pipefail

# --- Make Windows programs callable from an SSH session (sshd/tailscaled run under systemd) ---
if [ -z "${WSL_INTEROP:-}" ]; then
  sock=$(ls -t /run/WSL/*_interop 2>/dev/null | head -1)
  [ -n "$sock" ] && export WSL_INTEROP="$sock"
fi
if ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qi '^WSLInterop'; then
  echo ':WSLInterop:M::MZ::/init:PF' | sudo tee /proc/sys/fs/binfmt_misc/register >/dev/null
fi
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
SHUTDOWN=/mnt/c/Windows/System32/shutdown.exe
win() { "$PS" -NoProfile -NonInteractive -Command "$1"; }
SLEEP_CMD="Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', \$false, \$false)"

# Sleep a few seconds after this SSH session returns, so your terminal doesn't hang.
sleep_later() { setsid nohup bash -c "sleep 5; \"$PS\" -NoProfile -NonInteractive -Command \"$SLEEP_CMD\"" >/dev/null 2>&1 & }

if ! win "exit 0" >/dev/null 2>&1; then
  echo "ERROR: can't reach Windows from WSL (interop). Run 'wsl --shutdown' on the offload PC and log in again."
  exit 1
fi

case "${1:-status}" in
  status)
    echo "Offload PC is ON - $(uptime -p)"
    nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
      --format=csv,noheader 2>/dev/null || echo "(GPU info unavailable)"
    ;;
  sleep)
    echo "Offload PC goes to sleep in 5 s. Wake it with Wake-on-LAN or a scheduled wake (offloadpc-sleep-until)."
    sleep_later
    ;;
  sleep-until)
    t="${2:-}"
    if ! [[ "$t" =~ ^[0-2]?[0-9]:[0-5][0-9]$ ]]; then echo "Usage: offloadpc-sleep-until HH:MM   (24h, e.g. 22:30)"; exit 1; fi
    win "\$at = [datetime]::Today.Add([timespan]'$t'); if (\$at -lt (Get-Date)) { \$at = \$at.AddDays(1) };
         \$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit';
         \$s = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries;
         Register-ScheduledTask -TaskName 'OffloadPC scheduled wake' -Action \$a -Trigger (New-ScheduledTaskTrigger -Once -At \$at) -Settings \$s -Force | Out-Null;
         'Wake scheduled for ' + \$at.ToString('ddd HH:mm')" || { echo "Could not schedule the wake - not sleeping."; exit 1; }
    echo "Offload PC goes to sleep in 5 s."
    sleep_later
    ;;
  off)
    "$SHUTDOWN" /s /t 60 /c "Remote shutdown (offloadpc-off). Cancel: shutdown /a" \
      && echo "Shutting down in 60 s (cancel: offloadpc-cancel). Note: after a shutdown it can only be started with Wake-on-LAN or the power button, and Windows must log in again."
    ;;
  restart)
    "$SHUTDOWN" /r /t 60 /c "Remote restart (offloadpc-restart). Cancel: shutdown /a" \
      && echo "Restarting in 60 s (cancel: offloadpc-cancel). Windows must log in again (auto-login) for ROS to come back."
    ;;
  cancel)
    "$SHUTDOWN" /a && echo "Pending shutdown/restart cancelled."
    ;;
  mac)
    win "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | ForEach-Object { \$_.Name + ': ' + \$_.MacAddress }"
    ;;
  *)
    echo "Usage: power.sh status|sleep|sleep-until HH:MM|off|restart|cancel|mac"; exit 1
    ;;
esac

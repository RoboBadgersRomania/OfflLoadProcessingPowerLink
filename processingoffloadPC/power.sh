#!/usr/bin/env bash
# Remote power control + activity report for the processing offload PC ("nuclear powerplant").
# Runs INSIDE WSL on the offload PC and controls Windows through WSL interop.
# From your PC use the shortcuts (set up by your-pc/setup-ros-client.sh):
#   start-nuclear-powerplant           make sure ROS is running, open a ROS shell
#   sleep-nuclear-powerplant [HH:MM]   sleep now (and wake at HH:MM if given)
#   show-running-processes             what's running? safe to power off?
#   sleep-after-finish [HH:MM]         sleep automatically once your work is done (wake at HH:MM)
#   sleep-after-finish status|cancel
#   offloadpc-status | offloadpc-off | offloadpc-restart | offloadpc-cancel | offloadpc-mac
# Direct use: power.sh start|status|processes|sleep|sleep-until HH:MM|off|restart|cancel|mac [--force]
# sleep/off/restart refuse when the PC looks busy, unless you confirm (terminal) or pass --force.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=0
ARGS=()
for a in "$@"; do if [ "$a" = "--force" ]; then FORCE=1; else ARGS+=("$a"); fi; done
ACTION="${ARGS[0]:-status}"
ARG1="${ARGS[1]:-}"

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

# Run PowerShell code on Windows. -EncodedCommand avoids every quoting problem between bash and Windows.
encode() { printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0; }
# (progress bars off: otherwise PowerShell prints CLIXML clutter when its output is piped)
win() { "$PS" -NoProfile -NonInteractive -EncodedCommand "$(encode "\$ProgressPreference='SilentlyContinue'; $1")" | tr -d '\r'; }

SLEEP_PS="Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', \$false, \$false)"
# Sleep a few seconds after this SSH session returns, so your terminal doesn't hang.
sleep_later() { setsid nohup bash -c "sleep 5; \"$PS\" -NoProfile -NonInteractive -EncodedCommand $(encode "$SLEEP_PS")" >/dev/null 2>&1 & }

IDLE_PS='Add-Type @"
using System; using System.Runtime.InteropServices;
public static class BadgerIdle {
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static uint Seconds() { LII l = new LII(); l.cbSize = 8; GetLastInputInfo(ref l); return ((uint)Environment.TickCount - l.dwTime) / 1000; }
}
"@; [BadgerIdle]::Seconds()'

docker_c() { docker "$@" 2>/dev/null || sudo -n docker "$@" 2>/dev/null; }
compose() { (cd "$REPO/docker" && docker_c compose "$@"); }

# Prints the activity report. Returns 0 = idle (safe to power off), 1 = busy.
busy_report() {
  local busy=0 reasons=()
  echo "========== Nuclear powerplant activity =========="
  # GPU
  local g gu gm gt
  g=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$g" ]; then
    IFS=', ' read -r gu gm gt <<<"$g"
    echo "GPU      : ${gu}% busy, ${gm} / ${gt} MiB memory used"
    if [ "${gu:-0}" -ge 10 ]; then busy=1; reasons+=("GPU ${gu}% busy"); fi
  else
    echo "GPU      : (nvidia-smi unavailable)"
  fi
  # CPU
  local load cores
  read -r load _ < /proc/loadavg; cores=$(nproc)
  echo "CPU load : $load (1 min) on $cores threads"
  if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c*0.25)}'; then busy=1; reasons+=("CPU load $load"); fi
  # Windows user (someone sitting at the PC?)
  local idle
  idle=$(win "$IDLE_PS" 2>/dev/null | tail -1)
  if [[ "$idle" =~ ^[0-9]+$ ]]; then
    echo "Windows  : last keyboard/mouse use $((idle / 60)) min ago"
    if [ "$idle" -lt 600 ]; then busy=1; reasons+=("someone used the PC $((idle / 60)) min ago"); fi
  else
    echo "Windows  : (couldn't read keyboard/mouse activity)"
  fi
  # Containers
  echo; echo "--- Docker containers ---"
  docker_c stats --no-stream --format '  {{.Name}}: CPU {{.CPUPerc}}  RAM {{.MemUsage}}' || echo "  (docker not reachable)"
  # Top processes (Ubuntu + inside containers)
  echo; echo "--- Top processes by CPU ---"
  ps -eo pcpu=CPU%,pmem=MEM%,etime=RUNNING,comm=COMMAND --sort=-pcpu | head -8 | sed 's/^/  /'
  # ROS nodes
  echo; echo "--- ROS 2 nodes ---"
  local nodes
  nodes=$(compose exec -T dev timeout 15 bash -lc 'source /opt/ros/jazzy/setup.bash; ros2 node list 2>/dev/null' \
          | tr -d '\r' | grep -v -e foxglove -e '^\s*$' || true)
  if [ -n "$nodes" ]; then
    echo "$nodes" | sed 's/^/  /'
    busy=1; reasons+=("$(echo "$nodes" | wc -l) ROS node(s) running")
  else
    echo "  none (besides the Foxglove bridge)"
  fi
  # Background jobs (tmux) on Ubuntu and in the dev container. A pane only counts as busy while it
  # runs a program; a finished job leaves just a shell (bash) behind, which counts as idle.
  echo; echo "--- Background jobs (tmux) ---"
  local fmt='#{session_name}: #{pane_current_command}' tm running
  tm=$( { tmux list-panes -a -F "$fmt" 2>/dev/null; compose exec -T dev tmux list-panes -a -F "$fmt" 2>/dev/null; } \
        | tr -d '\r' | grep -v -i -e 'no server' -e 'error' -e '^\s*$' || true)
  running=$(echo "$tm" | grep -v -E ': (bash|zsh|sh|fish|dash)$' | grep -v '^\s*$' || true)
  if [ -n "$tm" ]; then
    echo "$tm" | sed -E 's/^/  /; s/: (bash|zsh|sh|fish|dash)$/: (finished, shell waiting)/'
  else
    echo "  none"
  fi
  if [ -n "$running" ]; then busy=1; reasons+=("$(echo "$running" | wc -l) tmux job(s) still running"); fi
  echo
  if [ "$busy" = 1 ]; then
    echo "VERDICT: BUSY - $(IFS=';'; echo "${reasons[*]}" | sed 's/;/, /g'). Better not power it off yet."
    return 1
  fi
  echo "VERDICT: IDLE - safe to sleep or power off."
  return 0
}

# Refuse to sleep/shut down a busy PC unless confirmed.
guard() {
  [ "$FORCE" = 1 ] && return 0
  local report rc
  report=$(busy_report); rc=$?
  if [ "$rc" = 0 ]; then echo "Idle - OK."; return 0; fi
  echo "$report"
  if [ -t 0 ]; then
    read -r -p "The nuclear powerplant looks busy. $1 anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]] && return 0
    echo "Cancelled."; exit 3
  fi
  echo "BUSY - add --force to do it anyway."; exit 2
}

# Register a one-time Windows task that wakes the PC at HH:MM (today, or tomorrow if already past).
schedule_wake() {
  win "\$at = [datetime]::Today.Add([timespan]'$1'); if (\$at -lt (Get-Date)) { \$at = \$at.AddDays(1) }
       \$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit'
       \$s = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries
       Register-ScheduledTask -TaskName 'OffloadPC scheduled wake' -Action \$a -Trigger (New-ScheduledTaskTrigger -Once -At \$at) -Settings \$s -Force | Out-Null
       'Wake scheduled for ' + \$at.ToString('ddd HH:mm')"
}
valid_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# sleep-after-finish: background watcher state
SAF_PID=/tmp/offloadpc-sleep-after-finish.pid
SAF_LOG=/tmp/offloadpc-sleep-after-finish.log
SAF_IDLE_CHECKS="${SAF_IDLE_CHECKS:-5}"   # consecutive idle checks (1/min) before sleeping
saf_running() { [ -f "$SAF_PID" ] && kill -0 "$(cat "$SAF_PID")" 2>/dev/null; }

if ! win "exit 0" >/dev/null 2>&1; then
  echo "ERROR: can't reach Windows from WSL (interop). Run 'wsl --shutdown' on the offload PC and log in again."
  exit 1
fi

case "$ACTION" in
  status)
    echo "Nuclear powerplant is ON - $(uptime -p)"
    nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
      --format=csv,noheader 2>/dev/null || echo "(GPU info unavailable)"
    ;;
  start)
    echo "Nuclear powerplant is ON - $(uptime -p). Starting ROS containers..."
    compose up -d && compose ps --format '  {{.Service}}: {{.Status}}'
    ;;
  processes)
    busy_report
    ;;
  sleep)
    guard "Sleep"
    echo "Nuclear powerplant goes to sleep in 5 s. Wake it with Wake-on-LAN, or use: sleep-nuclear-powerplant HH:MM"
    sleep_later
    ;;
  sleep-until)
    if ! valid_time "$ARG1"; then echo "Usage: sleep-nuclear-powerplant HH:MM   (24h, e.g. 22:30)"; exit 1; fi
    guard "Sleep"
    schedule_wake "$ARG1" || { echo "Could not schedule the wake - not sleeping."; exit 1; }
    echo "Nuclear powerplant goes to sleep in 5 s."
    sleep_later
    ;;
  sleep-after-finish)
    case "$ARG1" in
      cancel)
        if saf_running; then kill "$(cat "$SAF_PID")"; rm -f "$SAF_PID"; echo "sleep-after-finish cancelled. The PC stays on.";
        else echo "No sleep-after-finish is waiting."; fi
        ;;
      status)
        if saf_running; then echo "sleep-after-finish is WAITING. Recent checks:"; tail -n 5 "$SAF_LOG" 2>/dev/null | sed 's/^/  /';
        else echo "sleep-after-finish is not active."; fi
        ;;
      ""|*:*)
        if [ -n "$ARG1" ] && ! valid_time "$ARG1"; then echo "Usage: sleep-after-finish [HH:MM|status|cancel]"; exit 1; fi
        if saf_running; then kill "$(cat "$SAF_PID")" 2>/dev/null; fi
        : > "$SAF_LOG"
        setsid nohup bash "${BASH_SOURCE[0]}" _watch "$ARG1" >>"$SAF_LOG" 2>&1 &
        echo $! > "$SAF_PID"
        echo "OK - the nuclear powerplant will sleep once it has been idle for $SAF_IDLE_CHECKS min in a row"
        echo "(GPU/CPU quiet, no ROS nodes, no running tmux jobs, nobody at the keyboard)."
        [ -n "$ARG1" ] && echo "It will wake up again at $ARG1."
        echo "Check: sleep-after-finish status    Cancel: sleep-after-finish cancel"
        ;;
      *) echo "Usage: sleep-after-finish [HH:MM|status|cancel]"; exit 1 ;;
    esac
    ;;
  _watch)   # internal: background loop started by sleep-after-finish
    idle=0
    while true; do
      if busy_report > /tmp/offloadpc-saf-report.txt 2>&1; then idle=$((idle + 1)); else idle=0; fi
      echo "$(date '+%a %H:%M')  idle ${idle}/${SAF_IDLE_CHECKS}  $(grep -m1 VERDICT /tmp/offloadpc-saf-report.txt)"
      if [ "$idle" -ge "$SAF_IDLE_CHECKS" ]; then
        if [ -n "$ARG1" ]; then schedule_wake "$ARG1"; fi
        echo "$(date '+%a %H:%M')  work finished - going to sleep"
        rm -f "$SAF_PID"
        win "$SLEEP_PS"
        exit 0
      fi
      sleep 60
    done
    ;;
  off)
    guard "Shut down"
    "$SHUTDOWN" /s /t 60 /c "Remote shutdown (offloadpc-off). Cancel: shutdown /a" \
      && echo "Shutting down in 60 s (cancel: offloadpc-cancel). After a shutdown it only starts with Wake-on-LAN or the power button, and Windows must log in again."
    ;;
  restart)
    guard "Restart"
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
    echo "Usage: power.sh start|status|processes|sleep|sleep-until HH:MM|sleep-after-finish [HH:MM|status|cancel]|off|restart|cancel|mac [--force]"; exit 1
    ;;
esac

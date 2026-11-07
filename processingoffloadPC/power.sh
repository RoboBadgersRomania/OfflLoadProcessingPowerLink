#!/usr/bin/env bash
# Power control + activity report for a processing offload PC ("nuclear powerplant").
# Runs INSIDE Ubuntu (WSL) on the offload PC. Windows is only reached through the Windows agent
# (agent.ps1), which accepts a fixed list of requests - Ubuntu can't touch the owner's files.
#
# From your PC use the shortcuts (your-pc/setup-ros-client.sh) or the VS Code extension:
#   start-nuclear-powerplant | sleep-nuclear-powerplant [HH:MM] [--after-finish] | show-running-processes
#   offloadpc-status | offloadpc-off | offloadpc-restart | offloadpc-cancel | offloadpc-mac
#   offloadpc-resume | offloadpc-guardian [on|off|status] | offloadpc-notifications
#
# Direct: power.sh status|specs|start|processes|sleep|sleep-until HH:MM|
#                  sleep-after-finish [HH:MM|status|cancel]|off|restart|cancel|mac|
#                  resume|guardian [on|off|status]|notify-info|notify-test   [--force]
# sleep/off/restart refuse when the PC looks busy, unless you confirm (terminal) or pass --force.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
ARGS=()
for a in "$@"; do if [ "$a" = "--force" ]; then FORCE=1; else ARGS+=("$a"); fi; done
ACTION="${ARGS[0]:-status}"
ARG1="${ARGS[1]:-}"

valid_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }
ok_or_fail() { local out; out=$(agent "$@"); echo "$out"; [[ "$out" == ok* ]]; }

# Prints the activity report. Returns 0 = idle (safe to power off), 1 = busy.
busy_report() {
  local busy=0 reasons=()
  echo "========== $(powerplant_name): activity =========="
  # GPU
  local g gu gm gt
  g=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$g" ]; then
    IFS=', ' read -r gu gm gt <<<"$g"
    echo "GPU      : ${gu}% busy, ${gm} / ${gt} MiB memory used"
    if [ "${gu:-0}" -ge 10 ] 2>/dev/null; then busy=1; reasons+=("GPU ${gu}% busy"); fi
  else
    echo "GPU      : (nvidia-smi unavailable)"
  fi
  # CPU
  local load cores
  read -r load _ < /proc/loadavg; cores=$(nproc)
  echo "CPU load : $load (1 min) on $cores threads"
  if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c*0.25)}'; then busy=1; reasons+=("CPU load $load"); fi
  # PC owner at the keyboard?
  local idle; idle=$(win_idle || true)
  if [ -n "$idle" ]; then
    echo "Owner    : last keyboard/mouse use $((idle / 60)) min ago"
    if [ "$idle" -lt 600 ]; then busy=1; reasons+=("someone used the PC $((idle / 60)) min ago"); fi
  else
    echo "Owner    : (unknown - Windows agent not running)"
  fi
  # Guardian pause
  if dev_paused; then busy=1; reasons+=("your job is PAUSED because someone is using the PC"); echo "Guardian : job PAUSED (owner using the PC)"; fi
  # Containers
  echo; echo "--- Docker containers ---"
  docker_c stats --no-stream --format '  {{.Name}}: CPU {{.CPUPerc}}  RAM {{.MemUsage}}' || echo "  (docker not reachable)"
  # Top processes (Ubuntu + inside containers)
  echo; echo "--- Top processes by CPU ---"
  ps -eo pcpu=CPU%,pmem=MEM%,etime=RUNNING,comm=COMMAND --sort=-pcpu | head -8 | sed 's/^/  /'
  # ROS nodes
  echo; echo "--- ROS 2 nodes ---"
  local nodes=""
  if ! dev_paused; then
    nodes=$(compose exec -T dev timeout 15 bash -lc 'source /opt/ros/jazzy/setup.bash; ros2 node list 2>/dev/null' \
            | tr -d '\r' | grep -v -e foxglove -e '^\s*$' || true)
  fi
  if [ -n "$nodes" ]; then
    echo "$nodes" | sed 's/^/  /'
    busy=1; reasons+=("$(echo "$nodes" | wc -l) ROS node(s) running")
  else
    echo "  none (besides the Foxglove bridge)"
  fi
  # Background jobs (tmux). A pane only counts while it runs a program; a finished job leaves a shell.
  echo; echo "--- Background jobs (tmux) ---"
  local fmt='#{session_name}: #{pane_current_command}' tm running
  tm=$( { tmux list-panes -a -F "$fmt" 2>/dev/null; dev_paused || compose exec -T dev tmux list-panes -a -F "$fmt" 2>/dev/null; } \
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
    read -r -p "$(powerplant_name) looks busy. $1 anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]] && return 0
    echo "Cancelled."; exit 3
  fi
  echo "BUSY - add --force to do it anyway."; exit 2
}

# sleep-after-finish: background watcher state
SAF_PID=/tmp/offloadpc-sleep-after-finish.pid
SAF_LOG=/tmp/offloadpc-sleep-after-finish.log
SAF_IDLE_CHECKS="${SAF_IDLE_CHECKS:-5}"   # consecutive idle checks (1/min) before sleeping
saf_running() { [ -f "$SAF_PID" ] && kill -0 "$(cat "$SAF_PID")" 2>/dev/null; }

owner_warning() {
  local idle; idle=$(win_idle || true)
  if [ -n "$idle" ] && [ "$idle" -lt 600 ]; then
    echo "WARNING: someone used this PC $((idle / 60)) min ago - they may be using it right now."
    load_conf
    if [ "${ENABLED:-1}" = 1 ]; then echo "         If they use it while your job runs, the guardian pauses the job and notifies you."; fi
  fi
}

case "$ACTION" in
  status)
    echo "$(powerplant_name) is ON - $(uptime -p)"
    echo "Specs: $(cat "$AGENT/specs" 2>/dev/null | tr -d '\r' || echo unknown)"
    nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
      --format=csv,noheader 2>/dev/null || echo "(GPU info unavailable)"
    idle=$(win_idle || true); [ -n "$idle" ] && echo "Owner: last keyboard/mouse use $((idle / 60)) min ago"
    if [ -f "$STATE" ] && dev_paused; then echo "Guardian: PAUSED - someone is using this PC (since $(date -d "@$(cat "$STATE")" +%H:%M))"; fi
    agent_alive || echo "Agent: NOT RUNNING (power commands won't work until someone logs in to Windows)"
    ;;
  specs)
    cat "$AGENT/specs" 2>/dev/null | tr -d '\r'; echo
    ;;
  start)
    echo "$(powerplant_name) is ON - $(uptime -p). Starting ROS containers..."
    owner_warning
    compose up -d && compose ps --format '  {{.Service}}: {{.Status}}'
    if [ -f "$STATE" ] && dev_paused; then echo "NOTE: your job is still PAUSED by the guardian (owner active). Force: offloadpc-resume"; fi
    ;;
  processes)
    busy_report
    ;;
  sleep)
    guard "Sleep"
    ok_or_fail sleep && echo "$(powerplant_name) goes to sleep. Wake: Wake-on-LAN, or next time sleep-nuclear-powerplant HH:MM"
    ;;
  sleep-until)
    if ! valid_time "$ARG1"; then echo "Usage: sleep-nuclear-powerplant HH:MM   (24h, e.g. 22:30)"; exit 1; fi
    guard "Sleep"
    ok_or_fail sleep-until "$ARG1"
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
        agent_alive || { echo "ERROR: the Windows agent isn't running, so it couldn't sleep later."; exit 1; }
        if saf_running; then kill "$(cat "$SAF_PID")" 2>/dev/null; fi
        : > "$SAF_LOG"
        setsid nohup bash "${BASH_SOURCE[0]}" _watch "$ARG1" >>"$SAF_LOG" 2>&1 &
        echo $! > "$SAF_PID"
        echo "OK - $(powerplant_name) will sleep once it has been idle for $SAF_IDLE_CHECKS min in a row"
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
        echo "$(date '+%a %H:%M')  work finished - going to sleep"
        rm -f "$SAF_PID"
        notify "$(powerplant_name) is going to sleep" "Your work finished, so it is going to sleep now.${ARG1:+ It wakes up at $ARG1.}" "zzz"
        if [ -n "$ARG1" ]; then agent sleep-until "$ARG1"; else agent sleep; fi
        exit 0
      fi
      sleep 60
    done
    ;;
  off)
    guard "Shut down"
    ok_or_fail off && echo "Cancel within 60 s: offloadpc-cancel. After a shutdown it only starts with Wake-on-LAN or the power button."
    ;;
  restart)
    guard "Restart"
    ok_or_fail restart && echo "Cancel within 60 s: offloadpc-cancel. Windows must log in again before ROS is back."
    ;;
  cancel)
    agent cancel
    ;;
  mac)
    cat "$AGENT/mac" 2>/dev/null | tr -d '\r' || echo "unknown (Windows agent not running)"; echo
    ;;
  resume)
    if dev_paused; then
      docker_c unpause "$(dev_id)" >/dev/null && rm -f "$STATE"
      echo $(( $(date +%s) + 3600 )) > "$OVERRIDE"
      echo "Job resumed. The guardian won't pause it again for 60 min."
      owner_warning
    else
      echo "Nothing is paused."
    fi
    ;;
  guardian)
    load_conf
    case "$ARG1" in
      on|off)
        v=$([ "$ARG1" = on ] && echo 1 || echo 0)
        if grep -q '^ENABLED=' "$CONF" 2>/dev/null; then sed -i "s/^ENABLED=.*/ENABLED=$v/" "$CONF"; else echo "ENABLED=$v" >> "$CONF"; fi
        echo "Guardian is now $([ "$v" = 1 ] && echo ON || echo OFF)."
        if [ "$v" = 0 ] && dev_paused && [ -f "$STATE" ]; then docker_c unpause "$(dev_id)" >/dev/null; rm -f "$STATE"; echo "Paused job resumed."; fi
        ;;
      *)
        echo "Guardian: $([ "${ENABLED:-1}" = 1 ] && echo ON || echo OFF)  (pauses your job while the PC owner is active, resumes after $(( ${RESUME_AFTER_IDLE:-600} / 60 )) min idle)"
        if [ -f "$STATE" ] && dev_paused; then echo "Right now: job PAUSED since $(date -d "@$(cat "$STATE")" +%H:%M)"; else echo "Right now: nothing paused"; fi
        echo "Recent events:"; tail -n 5 "$AGENT/guardian.log" 2>/dev/null | sed 's/^/  /'
        ;;
    esac
    ;;
  notify-info)
    load_conf
    if [ -n "${NTFY_TOPIC:-}" ]; then
      echo "Notifications for $(powerplant_name) (job paused / resumed / going to sleep) go to ntfy topic:"
      echo "  ${NTFY_TOPIC}"
      echo "Phone: install the 'ntfy' app -> + -> subscribe to that topic."
      echo "Browser: ${NTFY_SERVER:-https://ntfy.sh}/${NTFY_TOPIC}"
      echo "Test: offloadpc-notifications test"
    else
      echo "Notifications are off (NTFY_TOPIC is empty in ~/.offload-agent/guardian.conf)."
    fi
    ;;
  notify-test)
    notify "Test from $(powerplant_name)" "Notifications work." "white_check_mark"; echo "Test notification sent."
    ;;
  *)
    echo "Usage: power.sh status|specs|start|processes|sleep|sleep-until HH:MM|sleep-after-finish [HH:MM|status|cancel]|off|restart|cancel|mac|resume|guardian [on|off|status]|notify-info|notify-test [--force]"
    exit 1
    ;;
esac

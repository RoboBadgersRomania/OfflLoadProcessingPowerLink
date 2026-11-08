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
    mac=$(grep -oiE '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}' "$AGENT/mac" 2>/dev/null | head -1); [ -n "$mac" ] && echo "MAC: $mac"
    load_conf; [ -n "${WAKE_TOPIC:-}" ] && echo "WakeTopic: $WAKE_TOPIC"
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
  wake-topic)
    load_conf; echo "${WAKE_TOPIC:-}"
    ;;
  wake-info)
    load_conf
    mac=$(grep -oiE '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}' "$AGENT/mac" 2>/dev/null | head -1)
    echo "Wake $(powerplant_name) from any network: run a wake listener on ITS home network."
    echo "  Wake topic : ${WAKE_TOPIC:-none - rerun SETUP-processingoffloadPC.cmd}"
    echo "  MAC        : ${mac:-unknown}"
    echo "  Raspberry Pi / old laptop / Android (Termux):"
    echo "    python3 wake_listener.py --topic ${WAKE_TOPIC:-TOPIC}            (sudo ... --install-service = start at boot)"
    echo "  ESP32 board: put the topic in wake-listener/esp32_wake_listener/esp32_wake_listener.ino"
    ;;
  notify-test)
    notify "Test from $(powerplant_name)" "Notifications work." "white_check_mark"; echo "Test notification sent."
    ;;

  # ---------------- distributed work (used by cluster/distribute.py on your PC) ----------------
  capacity)   # one JSON line: hardware + current load, for the scheduler
    g=$(nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    read -r load _ < /proc/loadavg
    jobs_running=$( (dev_paused || compose exec -T dev tmux list-panes -a -F '#{session_name} #{pane_current_command}' 2>/dev/null) \
                    | tr -d '\r' | grep '^job_' | grep -cvE ' (bash|sh)$' || true)
    load_conf
    GPU_CSV="$g" LOAD="$load" THREADS="$(nproc)" IDLE="$(win_idle || echo -1)" PAUSED="$(dev_paused && echo 1 || echo 0)" \
    JOBS="${jobs_running:-0}" GUARD="${ENABLED:-1}" NAME="$(powerplant_name)" SPECS="$(cat "$AGENT/specs" 2>/dev/null | tr -d '\r')" \
    ROLE="$(pc_role)" AVAIL="$(available && echo 1 || echo 0)" SCHED="${SCHEDULE:-}" HWJSON="$AGENT/hwcheck.json" \
    python3 - <<'EOF'
import json, os
def num(x, d=0.0):
    try: return float(x)
    except (TypeError, ValueError): return d
g = [p.strip() for p in os.environ.get('GPU_CSV', '').split(',')] if os.environ.get('GPU_CSV') else []
mem = {}
for line in open('/proc/meminfo'):
    k, v = line.split(':', 1); mem[k] = int(v.split()[0])
import time
try:
    h = json.load(open(os.environ['HWJSON']))
    hw = {'verified': bool(h.get('verified')), 'hw_summary': h.get('summary', ''), 'hw_age_h': round((time.time() - h['time']) / 3600, 1)}
except (OSError, ValueError, KeyError):
    hw = {'verified': None, 'hw_summary': 'not checked yet', 'hw_age_h': None}
print(json.dumps({
    'name': os.environ['NAME'], 'specs': os.environ['SPECS'],
    'gpu': g[0] if g else '', 'vram_total_mb': num(g[1]) if len(g) > 1 else 0, 'vram_used_mb': num(g[2]) if len(g) > 2 else 0,
    'gpu_util': num(g[3]) if len(g) > 3 else 0,
    'threads': int(os.environ['THREADS']), 'load1': num(os.environ['LOAD']),
    'ram_total_gb': round(mem.get('MemTotal', 0) / 1048576, 1), 'ram_avail_gb': round(mem.get('MemAvailable', 0) / 1048576, 1),
    'owner_idle_s': int(num(os.environ['IDLE'], -1)), 'paused': os.environ['PAUSED'] == '1',
    'guardian': os.environ['GUARD'] == '1', 'jobs_running': int(num(os.environ['JOBS'])),
    'role': os.environ['ROLE'], 'available': os.environ['AVAIL'] == '1', 'schedule': os.environ['SCHED'],
    **hw,
}))
EOF
    ;;
  run-job)    # run-job NAME BASE64_COMMAND : start a job in the dev container, in tmux session job_NAME
    name="$ARG1"; cmd=$(printf '%s' "${ARGS[2]:-}" | base64 -d 2>/dev/null)
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: job name must be letters, digits, - or _"; exit 1; }
    [ -n "$cmd" ] || { echo "error: empty command"; exit 1; }
    if dev_paused; then echo "error: the ROS container is paused (owner using the PC)"; exit 1; fi
    compose up -d dev >/dev/null 2>&1
    mkdir -p "$REPO/ws/.jobs"
    {
      echo '#!/bin/bash'
      echo 'source /opt/ros/jazzy/setup.bash'
      echo '[ -f /ws/install/setup.bash ] && source /ws/install/setup.bash'
      echo "cd /ws; export BADGER_JOB='$name' BADGER_POWERPLANT='$(powerplant_name)'"
      echo "echo \"[job $name started on $(powerplant_name) at \$(date)]\""
      printf '%s\n' "$cmd"
      echo 'rc=$?; echo "[job '"$name"' finished with exit code $rc at $(date)]"'
    } > "$REPO/ws/.jobs/$name.sh"
    compose exec -T dev tmux kill-session -t "job_$name" >/dev/null 2>&1
    : > "$REPO/ws/.jobs/$name.log"
    if compose exec -T dev tmux new-session -d -s "job_$name" "bash /ws/.jobs/$name.sh 2>&1 | tee -a /ws/.jobs/$name.log; exec bash"; then
      echo "ok job $name started on $(powerplant_name)"
    else
      echo "error: could not start job $name"; exit 1
    fi
    ;;
  jobs)       # list jobs: NAME running|finished + last log line
    panes=$(compose exec -T dev tmux list-panes -a -F '#{session_name} #{pane_current_command}' 2>/dev/null | tr -d '\r' | grep '^job_' || true)
    if [ -z "$panes" ]; then echo "(no jobs on $(powerplant_name))"; exit 0; fi
    while read -r sess cmdname; do
      n=${sess#job_}
      state=$([[ "$cmdname" =~ ^(bash|sh)$ ]] && echo finished || echo running)
      dev_paused && state=paused
      printf '%-24s %-9s %s\n' "$n" "$state" "$(tail -n 1 "$REPO/ws/.jobs/$n.log" 2>/dev/null | cut -c1-80)"
    done <<<"$panes"
    ;;
  stop-jobs)  # stop-jobs [NAME|all]
    target="${ARG1:-all}"
    for sess in $(compose exec -T dev tmux list-sessions -F '#{session_name}' 2>/dev/null | tr -d '\r' | grep '^job_'); do
      if [ "$target" = all ] || [ "$sess" = "job_$target" ]; then compose exec -T dev tmux kill-session -t "$sess" && echo "stopped ${sess#job_}"; fi
    done
    ;;
  job-log)
    tail -n "${ARGS[2]:-40}" "$REPO/ws/.jobs/$ARG1.log" 2>/dev/null || echo "no log for job $ARG1"
    ;;
  role)       # role [nodeuser|both|processing] : is this PC shared? (switched from the app's My PC tab)
    case "$ARG1" in
      nodeuser)
        conf_set ROLE nodeuser
        compose stop >/dev/null 2>&1
        echo "Role: NodeUser - this PC is no longer shared (its ROS containers are stopped)." ;;
      both|processing)
        conf_set ROLE "$ARG1"
        compose up -d >/dev/null 2>&1
        echo "Role: $([ "$ARG1" = both ] && echo Both || echo ProcessingNode) - this PC is shared$(in_schedule || echo ', but it is outside its schedule right now')." ;;
      "") pc_role ;;
      *) echo "Usage: power.sh role nodeuser|both|processing"; exit 1 ;;
    esac
    ;;
  schedule)   # schedule [show] | clear | "Mon-Fri 22:00-08:00; Sat-Sun 00:00-24:00"
    spec="${ARGS[*]:1}"
    case "$spec" in
      ""|show)
        load_conf
        echo "Schedule: ${SCHEDULE:-always available}"
        if in_schedule; then echo "Now: inside the window (shared)"; else echo "Now: outside the window (not shared; sleeps when idle)"; fi ;;
      clear)
        conf_set SCHEDULE ""
        agent clear-wake-weekly >/dev/null
        echo "Schedule cleared: always available." ;;
      *)
        # validate + expand day ranges for the Windows wake tasks
        rules=$(SPEC="$spec" python3 - <<'EOF'
import os, re, sys
D = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
out = []
for rule in os.environ['SPEC'].split(';'):
    if not rule.strip():
        continue
    r = re.match(r'\s*([A-Za-z,\- ]+?)\s+(\d{1,2}):(\d\d)\s*-\s*(\d{1,2}):(\d\d)\s*$', rule)
    if not r or int(r.group(2)) > 24 or int(r.group(4)) > 24:
        sys.exit(f'bad rule: {rule.strip()!r}  (example: Mon-Fri 22:00-08:00)')
    days = []
    for part in r.group(1).split(','):
        part = part.strip()
        try:
            if '-' in part:
                a, b = (D.index(x.strip()[:3].title()) for x in part.split('-'))
                k = a
                while True:
                    days.append(D[k])
                    if k == b: break
                    k = (k + 1) % 7
            else:
                days.append(D[D.index(part[:3].title())])
        except ValueError:
            sys.exit(f'bad day in {rule.strip()!r} (use Mon Tue Wed Thu Fri Sat Sun)')
    start = f'{int(r.group(2)) % 24:02d}:{r.group(3)}'
    out.append(f"{','.join(days)} {start}")
print('\n'.join(out))
EOF
) || { echo "$rules"; exit 1; }
        conf_set SCHEDULE "$spec"
        agent clear-wake-weekly >/dev/null
        while read -r days start; do
          [ -n "$days" ] && echo "  wake: $(agent wake-weekly "$days" "$start")"
        done <<<"$rules"
        echo "Schedule set: $spec"
        if in_schedule; then echo "Now: inside the window (shared)"; else echo "Now: outside the window"; fi ;;
    esac
    ;;
  hwcheck)    # prove the hardware is real (hwcheck.py, ~15 s, uses the GPU briefly)
    if dev_paused; then echo "Skipped: job paused (owner using the PC)."; exit 1; fi
    compose up -d dev >/dev/null 2>&1
    out=$(compose exec -T dev python3 - < "$REPO/processingoffloadPC/hwcheck.py" 2>&1 | tail -n 1)
    if echo "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
      echo "$out" > "$AGENT/hwcheck.json"
      echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["summary"])'
    else
      echo "Hardware check failed to run: $out"; exit 1
    fi
    ;;
  link)       # link host1,host2 | none : connect this powerplant's ROS router to other powerplants' routers
    f="$AGENT/cluster.env"
    if [ -z "$ARG1" ] || [ "$ARG1" = none ]; then : > "$f"; echo "unlinked";
    else
      eps=$(echo "$ARG1" | tr ',' '\n' | grep -v "^$(powerplant_name)$" | grep -v '^$' | sed 's/.*/"tcp\/&:7447"/' | paste -sd, -)
      if [ -n "$eps" ]; then echo "ZENOH_CONFIG_OVERRIDE=connect/endpoints=[$eps]" > "$f"; else : > "$f"; fi
      echo "linked to: ${eps:-nobody}"
    fi
    compose up -d --force-recreate zenoh >/dev/null 2>&1 && echo "ROS router restarted"
    ;;
  *)
    echo "Usage: power.sh status|specs|start|processes|sleep|sleep-until HH:MM|sleep-after-finish [HH:MM|status|cancel]|off|restart|cancel|mac|resume|guardian [on|off|status]|notify-info|notify-test|wake-topic|wake-info|capacity|run-job NAME B64CMD|jobs|stop-jobs [NAME|all]|job-log NAME|link PEERS|none [--force]"
    exit 1
    ;;
esac

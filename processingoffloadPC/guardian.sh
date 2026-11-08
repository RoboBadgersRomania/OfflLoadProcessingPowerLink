#!/usr/bin/env bash
# Guardian (systemd service "offload-guardian" on the processing offload PC).
# If the PC owner starts using keyboard/mouse while your job runs, it PAUSES the whole ROS dev
# container (docker pause = frozen, nothing lost) and notifies you. When nobody has touched the PC
# for RESUME_AFTER_IDLE seconds, it resumes the job and notifies you again.
# Settings: ~/.offload-agent/guardian.conf   Log: ~/.offload-agent/guardian.log
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

log() {
  echo "$(date '+%a %d %b %H:%M:%S')  $*" >> "$AGENT/guardian.log"
  if [ "$(wc -l < "$AGENT/guardian.log")" -gt 500 ]; then
    tail -n 300 "$AGENT/guardian.log" > "$AGENT/guardian.log.tmp" && mv "$AGENT/guardian.log.tmp" "$AGENT/guardian.log"
  fi
}

# Is your work actually running? (GPU busy, or the dev container using CPU)
job_running() {
  local gu cpu id
  gu=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9')
  [ -n "$gu" ] && [ "$gu" -ge 10 ] && return 0
  id=$(dev_id); [ -z "$id" ] && return 1
  cpu=$(docker_c stats --no-stream --format '{{.CPUPerc}}' "$id" | cut -d. -f1 | tr -dc '0-9')
  [ -n "$cpu" ] && [ "$cpu" -ge 20 ]
}

mkdir -p "$AGENT"
log "guardian started"
last_sched_check=0
last_hw_check=0
while true; do
  # --- Schedule: outside the availability window, sleep once nobody uses the PC (30 min) and no work runs.
  now=$(date +%s)
  if [ $((now - last_sched_check)) -ge 300 ]; then
    last_sched_check=$now
    load_conf
    idle_s=$(win_idle || echo 0)
    if [ -n "${SCHEDULE:-}" ] && [ "${AUTO_SLEEP_OUTSIDE:-1}" = 1 ] && [ "$(pc_role)" != nodeuser ] && ! in_schedule \
       && [ "${idle_s:-0}" -ge 1800 ] && bash "$(dirname "${BASH_SOURCE[0]}")/power.sh" processes >/dev/null 2>&1; then
      log "outside schedule and idle - going to sleep"
      notify "$(powerplant_name) is going to sleep" "Outside its availability schedule and nobody is using it." "zzz"
      agent sleep >/dev/null
    fi
  fi
  # --- Hardware check once a day, only when the owner is away (30 min) and no job runs
  if [ $((now - last_hw_check)) -ge 3600 ]; then
    last_hw_check=$now
    hw_time=$(python3 -c "import json;print(json.load(open('$AGENT/hwcheck.json'))['time'])" 2>/dev/null || echo 0)
    idle_s=$(win_idle || echo 0)
    if [ $((now - hw_time)) -ge 86400 ] && [ "${idle_s:-0}" -ge 1800 ] && [ "$(pc_role)" != nodeuser ] && ! job_running && ! dev_paused; then
      log "daily hardware check: $(bash "$(dirname "${BASH_SOURCE[0]}")/power.sh" hwcheck 2>&1 | tail -n 1)"
    fi
  fi

  load_conf
  idle=$(win_idle || true)
  now=$(date +%s)
  if [ "${ENABLED:-1}" = 1 ] && [ -n "$idle" ]; then
    name=$(powerplant_name)
    resume_min=$(( ${RESUME_AFTER_IDLE:-600} / 60 ))
    if [ -f "$STATE" ]; then
      if ! dev_paused; then
        rm -f "$STATE"; log "job was resumed by hand"
      elif [ "${AUTO_RESUME:-1}" = 1 ] && [ "$idle" -ge "${RESUME_AFTER_IDLE:-600}" ]; then
        if docker_c unpause "$(dev_id)" >/dev/null; then
          rm -f "$STATE"
          log "RESUMED - owner idle $((idle / 60)) min"
          notify "Job resumed on $name" "Nobody has used $name for $((idle / 60)) min, so your job is running again." "arrow_forward"
        fi
      fi
    else
      until_ts=$(cat "$OVERRIDE" 2>/dev/null || echo 0)
      [[ "$until_ts" =~ ^[0-9]+$ ]] || until_ts=0
      if [ "$idle" -lt "${ACTIVE_SECONDS:-60}" ] && [ "$now" -ge "$until_ts" ] && ! dev_paused && job_running; then
        if docker_c pause "$(dev_id)" >/dev/null; then
          echo "$now" > "$STATE"
          log "PAUSED - owner started using the PC"
          notify "Job paused on $name" "Someone started using $name, so your job is paused (nothing is lost). It resumes after $resume_min min without keyboard/mouse use. Force it: offloadpc-resume" "pause_button"
        fi
      fi
    fi
  fi
  sleep 10
done

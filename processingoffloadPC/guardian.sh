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
while true; do
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

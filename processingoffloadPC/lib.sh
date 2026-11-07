# Shared helpers for power.sh and guardian.sh (sourced, not run).
# Ubuntu never calls Windows directly: it talks to the Windows agent (agent.ps1) through files in
# ~/.offload-agent/  (cmd -> result, plus idle / heartbeat / mac / specs written by the agent).

export PATH="$PATH:/usr/lib/wsl/lib"          # nvidia-smi lives here
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$HOME/.offload-agent"
CONF="$AGENT/guardian.conf"
STATE="$AGENT/guardian-state"                 # exists while the guardian has paused your job
OVERRIDE="$AGENT/guardian-override"           # unix time until which the guardian won't pause

load_conf() { [ -f "$CONF" ] && . "$CONF"; }

docker_c() { docker "$@" 2>/dev/null || sudo -n docker "$@" 2>/dev/null; }
compose()  { (cd "$REPO/docker" && docker_c compose "$@"); }
dev_id()   { compose ps -q dev 2>/dev/null | head -1; }
dev_paused() {
  local id; id=$(dev_id)
  [ -n "$id" ] && [ "$(docker_c inspect -f '{{.State.Paused}}' "$id")" = "true" ]
}

agent_alive() {
  local hb; hb=$(cat "$AGENT/heartbeat" 2>/dev/null)
  [[ "$hb" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - hb )) -lt 20 ]
}
win_idle() { local v; v=$(cat "$AGENT/idle" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; }

# agent REQUEST - send one request from the fixed list to the Windows agent, print its answer.
agent() {
  if ! agent_alive; then
    echo "ERROR: the Windows agent isn't running (is someone logged in to Windows? else rerun SETUP-processingoffloadPC.cmd)"
    return 1
  fi
  rm -f "$AGENT/result"
  printf '%s' "$*" > "$AGENT/cmd.tmp" && mv -f "$AGENT/cmd.tmp" "$AGENT/cmd"
  local _
  for _ in $(seq 1 30); do
    if [ -f "$AGENT/result" ]; then cat "$AGENT/result"; echo; rm -f "$AGENT/result"; return 0; fi
    sleep 0.5
  done
  echo "ERROR: no answer from the Windows agent."
  return 1
}

# notify TITLE MESSAGE [TAGS] - phone/desktop push via ntfy (topic in guardian.conf; empty = off)
notify() {
  load_conf
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -H "Tags: ${3:-robot}" -d "$2" \
    "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

powerplant_name() { load_conf; echo "${POWERPLANT_NAME:-$(hostname)}"; }

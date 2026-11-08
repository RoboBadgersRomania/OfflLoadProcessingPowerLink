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

# conf_set KEY VALUE - set one setting in guardian.conf (quoted safely, keeps the other lines)
conf_set() {
  KEY="$1" VAL="$2" CONFF="$CONF" python3 - <<'EOF'
import os, re, shlex
k, v, p = os.environ['KEY'], os.environ['VAL'], os.environ['CONFF']
lines = open(p).read().splitlines() if os.path.exists(p) else []
new = f'{k}={shlex.quote(v)}'
for i, l in enumerate(lines):
    if re.match(rf'^{k}=', l):
        lines[i] = new
        break
else:
    lines.append(new)
open(p, 'w').write('\n'.join(lines) + '\n')
EOF
}

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

# Role of this PC (switched in the app): nodeuser = not shared | both | processing
pc_role() { load_conf; echo "${ROLE:-both}"; }

# in_schedule: true if NOW is inside SCHEDULE (guardian.conf), e.g.
#   SCHEDULE="Mon-Fri 22:00-08:00; Sat-Sun 00:00-24:00"     (empty = always available)
# A window that ends before it starts runs past midnight into the next day.
in_schedule() {
  load_conf
  [ -z "${SCHEDULE:-}" ] && return 0
  SCHED="$SCHEDULE" python3 - <<'EOF'
import datetime, os, re, sys
DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']
def days(spec):
    out = set()
    for part in spec.lower().split(','):
        part = part.strip()
        if '-' in part:
            a, b = (DAYS.index(x.strip()[:3]) for x in part.split('-'))
            k = a
            while True:
                out.add(k)
                if k == b: break
                k = (k + 1) % 7
        elif part:
            out.add(DAYS.index(part[:3]))
    return out
now = datetime.datetime.now()
wd, m = now.weekday(), now.hour * 60 + now.minute
for rule in os.environ['SCHED'].split(';'):
    r = re.match(r'\s*([A-Za-z,\- ]+?)\s+(\d{1,2}):(\d\d)\s*-\s*(\d{1,2}):(\d\d)\s*$', rule)
    if not r:
        continue
    d = days(r.group(1))
    s, e = int(r.group(2)) * 60 + int(r.group(3)), int(r.group(4)) * 60 + int(r.group(5))
    if s < e and wd in d and s <= m < e:
        sys.exit(0)
    if s >= e and ((wd in d and m >= s) or ((wd - 1) % 7 in d and m < e)):
        sys.exit(0)
sys.exit(1)
EOF
}
available() { [ "$(pc_role)" != nodeuser ] && in_schedule; }

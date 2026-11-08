#!/usr/bin/env bash
# Run INSIDE Ubuntu 24.04 (WSL) on YOUR laptop / desktop:
#   bash your-pc/setup-ros-client.sh
# Installs ROS 2 Jazzy + Gazebo + Zenoh and connects it to the processing offload PC (processingoffloadpc).
set -euo pipefail

if ! grep -qi microsoft /proc/version; then echo "Not running in WSL - stop."; exit 1; fi
. /etc/os-release
if [ "$VERSION_CODENAME" != "noble" ]; then echo "Needs Ubuntu 24.04 (noble), found $VERSION_CODENAME."; exit 1; fi

echo "== 1. ROS 2 apt repository =="
sudo apt-get update
sudo apt-get install -y software-properties-common curl
sudo add-apt-repository -y universe
# Only the first time: once installed, apt keeps ros2-apt-source updated from packages.ros.org (no GitHub).
if ! dpkg -s ros2-apt-source >/dev/null 2>&1; then
  # --retry: GitHub sometimes answers 503/504 for a while; curl waits and tries again.
  ROS_APT_SOURCE_VERSION=$(curl -fsSL --retry 5 --retry-delay 20 https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
    | grep -F '"tag_name"' | awk -F'"' '{print $4}') \
    || { echo "GitHub isn't answering right now (see githubstatus.com). Run the SETUP file again later."; exit 1; }
  curl -fsSL --retry 5 --retry-delay 20 -o /tmp/ros2-apt-source.deb \
    "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${VERSION_CODENAME}_all.deb"
  sudo dpkg -i /tmp/ros2-apt-source.deb
fi

echo "== 2. ROS 2 Jazzy desktop + Gazebo + Zenoh (~3 GB) =="
sudo apt-get update
sudo apt-get install -y \
  ros-jazzy-desktop ros-jazzy-ros-gz ros-jazzy-rmw-zenoh-cpp \
  ros-jazzy-image-transport-plugins \
  python3-colcon-common-extensions git tmux

echo "== 3. Connect to the offload PC on every new terminal =="
# Rewrite our block on every run (so updates apply), keeping a customised OFFLOAD_USER.
old_user=$(grep -oP '^export OFFLOAD_USER="\K[^"$][^"]*' ~/.bashrc 2>/dev/null | tail -1 || true)
sed -i '/# >>> ros2-remote >>>/,/# <<< ros2-remote <<</d' ~/.bashrc
cat >> ~/.bashrc <<'EOF'
# >>> ros2-remote >>>
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
# Your Ubuntu username ON THE nuclear powerplants (change if it differs from this PC's).
export OFFLOAD_USER="$USER"

# --- Which nuclear powerplant (offload PC) to use: list-powerplants / use-powerplant NAME ---
export OFFLOAD_HOST="$(cat ~/.offloadpc-target 2>/dev/null || echo processingoffloadpc)"
_offload_zenoh() {
  if [ "$OFFLOAD_HOST" = local ]; then unset ZENOH_CONFIG_OVERRIDE
  else export ZENOH_CONFIG_OVERRIDE="connect/endpoints=[\"tcp/$OFFLOAD_HOST:7447\"];mode=\"client\""; fi
}
_offload_zenoh
offloadpc-online() { [ "$OFFLOAD_HOST" != local ] && timeout 4 bash -c "</dev/tcp/${1:-$OFFLOAD_HOST}/22" 2>/dev/null; }
_offload_names() {   # powerplants known to Tailscale (Windows) + ones you used before
  { local ts
    for ts in "$(command -v tailscale.exe)" "/mnt/c/Program Files/Tailscale/tailscale.exe" /mnt/?/Programs/Tailscale/tailscale.exe; do [ -x "$ts" ] && break; done
    [ -x "$ts" ] && "$ts" status 2>/dev/null | tr -d '\r' | awk '{print $2}' | grep '^processingoffloadpc'
    cat ~/.offloadpc-known 2>/dev/null; echo "$OFFLOAD_HOST"; } | grep -v '^local$' | grep -v '^$' | sort -u
}
_green=$'\e[32m●\e[0m'
_red=$'\e[31m●\e[0m'
list-powerplants() {
  local n specs dot
  echo "Nuclear powerplants (current: $OFFLOAD_HOST):"
  for n in $(_offload_names); do
    if offloadpc-online "$n"; then
      dot="$_green"
      specs=$(timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 "$OFFLOAD_USER@$n" \
              "cat ~/.offload-agent/specs 2>/dev/null" 2>/dev/null | tr -d '\r')
      [ -n "$specs" ] && echo "$specs" > ~/.offloadpc-specs-"$n"
    else
      dot="$_red"; specs="$(cat ~/.offloadpc-specs-"$n" 2>/dev/null) (offline)"
    fi
    printf '  %s %-30s %s%s\n' "$dot" "$n" "${specs:-?}" "$([ "$n" = "$OFFLOAD_HOST" ] && echo '   <- current')"
  done
  echo "Switch: use-powerplant NAME   (e.g. use-powerplant 4090, use-powerplant local)"
}
use-powerplant() {
  local n="${1:-}"
  if [ -z "$n" ]; then list-powerplants; return; fi
  case "$n" in local|processingoffloadpc*) ;; *) n="processingoffloadpc-$n" ;; esac
  echo "$n" > ~/.offloadpc-target; export OFFLOAD_HOST="$n"; _offload_zenoh
  if [ "$n" != local ] && ! grep -qx "$n" ~/.offloadpc-known 2>/dev/null; then echo "$n" >> ~/.offloadpc-known; fi
  if [ "$n" = local ]; then echo "Using this PC only. Start a local ROS router once:  ros2 run rmw_zenoh_cpp rmw_zenohd"
  elif offloadpc-online; then echo "Now using $_green $n"; else echo "Now using $_red $n (offline right now)"; fi
  echo "(ROS nodes already running keep their old connection - restart them. Other terminals: run 'use-powerplant $n' or open a new one.)"
}

alias offloadpc='ssh -t "$OFFLOAD_USER@$OFFLOAD_HOST" "cd ~/ros2-remote/docker && docker compose exec dev bash"'
offloadpc-power() { ssh -t "$OFFLOAD_USER@$OFFLOAD_HOST" "bash ~/ros2-remote/processingoffloadPC/power.sh $*"; }
offloadpc-exec()  { ssh -o ConnectTimeout=8 "$OFFLOAD_USER@$OFFLOAD_HOST" "bash ~/ros2-remote/processingoffloadPC/power.sh $*"; }

start-nuclear-powerplant() {
  echo "Starting nuclear powerplant: $OFFLOAD_HOST"
  if ! offloadpc-online; then
    if _offload_relay >/dev/null; then wake-nuclear-powerplant || return 1; echo "Giving Ubuntu + Docker 20 s to start..."; sleep 20
    else
      echo "It's offline (asleep or off). Wake it with Wake-on-LAN from its home network,"
      echo "set up a wake relay (README > Wake over the internet: set-wake-relay), or next time"
      echo "use  sleep-nuclear-powerplant HH:MM  (it wakes itself at HH:MM)."
      return 1
    fi
  fi
  offloadpc-exec mac > ~/.offloadpc-mac-"$OFFLOAD_HOST" 2>/dev/null
  offloadpc-power start && offloadpc
}
# sleep-nuclear-powerplant [HH:MM] [--after-finish] [--force]
#   (nothing)        sleep now (asks first if it's busy)
#   22:30            sleep now, wake up at 22:30
#   --after-finish   sleep automatically once the running work is done (add 22:30 to wake then too;
#                    "--after-finish status" / "--after-finish cancel" to check or stop it)
sleep-nuclear-powerplant() {
  local after=0 t="" extra=()
  for a in "$@"; do
    case "$a" in
      --after-finish|--when-done|-a) after=1 ;;
      --force) extra+=(--force) ;;
      *) t="$a" ;;
    esac
  done
  if [ "$after" = 1 ]; then offloadpc-power sleep-after-finish $t
  elif [ -n "$t" ]; then offloadpc-power sleep-until "$t" "${extra[@]}"
  else offloadpc-power sleep "${extra[@]}"; fi
}
sleep-after-finish() { sleep-nuclear-powerplant --after-finish "$@"; }
show-running-processes() { offloadpc-power processes; }
offloadpc-mac() { offloadpc-exec mac | tee ~/.offloadpc-mac-"$OFFLOAD_HOST"; }
offloadpc-resume() { offloadpc-power resume; }
offloadpc-guardian() { offloadpc-power guardian "${1:-status}"; }
offloadpc-notifications() { if [ "${1:-}" = test ]; then offloadpc-power notify-test; else offloadpc-power notify-info; fi; }
alias offloadpc-status='offloadpc-power status'
alias offloadpc-off='offloadpc-power off'
alias offloadpc-restart='offloadpc-power restart'
alias offloadpc-cancel='offloadpc-power cancel'

# --- Wake over the internet: a "wake relay" = any always-on Tailscale device on the powerplant's
#     home network (Raspberry Pi, old laptop...). It sends the Wake-on-LAN packet for you.
_offload_relay() { local r; r=$(awk -v h="$OFFLOAD_HOST" '$1==h{print $2}' ~/.offloadpc-wake 2>/dev/null | tail -1); [ -n "$r" ] && echo "$r"; }
set-wake-relay() {
  if [ -z "${1:-}" ]; then echo "Usage: set-wake-relay user@device   (a Tailscale device on $OFFLOAD_HOST's home network)"; return 1; fi
  { grep -v "^$OFFLOAD_HOST " ~/.offloadpc-wake 2>/dev/null; echo "$OFFLOAD_HOST $1"; } > ~/.offloadpc-wake.tmp && mv ~/.offloadpc-wake.tmp ~/.offloadpc-wake
  echo "Wake relay for $OFFLOAD_HOST: $1"
}
_WOL_PY='import socket,sys;m=bytes.fromhex(sys.argv[1].replace(":","").replace("-",""));s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);[s.sendto(b"\xff"*6+m*16,("255.255.255.255",p)) for p in (7,9)]'
wake-nuclear-powerplant() {
  local relay mac i
  relay=$(_offload_relay) || { echo "No wake relay for $OFFLOAD_HOST yet: set-wake-relay user@device (see README)"; return 1; }
  mac=$(grep -oiE '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}' ~/.offloadpc-mac-"$OFFLOAD_HOST" 2>/dev/null | head -1)
  if [ -z "$mac" ]; then echo "MAC address unknown - run offloadpc-mac once while $OFFLOAD_HOST is on."; return 1; fi
  echo "Waking $OFFLOAD_HOST ($mac) via $relay ..."
  ssh -o ConnectTimeout=8 "$relay" "python3 -c '$_WOL_PY' $mac" || { echo "Couldn't reach the relay $relay."; return 1; }
  echo -n "Waiting for it to come online"
  for i in $(seq 1 36); do
    if offloadpc-online; then echo " - $_green online!"; return 0; fi
    echo -n .; sleep 5
  done
  echo " - $_red not online after 3 min (Wake-on-LAN enabled in its BIOS? wired network?)"; return 1
}
# <<< ros2-remote <<<
EOF
if [ -n "$old_user" ]; then sed -i "s/^export OFFLOAD_USER=\"\$USER\"/export OFFLOAD_USER=\"$old_user\"/" ~/.bashrc; fi

echo "== 4. Check connection =="
if getent hosts processingoffloadpc >/dev/null; then
  echo "OK: processingoffloadpc found via Tailscale."
else
  echo "NOTE: processingoffloadpc not found yet (fine if your powerplant has another name or is set up later)."
fi

echo
echo "Done. Open a NEW Ubuntu terminal, then test:"
echo "  ros2 topic list            # should include topics from the offload PC"
echo "  offloadpc                  # shell inside the dev container on the offload PC"
echo "  start-nuclear-powerplant   # start ROS on the offload PC + open a shell there"
echo "  show-running-processes     # what's running? safe to power off?"
echo "  sleep-nuclear-powerplant   # put it to sleep (add 22:30 to wake it at 22:30)"
echo "  sleep-nuclear-powerplant --after-finish   # sleep automatically when your work is done"
echo "  list-powerplants / use-powerplant NAME     # choose which PC does the heavy work"

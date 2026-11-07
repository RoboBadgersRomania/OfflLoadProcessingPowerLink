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
ROS_APT_SOURCE_VERSION=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
  | grep -F '"tag_name"' | awk -F'"' '{print $4}')
curl -fsSL -o /tmp/ros2-apt-source.deb \
  "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${VERSION_CODENAME}_all.deb"
sudo dpkg -i /tmp/ros2-apt-source.deb

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
# Use the Zenoh router on the processing offload PC (via Tailscale). Comment out to work offline.
export ZENOH_CONFIG_OVERRIDE='connect/endpoints=["tcp/processingoffloadpc:7447"];mode="client"'
# Your Ubuntu username ON THE offload PC (change if it differs from this PC's).
export OFFLOAD_USER="$USER"
alias offloadpc='ssh -t "$OFFLOAD_USER@processingoffloadpc" "cd ~/ros2-remote/docker && docker compose exec dev bash"'
# Remote power control (see processingoffloadPC/power.sh)
offloadpc-power() { ssh -t "$OFFLOAD_USER@processingoffloadpc" "bash ~/ros2-remote/processingoffloadPC/power.sh $*"; }
alias offloadpc-status='offloadpc-power status'
alias offloadpc-sleep='offloadpc-power sleep'
alias offloadpc-sleep-until='offloadpc-power sleep-until'
alias offloadpc-off='offloadpc-power off'
alias offloadpc-restart='offloadpc-power restart'
alias offloadpc-cancel='offloadpc-power cancel'
alias offloadpc-mac='offloadpc-power mac'
# <<< ros2-remote <<<
EOF
if [ -n "$old_user" ]; then sed -i "s/^export OFFLOAD_USER=\"\$USER\"/export OFFLOAD_USER=\"$old_user\"/" ~/.bashrc; fi

echo "== 4. Check connection =="
if getent hosts processingoffloadpc >/dev/null; then
  echo "OK: processingoffloadpc found via Tailscale."
else
  echo "WARNING: processingoffloadpc not reachable. Is Tailscale signed in on Windows, and is the offload PC on?"
fi

echo
echo "Done. Open a NEW Ubuntu terminal, then test:"
echo "  ros2 topic list            # should include topics from the offload PC"
echo "  offloadpc                  # shell inside the dev container on the offload PC"
echo "  offloadpc-status           # is it on? GPU load"
echo "  offloadpc-sleep            # put it to sleep (offloadpc-sleep-until 22:30 = sleep + auto-wake)"

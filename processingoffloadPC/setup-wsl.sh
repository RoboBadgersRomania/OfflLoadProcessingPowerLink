#!/usr/bin/env bash
# Run INSIDE Ubuntu 24.04 (WSL) on a processing offload PC ("nuclear powerplant").
# setup.ps1 runs it for you. By hand:
#   POWERPLANT_NAME=processingoffloadpc PRIVACY=1 GUARDIAN=1 bash processingoffloadPC/setup-wsl.sh
#     POWERPLANT_NAME  its name on your Tailscale network (must start with processingoffloadpc)
#     PRIVACY=1        someone else's PC: Ubuntu can't read Windows files or run Windows programs
#     GUARDIAN=1       pause your jobs while the PC owner uses the PC (and notify you)
# Installs: Docker Engine, NVIDIA Container Toolkit, Tailscale (with SSH), guardian service.
set -euo pipefail
export PATH="$PATH:/usr/lib/wsl/lib"
POWERPLANT_NAME="${POWERPLANT_NAME:-processingoffloadpc}"
PRIVACY="${PRIVACY:-1}"
GUARDIAN="${GUARDIAN:-$PRIVACY}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 0. Checks + WSL settings =="
if ! grep -qi microsoft /proc/version; then echo "Not running in WSL - stop."; exit 1; fi
if ! command -v nvidia-smi >/dev/null; then
  echo "nvidia-smi not found. Install/update the NVIDIA driver on WINDOWS (not in WSL), then rerun."; exit 1
fi
# /etc/wsl.conf: systemd on; privacy mode = no Windows drives, no running Windows programs.
# Edits only these keys and keeps everything else (e.g. the default user).
sudo PRIVACY="$PRIVACY" python3 - <<'EOF'
import configparser, os
p = '/etc/wsl.conf'
c = configparser.ConfigParser(); c.optionxform = str; c.read(p)
def put(s, k, v):
    if not c.has_section(s): c.add_section(s)
    c.set(s, k, v)
def drop(s, k):
    if c.has_section(s): c.remove_option(s, k)
put('boot', 'systemd', 'true')
if os.environ['PRIVACY'] == '1':
    put('automount', 'enabled', 'false')
    put('automount', 'mountFsTab', 'false')
    put('interop', 'enabled', 'false')
    put('interop', 'appendWindowsPath', 'false')
else:
    for s, k in [('automount', 'enabled'), ('automount', 'mountFsTab'), ('interop', 'enabled'), ('interop', 'appendWindowsPath')]:
        drop(s, k)
with open(p, 'w') as f: c.write(f)
EOF
echo "Privacy mode: $([ "$PRIVACY" = 1 ] && echo 'ON (applies after WSL restarts)' || echo OFF)"
if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  echo "systemd was off - it is now enabled. Restart WSL (wsl --shutdown) and run this again."
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv

echo "== 1. Docker Engine =="
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg tmux rsync
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"

echo "== 2. NVIDIA Container Toolkit (GPU inside Docker) =="
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

echo "== 3. GPU test inside a container =="
sudo docker run --rm --gpus all ubuntu:24.04 nvidia-smi

echo "== 4. Tailscale as '$POWERPLANT_NAME' (only this Ubuntu joins - not the Windows PC) =="
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
if sudo tailscale status >/dev/null 2>&1; then
  sudo tailscale set --ssh --hostname="$POWERPLANT_NAME"
else
  echo ">> A login link will appear. Open it and sign in with YOUR Tailscale account."
  sudo tailscale up --ssh --hostname="$POWERPLANT_NAME"
fi

echo "== 5. Agent folder, guardian + notifications =="
AGENT="$HOME/.offload-agent"
mkdir -p "$AGENT"; chmod 777 "$AGENT"
CONF="$AGENT/guardian.conf"
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<EOF
# Guardian + notification settings for this nuclear powerplant (edit freely; read every 10 s)
POWERPLANT_NAME=$POWERPLANT_NAME
ENABLED=$GUARDIAN            # 1 = pause your job while the PC owner uses the PC
ACTIVE_SECONDS=60            # keyboard/mouse used within this many seconds = owner is active
RESUME_AFTER_IDLE=600        # resume after nobody used the PC for this many seconds
AUTO_RESUME=1                # 0 = stay paused until you run offloadpc-resume
NTFY_TOPIC=badger-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')   # push notifications (ntfy.sh); empty = off
NTFY_SERVER=https://ntfy.sh
EOF
else
  sed -i "s/^POWERPLANT_NAME=.*/POWERPLANT_NAME=$POWERPLANT_NAME/; s/^ENABLED=[01]/ENABLED=$GUARDIAN/" "$CONF"
fi
# Private topic a wake listener on this PC's home network listens to (wake from any network)
grep -q '^WAKE_TOPIC=' "$CONF" || \
  echo "WAKE_TOPIC=badger-wake-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')   # see wake-listener/" >> "$CONF"
sudo tee /etc/systemd/system/offload-guardian.service >/dev/null <<EOF
[Unit]
Description=OffloadPC guardian (pause jobs while the PC owner uses the PC)
After=docker.service
[Service]
User=$USER
ExecStart=/bin/bash $HERE/guardian.sh
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now offload-guardian.service
. "$CONF"

echo
echo "Done: '$POWERPLANT_NAME' ($(tailscale ip -4 2>/dev/null | head -1))"
echo "Phone notifications (job paused/resumed): install the 'ntfy' app and subscribe to:  $NTFY_TOPIC"
echo "Wake from any network: run a wake listener on this home network with topic:  ${WAKE_TOPIC%% *}"

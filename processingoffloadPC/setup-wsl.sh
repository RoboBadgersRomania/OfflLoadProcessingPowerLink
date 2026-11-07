#!/usr/bin/env bash
# Run INSIDE Ubuntu 24.04 (WSL) on the processing offload PC:
#   bash processingoffloadPC/setup-wsl.sh
# Installs: Docker Engine, NVIDIA Container Toolkit, Tailscale (with SSH).
set -euo pipefail

echo "== 0. Checks =="
if ! grep -qi microsoft /proc/version; then echo "Not running in WSL - stop."; exit 1; fi
if ! command -v nvidia-smi >/dev/null; then
  echo "nvidia-smi not found. Install/update the NVIDIA driver on WINDOWS (not in WSL), then rerun."; exit 1
fi
if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
  echo "systemd is off. Enabling it - run 'wsl --shutdown' in PowerShell, reopen Ubuntu, rerun this script."
  printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total --format=csv

echo "== 1. Docker Engine =="
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
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

echo "== 4. Tailscale (remote access, only this WSL instance joins - not the Windows PC) =="
curl -fsSL https://tailscale.com/install.sh | sh
echo ">> A login link will appear. Open it and sign in with YOUR Tailscale account."
sudo tailscale up --ssh --hostname=processingoffloadpc

echo
echo "Done. Tailscale IP: $(tailscale ip -4)"
echo "Close this terminal and reopen Ubuntu (so the docker group applies), then:"
echo "  cd ~/ros2-remote/docker && docker compose up -d --build"

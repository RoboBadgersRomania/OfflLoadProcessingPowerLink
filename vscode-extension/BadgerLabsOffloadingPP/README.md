# BadgerLabsOffloadingPP

VS Code extension for **[OffLoad Processing Power Link](https://github.com/RoboBadgersRomania/OfflLoadProcessingPowerLink)**:
use a remote GPU PC (the *processing offload PC*) for heavy ROS 2 work, straight from VS Code.

## Features

- **Status bar**: `Offload: GPU 12%` / `Offload: offline`, auto-refreshing. Click it for all actions.
- **Start nuclear powerplant**: makes sure ROS is running on the offload PC and opens a ROS shell there.
- **Show running processes**: GPU/CPU load, someone using the PC?, containers, top processes,
  ROS nodes, tmux jobs, and a verdict: *IDLE, safe to power off* or *BUSY*.
- **Sleep nuclear powerplant** (optionally *and wake at HH:MM*): checks it's idle first, asks if busy.
- **Sleep nuclear powerplant after work finishes**: sleeps by itself once idle 5 min in a row
  (optional wake time; status; cancel).
- **Open offload PC workspace**: new VS Code window on the offload PC via Remote-SSH.
- **ROS shell on offload PC**: terminal inside the GPU ROS container.
- **ROS shell on this PC**: Ubuntu (WSL) terminal for Gazebo / RViz / light nodes.
- **Build workspace on offload PC**: `colcon build --symlink-install` in the container.
- **Foxglove**: opens the viewer connected to `ws://processingoffloadpc:8765`.
- **Power**: restart, shut down (busy check + confirmation), cancel, show MAC for Wake-on-LAN.

All commands are in the Command Palette (`Ctrl+Shift+P`) under **BadgerLabs:**.

## Requirements

- The repo's `SETUP-processingoffloadPC.cmd` (offload PC) and `SETUP-my-PC.cmd` (this PC) have run.
- Tailscale signed in on this PC with the same account.
- Optional: **Remote - SSH** extension for "Open offload PC workspace".

## Settings

| Setting | Default | |
|---|---|---|
| `badgerlabs.host` | `processingoffloadpc` | Tailscale name of the offload PC |
| `badgerlabs.remoteUser` | *(asked once)* | Your Ubuntu username on the offload PC |
| `badgerlabs.remoteRepoPath` | `~/ros2-remote` | Repo location inside Ubuntu on the offload PC |
| `badgerlabs.wslDistro` | `Ubuntu-24.04` | Local WSL distro for "ROS shell on this PC" |
| `badgerlabs.statusIntervalSeconds` | `60` | Status refresh interval (0 = manual) |

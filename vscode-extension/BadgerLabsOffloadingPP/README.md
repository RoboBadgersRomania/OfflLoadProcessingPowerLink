# BadgerLabsOffloadingPP

VS Code extension for **[OffLoad Processing Power Link](https://github.com/RoboBadgersRomania/OfflLoadProcessingPowerLink)**:
use remote GPU PCs (*nuclear powerplants*) for heavy ROS 2 work, straight from VS Code.

## Features

- **Status bar**: `🟢 RTX 4090 · 12%` (reachable, GPU load), `🟡 RTX 4090 · paused` (owner using it),
  `🔴 GTX 1080` (offline). Click it for all actions.
- **Choose nuclear powerplant**: like picking an AI model, every PC listed by its specs
  (e.g. `🟢 GTX 1080 · i7-9700K · 16 GB DDR4 3333MHz`) with a live green/red reachability dot.
- **Start nuclear powerplant**: wakes it via a wake relay if needed, starts ROS, opens a ROS shell.
  Warns if someone used that PC in the last 10 minutes.
- **Show running processes**: GPU/CPU load, owner at the keyboard?, containers, top processes,
  ROS nodes, tmux jobs, and a verdict: *IDLE, safe to power off* or *BUSY*.
- **Sleep nuclear powerplant** (now / *and wake at HH:MM* / *after work finishes*): checks it's idle first.
- **Guardian**: if the PC's owner starts using it while your job runs, the job is paused and you get
  a VS Code warning (and a phone notification); it resumes when they leave. **Resume paused job** forces it.
- **Wake nuclear powerplant**: Wake-on-LAN through an always-on device on its network.
- **Open powerplant workspace** (Remote-SSH), **ROS shells**, **colcon build**, **Foxglove**, restart / shut down.

All commands are in the Command Palette (`Ctrl+Shift+P`) under **BadgerLabs:**.

## Requirements

- The repo's `SETUP-processingoffloadPC.cmd` (each powerplant) and `SETUP-my-PC.cmd` (this PC) have run.
- Tailscale signed in on this PC with the same account.
- Optional: **Remote - SSH** extension for "Open powerplant workspace".

## Settings

| Setting | Default | |
|---|---|---|
| `badgerlabs.host` | `processingoffloadpc` | Powerplant in use (set by *Choose nuclear powerplant*) |
| `badgerlabs.remoteUser` | *(asked once)* | Your Ubuntu username on the powerplants |
| `badgerlabs.remoteRepoPath` | `~/ros2-remote` | Repo location inside Ubuntu on the powerplants |
| `badgerlabs.wslDistro` | `Ubuntu-24.04` | Local WSL distro for "ROS shell on this PC" |
| `badgerlabs.statusIntervalSeconds` | `60` | Status refresh interval (0 = manual) |
| `badgerlabs.wakeRelays` | `{}` | Wake relay per powerplant, e.g. `{"processingoffloadpc": "pi@wakepi"}` |

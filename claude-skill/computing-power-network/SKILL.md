---
name: computing-power-network
description: Operate and troubleshoot the Computing Power Network (BadgerLabs "nuclear powerplants") - remote Windows GPU PCs running ROS 2 Jazzy in WSL/Docker over Tailscale. Use when the user asks to start, sleep, wake, check, update or distribute work over their powerplants / offload PCs, see running processes, fix SSH/Tailscale/agent/guardian/wake problems, or edit jobs.yaml.
---

# Computing Power Network (BadgerLabs nuclear powerplants)

Repo: https://github.com/RoboBadgersRomania/PowerCluster (README has everything).
Skill version: 1.1.0. If `https://raw.githubusercontent.com/RoboBadgersRomania/PowerCluster/main/claude-skill/computing-power-network/SKILL.md`
shows a newer version, offer to replace this file with it (the dashboard's "Update kit" does that too).

## Architecture (what runs where)

- **User's PC / laptop (Windows)**: WSL Ubuntu 24.04 + ROS 2 Jazzy (`rmw_zenoh_cpp`), Tailscale for Windows,
  shell shortcuts in `~/.bashrc` (block `# >>> ros2-remote >>>`), VS Code extension *BadgerLabsOffloadingPP*,
  pygame dashboard (`dashboard/launcher.py`). Kit copy: `~/ros2-remote` inside Ubuntu.
- **Powerplant (Windows, NVIDIA GPU)**: WSL Ubuntu with Tailscale **inside** Ubuntu (name `processingoffloadpc[-x]`,
  Tailscale SSH), Docker (`zenoh` router :7447, `foxglove` :8765, `dev` container with GPU), `offload-guardian`
  systemd service, hidden Windows agent (`%LOCALAPPDATA%\OffloadPC\agent.ps1`, task "OffloadPC agent").
- **Privacy mode** (someone else's PC): Ubuntu has no Windows drives and no interop. Windows is reached only via
  the agent through files in `~/.offload-agent/` (`cmd`/`result`, `idle`, `heartbeat`, `mac`, `specs`).
  Allowed requests: ping, sleep, sleep-until HH:MM, wake-at HH:MM, wake-weekly Mon,Tue HH:MM, clear-wake-weekly,
  off, restart, cancel. Never try to bypass it.
- **Roles** (switched in the dashboard's My PC tab, `power.sh role nodeuser|both|processing`): NodeUser = uses the
  network only (this PC not shared, its containers stopped); Both; ProcessingNode = shares only. The installer /
  `SETUP-everything.cmd` installs both roles everywhere; setup asks to restart and resumes after login (RunOnce).
- **Apps**: pygame dashboard (`dashboard/`, self-updating launcher, Network + My PC tabs), VS Code extension,
  Claude side panel plugin `claude-skill/cpn-panel` (`/cpn`), this skill.

## Running commands

Prefer the user's shortcuts in an Ubuntu terminal; from Windows use **Windows' own ssh** (Git's `ssh` hangs with
Tailscale SSH): `C:\Windows\System32\OpenSSH\ssh.exe -n -o BatchMode=yes USER@HOST "bash ~/ros2-remote/processingoffloadPC/power.sh ACTION"`.
USER is the **Ubuntu** username on the powerplant (not the Windows name; VS Code setting `badgerlabs.remoteUser`).

| Goal | Shortcut (Ubuntu on user's PC) | power.sh action on the powerplant |
|---|---|---|
| List PCs (dot + specs) | `list-powerplants` | `specs` |
| Choose PC | `use-powerplant 4090` / `local` | |
| Start ROS + shell | `start-nuclear-powerplant` | `start` |
| Status | `offloadpc-status` | `status` (Specs/MAC/WakeTopic/Guardian lines) |
| Busy? | `show-running-processes` | `processes` (VERDICT: IDLE/BUSY) |
| Sleep | `sleep-nuclear-powerplant [HH:MM] [--after-finish] [--force]` | `sleep`, `sleep-until`, `sleep-after-finish [HH:MM|status|cancel]` |
| Wake (any network) | `wake-nuclear-powerplant` | (ntfy wake topic + LAN broadcast + optional Tailscale relay) |
| Guardian | `offloadpc-resume`, `offloadpc-guardian on|off` | `resume`, `guardian` |
| Distribute jobs | `distribute-work [--on a,b] [--plan]`, `cluster-status`, `stop-work`, `job-log NAME` | `capacity`, `run-job`, `jobs`, `stop-jobs`, `link` |
| Shut down/restart | `offloadpc-off` / `offloadpc-restart` / `offloadpc-cancel` | `off`, `restart`, `cancel` |
| Role (shared or not) | dashboard My PC tab | `role [nodeuser|both|processing]` |
| Availability schedule | dashboard My PC tab | `schedule [show|clear|"Mon-Fri 22:00-08:00; Sat-Sun 00:00-24:00"]` |
| Prove hardware | dashboard "Run hardware check now" | `hwcheck` (hwcheck.py in the dev container, ~6 s; result in capacity `verified`) |
| Wake info | `offloadpc-wake-info` | `wake-topic`, `wake-info` |

Wake from any network: a wake listener on the powerplant's LAN (`wake-listener/wake_listener.py --topic <WAKE_TOPIC>`
on a Pi / old laptop / Termux, or the ESP32 sketch) receives `wake <MAC>` from ntfy.sh and sends Wake-on-LAN.
Outside its SCHEDULE a powerplant isn't offered (capacity `available: false`), sleeps after 30 min owner-idle with
no work, and its agent wakes it at each window start.

Rules: sleep/off/restart exit **2** when busy (owner active <10 min, GPU >10 %, ROS nodes, running tmux jobs,
paused job). Only add `--force` when the user explicitly agrees. Never shut down a PC whose BIOS has a power-on
password unless the user insists (it won't come back without someone typing it); prefer sleep.

## Troubleshooting map

| Symptom | Cause / fix |
|---|---|
| `tailnet policy does not permit you to SSH as user X` | X doesn't exist on that powerplant -> use its Ubuntu username |
| SSH hangs from Windows | Git's ssh in PATH; use `C:\Windows\System32\OpenSSH\ssh.exe` and `-n` |
| Red dot / unreachable | asleep/off, Tailscale signed out, or nobody logged in to Windows (agent + WSL need a session; locked is fine) |
| "Windows agent isn't running" | log out/in on the powerplant or rerun `SETUP-processingoffloadPC.cmd` |
| Job paused (yellow dot) | guardian: owner active; auto-resumes after `RESUME_AFTER_IDLE`; `offloadpc-resume` forces |
| Wake fails from another network | needs a wake listener on the powerplant's LAN (`wake-listener/wake_listener.py --topic <WakeTopic>` or the ESP32 sketch); BIOS: Power On By PCI-E on, ErP off; wired |
| `capacity`/`run-job` unknown | powerplant has old scripts -> dashboard **Update kit** or rerun its SETUP |
| RAM speed lower than rated | XMP/DOCP off in BIOS |

Config on the powerplant: `~/.offload-agent/guardian.conf` (POWERPLANT_NAME, ENABLED, ACTIVE_SECONDS,
RESUME_AFTER_IDLE, AUTO_RESUME, NTFY_TOPIC, WAKE_TOPIC). Logs: `~/.offload-agent/guardian.log`,
job output `~/ros2-remote/ws/.jobs/NAME.log`.

## jobs.yaml (distribute-work)

`~/ros2-remote/ws/jobs.yaml` on the user's PC (example: `ws/jobs.example.yaml`). Per job: `name`, `run`
(required), `gpu`, `vram_gb`, `cpu`, `ram_gb`, `weight`, `pin` (never write `on:` - YAML turns it into `true`).
The scheduler gives GPU jobs to the most GPU power left (tier table x free VRAM), CPU jobs to most free threads,
and avoids PCs whose owner is active. It distributes separate jobs; it does not split one program.

## Etiquette

Powerplants may belong to relatives. Check `show-running-processes` before sleeping/shutting down, don't run heavy
jobs while the owner is active, and never read or touch the owner's Windows files.

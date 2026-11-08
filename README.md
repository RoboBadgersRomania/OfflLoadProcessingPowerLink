# OffLoad Processing Power Link

Run **ROS 2** on your everyday Windows PC or laptop and send the heavy work (AI models, SLAM,
simulation, training, big builds) to one or more powerful Windows PCs elsewhere, over the internet.
Those machines are the **nuclear powerplants** (processing offload PCs). They work in the
background: their screen isn't used and their owners keep using them normally.

```
 YOUR PC / LAPTOP (Windows)                    NUCLEAR POWERPLANT(S) (Windows, strong GPU)
 ──────────────────────────                    ───────────────────────────────────────────
 WSL2 Ubuntu 24.04 + ROS 2 Jazzy               WSL2 Ubuntu 24.04   e.g. processingoffloadpc (RTX 4090)
   Gazebo / RViz windows, light nodes ◄──┐       ├─ Docker: zenoh router :7447, foxglove :8765,
   your code, robot/camera plugged in    │       │          dev container (your heavy nodes + GPU)
                                         ├─ Tailscale ─┤ guardian (pauses jobs while the owner is active)
 VS Code + BadgerLabsOffloadingPP   ◄────┘ (encrypted) └─ Windows agent (hidden): power, idle time, specs
```

- **Tailscale** links the PCs securely from anywhere (home, university, hotspot). No port forwarding.
- **Zenoh** (`rmw_zenoh_cpp`) carries ROS 2 traffic over the internet (normal DDS needs multicast).
- **Several powerplants**: pick one by its specs (e.g. RTX 4090 at a relative's, your own GTX 1080 desktop).

## Fair to the PC owner

When a powerplant is **someone else's PC** (setup asks "whose PC is this?" → *someone else's*):

| | |
|---|---|
| **Privacy** | Ubuntu on that PC can't see its Windows drives and can't run Windows programs. The only bridge is a tiny Windows agent that accepts 7 fixed requests: `ping`, `sleep`, `sleep-until`, `wake-at`, `off`, `restart`, `cancel`. Your Tailscale access reaches only that Ubuntu, not Windows. |
| **No windows, no icons** | The agent runs hidden. Docker and Tailscale live inside Ubuntu. Nothing appears on the owner's screen or tray. |
| **Guardian** | If the owner starts using keyboard/mouse while your job runs, the job is **paused** (frozen, nothing lost) and you're notified. When nobody has used the PC for 10 min, it **resumes** and you're notified again. |
| **Busy check** | Sleep / shut down / restart refuse while someone used the PC in the last 10 min (unless you insist). |
| **Uninstall** | `UNINSTALL-processingoffloadPC.cmd` removes everything and restores the original sleep timer, wake timers and Wake-on-LAN settings. |

What the owner *will* notice: the setup (30–45 min, admin rights, 1–2 reboots), the PC no longer
going to sleep by itself (so it stays reachable), fans during heavy jobs. **Ask them first.**

## Requirements

| | Your PC / laptop | Nuclear powerplant |
|---|---|---|
| OS | Windows 10 22H2 / Windows 11 | Windows 10 22H2 / Windows 11 |
| GPU | anything that runs Gazebo/RViz | NVIDIA (RTX recommended), current driver |
| RAM | 16 GB+ | 16 GB+ (more = bigger jobs) |
| Disk | ~30 GB free on C: | ~60 GB free on C: |
| BIOS | virtualization (VT-x / SVM) on | virtualization on; Wake-on-LAN on (optional) |

Plus a free **Tailscale** account (tailscale.com, sign in with Google/GitHub/Microsoft).

## Quick start

1. Download this repo on each PC (**Code → Download ZIP**, extract) or `git clone` it.
2. **Each nuclear powerplant first:** double-click **`SETUP-processingoffloadPC.cmd`**. It asks:
   - a **name**: Enter = `processingoffloadpc`, or e.g. `4090` → `processingoffloadpc-4090`
   - **whose PC is this**: `1` someone else's (privacy + guardian) / `2` mine (full access, no auto-pause)
3. **Each of your PCs/laptops:** double-click **`SETUP-my-PC.cmd`**.
   A PC can be **both** (e.g. your desktop: powerplant for your laptop *and* a normal client).
4. Click **Yes** on the admin prompt and follow the window:
   - **REBOOT** requested → reboot, double-click the same file again (it continues where it stopped).
   - Ubuntu asks for a **username + password** once → choose any, then type `exit` at the prompt.
   - Installs ask for that **Ubuntu password** (nothing shows while typing; that's normal).
   - Powerplant: open the **Tailscale login link** it prints and sign in.
   - Your PC: click the **Tailscale tray icon → Log in** with the **same account**.
5. Check all machines appear at **login.tailscale.com/admin/machines**.

## Where do I type the commands?

All commands in this README (`ros2 ...`, `start-nuclear-powerplant`, ...) go in an **Ubuntu terminal
on your PC**, **not** PowerShell or Command Prompt. Open one of these:

| Option | How |
|---|---|
| **Ubuntu app** | Start menu → type **Ubuntu 24.04** → Enter. A window with `name@PC:~$` appears |
| **Windows Terminal** | Open *Terminal* → **˅** next to the tab → **Ubuntu-24.04** |
| **VS Code** (recommended) | Click the powerplant in the status bar, or `Ctrl+Shift+P` → **BadgerLabs: Open ROS shell on this PC** |

Inside `offloadpc` the prompt changes to `root@...:/ws#`: that terminal now runs **on the powerplant**.
`exit` brings you back.

### Test it
```bash
list-powerplants                       # 🟢/🔴 + specs of every powerplant
use-powerplant 4090                    # pick one (or: use-powerplant processingoffloadpc)
start-nuclear-powerplant               # starts ROS there, opens a shell in its ROS container
nvidia-smi                             #   shows that PC's GPU
ros2 run demo_nodes_cpp talker         #   publishes /chatter on the powerplant
```
Second Ubuntu window on your PC:
```bash
ros2 run demo_nodes_cpp listener       # prints "I heard: [Hello World: N]" -> linked!
```

## Daily use (commands on your PC)

| Command | What it does |
|---|---|
| `list-powerplants` | All powerplants with a 🟢 reachable / 🔴 offline dot and specs (GPU · CPU · RAM) |
| `use-powerplant NAME` | Switch powerplant (`4090`, `desktop`, full name, or `local` = this PC only) |
| `start-nuclear-powerplant` | Wakes it (if a wake relay is set), starts ROS, opens a ROS shell. Warns if the owner used it in the last 10 min |
| `offloadpc` | Shell inside the powerplant's ROS container |
| `ros2 topic list` | Topics from your PC **and** the powerplant |
| `show-running-processes` | GPU, CPU, owner at the keyboard?, ROS nodes, tmux jobs + verdict **IDLE / BUSY** |
| `sleep-nuclear-powerplant` | Sleep now (asks first if it's busy) |
| `sleep-nuclear-powerplant 22:30` | Sleep now, **wake automatically** at 22:30 |
| `sleep-nuclear-powerplant --after-finish` | **Sleep when your work is done** (idle 5 min in a row). Short: `sleep-after-finish` |
| `sleep-after-finish 07:00` / `status` / `cancel` | …and wake at 07:00 / is it waiting? / stop waiting |
| `wake-nuclear-powerplant` | Wake it over the internet via its wake relay (see below) |
| `offloadpc-resume` | Resume a job the guardian paused (won't re-pause for 60 min) |
| `offloadpc-guardian [on\|off]` | Guardian status / turn auto-pause on or off |
| `offloadpc-notifications [test]` | How to get phone notifications (pause / resume / going to sleep) |
| `offloadpc-status` | On? specs, GPU load, temperature, owner activity, guardian state |
| `offloadpc-off` / `offloadpc-restart` / `offloadpc-cancel` | Shut down / restart in 60 s (busy check) / cancel |
| `offloadpc-mac` | MAC address (remembered for waking) |

**Busy** means: GPU above 10%, high CPU load, ROS nodes or *running* tmux jobs, the guardian has
paused your job, or someone used keyboard/mouse in the last 10 minutes. Add `--force` to skip the
check. A tmux session whose job finished (only the shell is left) counts as idle:

```bash
offloadpc                                   # on the powerplant
tmux new -s train                           # start a tmux session
python train.py                             # long job...  then detach: Ctrl+B, then D
exit
sleep-nuclear-powerplant --after-finish     # back on your PC: it sleeps when train.py ends
```

**What runs where:**

| On your PC / laptop | On the powerplant (`offloadpc`) |
|---|---|
| Gazebo / RViz windows, your control nodes | AI models (detection, segmentation, LLMs), training |
| Anything plugged in (robot, camera, joystick) | SLAM / mapping, point clouds, path planning |
| Fast control loops (internet adds ~10–40 ms) | Long jobs in `tmux` |

- Build in `ws/src` → `cd /ws && colcon build --symlink-install` inside `offloadpc`.
- Send camera images **compressed** between PCs (`image_transport` → `compressed`).
- Run simulations on the powerplant **headless** (`gz sim -s -r world.sdf`), view them in **Foxglove**.

## Guardian + phone notifications

On powerplants set up as *someone else's PC* the guardian is **on**:

1. Your job runs (GPU busy or the ROS container using CPU).
2. The owner touches keyboard/mouse → within ~10 s the whole ROS dev container is **paused**
   (`docker pause`: frozen in place, memory kept, nothing lost). Zenoh/Foxglove keep running.
3. You get notified: VS Code status bar turns 🟡 + a warning, and a phone push (below).
4. Nobody touches the PC for 10 min → job **resumes** automatically → notified again.
5. Need it now? `offloadpc-resume` (the guardian then leaves it alone for 60 min).

**Phone notifications** use [ntfy](https://ntfy.sh) (free, no account): setup creates a random topic
per powerplant. Run `offloadpc-notifications`, install the **ntfy** app (Android/iOS) or open the
browser link, subscribe to the topic. Only short messages like "Job paused on processingoffloadpc"
are sent. Settings (on the powerplant): `~/.offload-agent/guardian.conf`
(`RESUME_AFTER_IDLE`, `ACTIVE_SECONDS`, `AUTO_RESUME`, `NTFY_TOPIC` empty = off).

Note: keyboard/mouse is what's detected; someone playing **only with a gamepad** isn't seen.

## Wake over the internet

A sleeping or switched-off PC is **not on Tailscale**, so nothing can reach it directly over the
internet. The wake signal (Wake-on-LAN "magic packet") must come from **inside its home network**:

| Option | Cost | How |
|---|---|---|
| **Scheduled wake** | free | `sleep-nuclear-powerplant 07:00` – it wakes itself at 07:00 |
| **Wake relay** (recommended) | ~100–250 RON | Any always-on Linux device on that network with Tailscale: Raspberry Pi Zero 2 W / Pi 4, old laptop, NAS. Then `set-wake-relay pi@wakepi` once, and `start-nuclear-powerplant` / `wake-nuclear-powerplant` wake it automatically (VS Code: *Wake nuclear powerplant*) |
| **Router app** | free if supported | Many routers (FRITZ!Box, ASUS, some TP-Link) have a "Wake on LAN" button in their app, also from outside |

For Wake-on-LAN to work: enable *Wake on LAN / Power On By PCI-E* in the powerplant's BIOS, use a
**wired** connection, and run `offloadpc-mac` once while it's on (so its MAC is remembered).
Waking from **sleep** works best; from shutdown also disable Windows *Fast Startup* and BIOS *ErP*.

**BIOS password?** Waking from **sleep** never asks for it (the BIOS isn't involved) and Windows
stays logged in. A **power-on / system** BIOS password, however, stops every **restart or
shutdown** at the password screen, and the PC stays unreachable until someone types it. With such a
password, only use sleep (avoid `offloadpc-restart` / `offloadpc-off`, and keep Windows Update from
restarting it at night). A **setup / admin** password (only for entering the BIOS) doesn't matter.

Setting up a Raspberry Pi relay: install Raspberry Pi OS Lite → `curl -fsSL https://tailscale.com/install.sh | sh`
→ `sudo tailscale up --ssh` (same account) → done (`python3` is preinstalled).

## VS Code

VS Code is the usual editor for ROS 2 work. You use **two VS Code windows** (your PC + the
powerplant) and the **BadgerLabsOffloadingPP** extension to control the powerplants.

### 1. Extensions
`SETUP-my-PC.cmd` installs these if VS Code is installed (else: Extensions panel, `Ctrl+Shift+X`):

| Extension | Why |
|---|---|
| **WSL** (`ms-vscode-remote.remote-wsl`) | Open your PC's Ubuntu in VS Code |
| **Remote - SSH** (`ms-vscode-remote.remote-ssh`) | Open a powerplant in VS Code |
| **Dev Containers** (`ms-vscode-remote.remote-containers`) | Work *inside* the powerplant's ROS container |
| **Robot Developer Extensions for ROS 2** (`Ranch-Hand-Robotics.rde-ros-2`) | ROS 2 launch/debug, URDF preview |
| **Python**, **C/C++**, **CMake Tools** | Write ROS nodes in Python / C++ |
| **BadgerLabsOffloadingPP** | This repo's extension: `code --install-extension vscode-extension\BadgerLabsOffloadingPP-0.2.1.vsix` |

### 2. Window 1: your PC (Gazebo, RViz, light nodes)
- `Ctrl+Shift+P` → **WSL: Connect to WSL** (bottom-left shows `WSL: Ubuntu-24.04`).
- *File → Open Folder* → your workspace. Terminal (``Ctrl+` ``) = Ubuntu on **your PC**.

### 3. Window 2: the powerplant (heavy nodes, AI, builds)
- Status bar menu → **Open powerplant workspace** (opens `~/ros2-remote/ws` there).
- To work *inside* the ROS container: `Ctrl+Shift+P` → **Dev Containers: Attach to Running Container** → `docker-dev-1`.
- Build with **Build workspace on powerplant** or `colcon build --symlink-install`.

### 4. The extension
The status bar (bottom left) shows the current powerplant:
`🟢 RTX 4090 · 12%` reachable (GPU load) · `🟡 RTX 4090 · paused` owner using it · `🔴 GTX 1080` offline.
**Click it** for the menu. The first entry switches powerplant: like choosing an AI model, each PC
is listed by its **specs** (`🟢 GTX 1080 · i7-9700K · 16 GB DDR4 3333MHz`) with a live dot.

| Command | Does |
|---|---|
| **Choose nuclear powerplant** | Pick a PC by its specs, 🟢/🔴 shows which are reachable |
| **Start nuclear powerplant** | Wake (relay) if needed, start ROS, open a ROS shell; warns if the owner is around |
| **Show running processes** | Activity report + IDLE/BUSY verdict (*BadgerLabs* output panel) |
| **Sleep nuclear powerplant** / **...wake at...** / **...after work finishes** | Sleep options |
| **Wake nuclear powerplant** | Wake-on-LAN through its wake relay |
| **Resume paused job**, **Guardian**, **Phone notifications** | Guardian controls |
| **Open powerplant workspace**, **ROS shell on powerplant / this PC**, **Build**, **Foxglove** | Work |
| **Restart ROS containers**, **Restart PC**, **Shut down PC**, **Cancel**, **Show MAC** | Maintenance |

First use asks your **Ubuntu username on the powerplants** (`badgerlabs.remoteUser`).

## Uninstall

| Where | Double-click | Removes |
|---|---|---|
| A powerplant | **`UNINSTALL-processingoffloadPC.cmd`** | Agent + tasks, guardian, ROS containers, Tailscale login; restores sleep timer, wake timers, Wake-on-LAN, `.wslconfig` |
| Your PC | **`UNINSTALL-my-PC.cmd`** | Ubuntu shortcuts, VS Code extension, optionally Tailscale |

Both then **ask** whether to delete Ubuntu 24.04 (and everything in it) and whether to remove WSL
from Windows completely (default: keep). Afterwards remove the machine from
login.tailscale.com/admin/machines.

## Repository layout

| Path | What |
|---|---|
| `SETUP-processingoffloadPC.cmd` / `UNINSTALL-processingoffloadPC.cmd` | Install / remove a nuclear powerplant |
| `SETUP-my-PC.cmd` / `UNINSTALL-my-PC.cmd` | Install / remove on your PC(s) / laptop(s) |
| `setup.ps1`, `uninstall.ps1`, `common.ps1` | The setup / uninstall logic (safe to re-run) |
| `check-specs.ps1` | Read-only hardware/Windows check |
| `processingoffloadPC/` | Powerplant: `agent.ps1` (Windows bridge), `windows-setup.ps1`, `setup-wsl.sh`, `power.sh`, `guardian.sh`, `lib.sh` |
| `your-pc/` | Your PC: Windows settings + Tailscale, ROS 2 Jazzy + Zenoh + shortcuts |
| `docker/` | ROS 2 Jazzy image (Gazebo, Zenoh, Foxglove, tmux) + compose file |
| `vscode-extension/` | **BadgerLabsOffloadingPP**: source, ready `.vsix`, `build-vsix.py` (no Node needed) |
| `ws/` | Your ROS 2 workspace (mounted at `/ws` in the container) |

## Troubleshooting

- **Powerplant 🔴 although it's on:** same Tailscale account? On it (Ubuntu): `sudo tailscale status`.
  Someone must be **logged in to Windows** (locked is fine) for the agent and Ubuntu to run.
- **"Windows agent isn't running":** log out and back in on the powerplant, or rerun its SETUP file.
- **Different Ubuntu usernames:** edit `OFFLOAD_USER` in `~/.bashrc` on your PC (VS Code: `badgerlabs.remoteUser`).
- **`nvidia-smi` fails on the powerplant:** update the NVIDIA driver **on Windows**; never inside Ubuntu.
- **Working offline:** `use-powerplant local`, then run `ros2 run rmw_zenoh_cpp rmw_zenohd` in one terminal.
- **RAM speed shows lower than rated** (e.g. DDR4 2400MHz instead of 3333): XMP/DOCP is off in that PC's BIOS.
- **Heavy rendering (Isaac Sim):** CUDA/AI runs at full speed in Docker on WSL; for Isaac Sim use
  NVIDIA's Isaac Sim container with livestreaming, or install it natively on Windows.

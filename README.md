# OffLoad Processing Power Link

Run **ROS 2** on your everyday Windows PC or laptop and send the heavy work (AI models, SLAM,
simulation, training, big builds) to a powerful Windows PC somewhere else, over the internet.
That machine is the **processing offload PC**. It runs in the background: its screen isn't used,
and its owner can keep using it.

```
 YOUR PC / LAPTOP (Windows)                    PROCESSING OFFLOAD PC (Windows, strong GPU)
 ──────────────────────────                    ───────────────────────────────────────────
 WSL2 Ubuntu 24.04 + ROS 2 Jazzy               WSL2 Ubuntu 24.04  (network name: processingoffloadpc)
   Gazebo / RViz windows, light nodes ◄──┐       └─ Docker
   your code, robot/camera plugged in    │           ├─ zenoh     ROS 2 discovery router   :7447
                                         ├─ Tailscale ─┤ foxglove  viewer bridge     :8765
 VS Code (Remote-SSH), Foxglove     ◄────┘ (encrypted) └─ dev       your heavy nodes + GPU
```

- **Tailscale** links the PCs securely from anywhere (home, university, hotspot). No port forwarding.
- **Zenoh** (`rmw_zenoh_cpp`) carries ROS 2 traffic over the internet. Normal DDS needs multicast,
  which doesn't work over Tailscale.
- Only the offload PC's **Ubuntu (WSL)** joins your Tailscale network, not its Windows side.

## Requirements

| | Your PC / laptop | Processing offload PC |
|---|---|---|
| OS | Windows 10 22H2 / Windows 11 | Windows 10 22H2 / Windows 11 |
| GPU | anything that runs Gazebo/RViz (e.g. GTX 1080, RTX 3050) | NVIDIA RTX (e.g. RTX 4090), current driver |
| RAM | 16 GB+ | 32 GB+ (more = bigger jobs) |
| Disk | ~30 GB free on C: | ~60 GB free on C: |
| BIOS | virtualization (VT-x / SVM) on | virtualization on; Wake-on-LAN on (optional) |

Plus a free **Tailscale** account (tailscale.com, sign in with Google/GitHub/Microsoft).

## Quick start

1. Download this repo on each PC (**Code → Download ZIP**, extract) or `git clone` it.
2. **Processing offload PC first:** double-click **`SETUP-processingoffloadPC.cmd`**.
3. **Each of your PCs/laptops:** double-click **`SETUP-my-PC.cmd`**.
4. Click **Yes** on the admin prompt and follow the window:
   - **REBOOT** requested → reboot, double-click the same file again (it continues where it stopped).
   - Ubuntu asks for a **username + password** once → choose any, then type `exit` at the prompt.
   - Installs ask for that **Ubuntu password** (nothing shows while typing; that's normal).
   - Offload PC: open the **Tailscale login link** it prints and sign in.
   - Your PC: click the **Tailscale tray icon → Log in** with the **same account**.
5. Check both machines appear at **console.tailscale.com → Machines**.

## Where do I type the commands?

All commands in this README (`ros2 ...`, `start-nuclear-powerplant`, `offloadpc`, ...) are typed in an
**Ubuntu terminal on your PC**, **not** in PowerShell or Command Prompt (they don't know these commands).
Open one of these:

| Option | How |
|---|---|
| **Ubuntu app** | Start menu → type **Ubuntu 24.04** → Enter. A black window with `name@PC:~$` appears |
| **Windows Terminal** | Open *Terminal* → click the **˅** next to the tab → **Ubuntu-24.04** |
| **VS Code** (recommended) | `Ctrl+Shift+P` → **BadgerLabs: Open ROS shell on this PC**, or connect VS Code to WSL (see [VS Code](#vs-code)) and open a terminal with ``Ctrl+` `` |

You know you're in the right place when the prompt looks like `name@PC:~$`.
Inside `offloadpc` the prompt changes to `root@...:/ws#`: that terminal now runs **on the offload PC**.
Type `exit` to come back to your PC.

### Test it (on your PC, in "Ubuntu 24.04")
```bash
start-nuclear-powerplant               # starts ROS there and drops you into the offload PC's ROS container
nvidia-smi                             #   shows the offload PC's GPU
ros2 run demo_nodes_cpp talker         #   publishes /chatter on the offload PC
```
Second Ubuntu window on your PC:
```bash
ros2 run demo_nodes_cpp listener       # prints "I heard: [Hello World: N]" -> linked!
```

## Daily use (commands on your PC)

| Command | What it does |
|---|---|
| `start-nuclear-powerplant` | Checks it's online, starts the ROS containers, opens a ROS shell on it |
| `offloadpc` | Shell inside the offload PC's ROS container (build/run heavy nodes there) |
| `ros2 topic list` | Topics from **both** PCs |
| `show-running-processes` | What's running there (GPU, CPU, ROS nodes, tmux jobs, someone at the PC?) + verdict **IDLE / BUSY** |
| `sleep-nuclear-powerplant` | Put it to sleep (checks it's idle first, asks if busy) |
| `sleep-nuclear-powerplant 22:30` | Sleep now, **wake automatically** at 22:30 (24 h clock) |
| `sleep-nuclear-powerplant --after-finish` | **Sleep when your work is done**: waits in the background until it's idle 5 min in a row, then sleeps. Short form: `sleep-after-finish` |
| `sleep-nuclear-powerplant --after-finish 07:00` | Same, and wake up again at 07:00 |
| `sleep-after-finish status` / `sleep-after-finish cancel` | Is it waiting? (shows the last checks) / stop waiting, stay on |
| `offloadpc-status` | Is it on? GPU name, load, memory, temperature, power |
| `offloadpc-off` / `offloadpc-restart` | Shut down / restart in 60 s (busy check first) |
| `offloadpc-cancel` | Cancel a pending shutdown/restart |
| `offloadpc-mac` | Show (and remember) its MAC address for Wake-on-LAN |

`sleep-nuclear-powerplant`, `offloadpc-off` and `offloadpc-restart` count the PC as **busy** if
the GPU is above 10%, CPU load is high, ROS nodes or `tmux` jobs are running, or someone used its
keyboard/mouse in the last 10 minutes. Add `--force` to skip the check. A `tmux` session whose job
has finished (only the shell is left) counts as idle, so this works with `--after-finish`:

```bash
offloadpc                                   # on the offload PC
tmux new -s train                           # start a tmux session
python train.py                             # long job...  then detach: Ctrl+B, then D
exit
sleep-nuclear-powerplant --after-finish     # back on your PC: it sleeps when train.py ends
```

**What runs where:**

| On your PC / laptop | On the offload PC (`offloadpc`) |
|---|---|
| Gazebo / RViz windows, your control nodes | AI models (detection, segmentation, LLMs), training |
| Anything plugged in (robot, camera, joystick) | SLAM / mapping, point clouds, path planning |
| Fast control loops (internet adds ~10–40 ms) | Long jobs: `tmux new -s job`, reattach `tmux attach -t job` |

- Build your packages in `ws/src` → `cd /ws && colcon build --symlink-install` inside `offloadpc`.
- Send camera images **compressed** between PCs (`image_transport` → `compressed`).
- Run simulations on the offload PC **headless** (`gz sim -s -r world.sdf`) and view them in
  **Foxglove** (foxglove.dev) → *Open connection* → `ws://processingoffloadpc:8765`.
## VS Code

VS Code is the most common editor for ROS 2 work. With this setup you use **two VS Code windows**:
one for your PC (light work) and one connected to the offload PC (heavy work), plus the
**BadgerLabsOffloadingPP** extension to control the offload PC.

### 1. Extensions
`SETUP-my-PC.cmd` installs these automatically if VS Code is installed. Otherwise install them from the Extensions panel (`Ctrl+Shift+X`):

| Extension | Why |
|---|---|
| **WSL** (`ms-vscode-remote.remote-wsl`) | Open your PC's Ubuntu in VS Code |
| **Remote - SSH** (`ms-vscode-remote.remote-ssh`) | Open the offload PC in VS Code |
| **Dev Containers** (`ms-vscode-remote.remote-containers`) | Work *inside* the offload PC's ROS container |
| **Robot Developer Extensions for ROS 2** (`Ranch-Hand-Robotics.rde-ros-2`) | ROS 2 launch/debug, URDF preview, ROS commands |
| **Python**, **C/C++**, **CMake Tools** | Write ROS nodes in Python / C++ |
| **BadgerLabsOffloadingPP** | This repo's extension (below) |

Install BadgerLabsOffloadingPP by hand with:
```powershell
code --install-extension vscode-extension\BadgerLabsOffloadingPP-0.1.0.vsix
```

### 2. Window 1: your PC (Gazebo, RViz, light nodes)
- `Ctrl+Shift+P` → **WSL: Connect to WSL** (bottom-left corner shows `WSL: Ubuntu-24.04`).
- *File → Open Folder* → your workspace (e.g. `/home/<you>/my_ws`).
- Terminal: ``Ctrl+` `` → you are in Ubuntu on **your PC**. Run `ros2 launch ...`, `gz sim ...`, `rviz2` here.

### 3. Window 2: the offload PC (heavy nodes, AI, builds)
- `Ctrl+Shift+P` → **BadgerLabs: Open offload PC workspace** (opens `~/ros2-remote/ws` there).
- First time only: pick **Linux** if asked, and open the Tailscale link if one appears in the terminal.
- To work *inside* the ROS container (ROS + GPU available): `Ctrl+Shift+P` →
  **Dev Containers: Attach to Running Container** → `docker-dev-1`.
- Files in `ws/src` are the same inside and outside the container. Build with
  **BadgerLabs: Build workspace on offload PC** or `colcon build --symlink-install` in the terminal.

### 4. BadgerLabsOffloadingPP extension
The status bar (bottom left) shows `Offload: GPU 12%`, `Offload: offline` or `Offload: login needed`.
**Click it** for the menu, or use `Ctrl+Shift+P` → `BadgerLabs: ...`:

| Command | Does |
|---|---|
| **Start nuclear powerplant** | Starts ROS on the offload PC and opens a ROS shell on it |
| **Show running processes** | Activity report + IDLE/BUSY verdict (in the *BadgerLabs* output panel) |
| **Sleep nuclear powerplant** / **...and wake at...** | Sleep (asks first if busy) / sleep + scheduled wake |
| **Sleep nuclear powerplant after work finishes** | Sleep automatically when idle (optional wake time, status, cancel) |
| **Open offload PC workspace** | New VS Code window on the offload PC (Remote-SSH) |
| **Open ROS shell on offload PC** / **on this PC** | Terminals for heavy / light work |
| **Build workspace on offload PC** | `colcon build --symlink-install` in the container |
| **Open Foxglove viewer** | Foxglove connected to `ws://processingoffloadpc:8765` |
| **Restart ROS containers**, **Restart PC**, **Shut down PC**, **Cancel**, **Show MAC** | Maintenance |

First use asks for your **Ubuntu username on the offload PC** (saved in settings: `badgerlabs.remoteUser`).

**A typical session:** click the status bar → *Start nuclear powerplant* → code in Window 2 →
*Build workspace* → run heavy nodes in the offload terminal → run Gazebo/RViz in Window 1 →
when done: *Show running processes* → *Sleep nuclear powerplant*.

## Remote power: sleep, wake, off

| Situation | Can you control it remotely? |
|---|---|
| On → **sleep** | ✅ `sleep-nuclear-powerplant`. Windows stays logged in, so ROS resumes on wake |
| Sleep → **on at a set time** | ✅ `sleep-nuclear-powerplant HH:MM` (Windows wake timer, enabled by setup) |
| Sleep/off → **on right now** | ⚠️ Needs **Wake-on-LAN** from a device on the same home network (see below) |
| On → **off / restart** | ✅ `offloadpc-off` / `offloadpc-restart`. After boot Windows must log in again |

**Prefer sleep over shutdown:** after sleep everything resumes by itself; after a shutdown someone
must log in (or enable Windows auto-login) before ROS comes back.

**Wake-on-LAN (optional):** a sleeping/off PC isn't on Tailscale, so the wake signal must come from
its own network:
1. Enable *Wake on LAN / Power on by PCI-E* in the offload PC's BIOS; use a **wired** connection.
2. Setup already enables *Wake on Magic Packet* in Windows. Get the MAC with `offloadpc-mac`.
3. Send the wake signal from the **router's app** (many have a WoL button), a phone WoL app on the
   same Wi-Fi, or any always-on device there (e.g. a Raspberry Pi with Tailscale: `wakeonlan <MAC>`).

## Repository layout

| Path | What |
|---|---|
| `SETUP-processingoffloadPC.cmd` | One-click setup for the processing offload PC |
| `SETUP-my-PC.cmd` | One-click setup for your PC(s) / laptop(s) |
| `setup.ps1` | The shared setup logic (WSL 2 → Ubuntu → Windows settings → Linux side). Safe to re-run |
| `check-specs.ps1` | Read-only hardware/Windows check (run anywhere) |
| `processingoffloadPC/` | Offload PC: Windows settings, Docker + GPU + Tailscale install, `power.sh` |
| `your-pc/` | Your PC: Windows settings + Tailscale, ROS 2 Jazzy + Zenoh install and shortcuts |
| `docker/` | ROS 2 Jazzy image (Gazebo, Zenoh, Foxglove) + compose file for the offload PC |
| `vscode-extension/` | **BadgerLabsOffloadingPP** VS Code extension: source, ready `.vsix`, `build-vsix.py` |
| `ws/` | Your ROS 2 workspace (mounted at `/ws` in the container) |

## Doing it by hand (what the SETUP files do)

**Both machines:** `wsl --install -d Ubuntu-24.04` (admin) → reboot → open Ubuntu, create user.

**Offload PC:**
```powershell
powershell -ExecutionPolicy Bypass -File .\processingoffloadPC\windows-setup.ps1   # admin
```
```bash
cp -r /mnt/c/path/to/repo ~/ros2-remote && cd ~/ros2-remote
bash processingoffloadPC/setup-wsl.sh          # Docker, NVIDIA toolkit, Tailscale
cd docker && sudo docker compose up -d --build # start zenoh, foxglove, dev
```
**Your PC:**
```powershell
powershell -ExecutionPolicy Bypass -File .\your-pc\windows-setup.ps1              # admin
```
```bash
cp -r /mnt/c/path/to/repo ~/ros2-remote
bash ~/ros2-remote/your-pc/setup-ros-client.sh # ROS 2 Jazzy, Zenoh, shortcuts
```

## Troubleshooting

- **`processingoffloadpc` not found:** both PCs on the same Tailscale account? On the offload PC
  (Ubuntu): `sudo tailscale up --ssh --hostname=processingoffloadpc`.
- **Different Ubuntu usernames on the two PCs:** edit `OFFLOAD_USER` in `~/.bashrc` on your PC.
- **`nvidia-smi` fails on the offload PC:** update the NVIDIA driver **on Windows**; never install
  a driver inside Ubuntu.
- **Power commands say "can't reach Windows":** on the offload PC run `wsl --shutdown`, then log
  in again (the logon task restarts Ubuntu).
- **Working offline (offload PC off):** on your PC comment out `ZENOH_CONFIG_OVERRIDE` in
  `~/.bashrc` and run `ros2 run rmw_zenoh_cpp rmw_zenohd` in one terminal.
- **GUI windows on the offload PC** open on *its* monitor; use Foxglove instead, or stream its
  desktop with Sunshine + Moonlight.
- **Heavy rendering (Isaac Sim):** CUDA/AI runs at full speed in Docker on WSL; for Isaac Sim use
  NVIDIA's Isaac Sim container with livestreaming, or install it natively on Windows.

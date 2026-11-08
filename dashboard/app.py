"""Computing Power Network - desktop dashboard (pygame).

Don't run this file directly: run launcher.py (or the compiled ComputingPowerNetwork.exe), which keeps
this file up to date from the GitHub repo. Needs: Windows, Tailscale signed in, and SETUP-my-PC done.
"""
APP_VERSION = '1.1.0'

import base64
import concurrent.futures as cf
import json
import math
import os
import queue
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile

import pygame

REPO = 'RoboBadgersRomania/OfflLoadProcessingPowerLink'
RAW = f'https://raw.githubusercontent.com/{REPO}/main'
ZIP = f'https://codeload.github.com/{REPO}/zip/refs/heads/main'
PREFIX = 'processingoffloadpc'
DATA = os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), 'OffloadPC')
CFG_FILE = os.path.join(DATA, 'dashboard.json')
POWER = 'bash ~/ros2-remote/processingoffloadPC/power.sh'
NOWIN = getattr(subprocess, 'CREATE_NO_WINDOW', 0)
# Always Windows' own OpenSSH: Git's ssh (often first in PATH) hangs with Tailscale SSH
SSH = next((p for p in (os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'OpenSSH', 'ssh.exe'),) if os.path.exists(p)), 'ssh')

BG, PANEL, CARD, CARD_HI, CARD_SEL = (16, 18, 24), (26, 29, 38), (34, 38, 50), (42, 47, 62), (50, 60, 84)
TEXT, DIM, FAINT = (228, 231, 238), (146, 152, 168), (90, 96, 110)
GREEN, RED, YELLOW, BLUE, ORANGE = (64, 204, 116), (226, 76, 76), (242, 192, 54), (88, 156, 255), (255, 160, 48)


# ======================================================================================= helpers
def short(h):
    return 'main' if h == PREFIX else h.replace(PREFIX + '-', '')


def run(args, timeout=60, input_bytes=None):
    try:
        r = subprocess.run(args, capture_output=True, timeout=timeout, creationflags=NOWIN,
                           **({'input': input_bytes} if input_bytes is not None else {'stdin': subprocess.DEVNULL}))
        return r.returncode, r.stdout.decode('utf-8', 'replace').replace('\x00', '').strip(), \
            r.stderr.decode('utf-8', 'replace').replace('\x00', '').strip()
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout'
    except FileNotFoundError as e:
        return 127, '', str(e)


def ssh(user, host, cmd, timeout=40):
    return run([SSH, '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new',
                f'{user}@{host}', cmd], timeout)


def reachable(host, timeout=3):
    try:
        socket.create_connection((host, 22), timeout).close()
        return True
    except OSError:
        return False


def tailscale_exe():
    on_drives = [f'{d}:\\Programs\\Tailscale\\tailscale.exe' for d in 'CDEFGHIJKLMNOPQRSTUVWXYZ']   # setup may use the kit's drive
    for p in [shutil.which('tailscale'), r'C:\Program Files\Tailscale\tailscale.exe'] + on_drives:
        if p and os.path.exists(p):
            return p
    return None


def discover():
    ts = tailscale_exe()
    if not ts:
        return []
    code, out, _ = run([ts, 'status'], 10)
    return sorted({l.split()[1] for l in out.splitlines() if len(l.split()) > 1 and l.split()[1].startswith(PREFIX)})


def wsl(distro, cmd, timeout=300):
    return run(['wsl.exe', '-d', distro, '--exec', 'bash', '-lc', cmd], timeout)


def http_get(url, timeout=15):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'ComputingPowerNetwork'}), timeout=timeout) as r:
            return r.read()
    except Exception:
        return None


def send_wol_direct(mac):
    raw = bytes.fromhex(re.sub(r'[:-]', '', mac))
    packet = b'\xff' * 6 + raw * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    targets = {'255.255.255.255'}
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith(('127.', '100.', '169.254.')):
                targets.add('.'.join(ip.split('.')[:3]) + '.255')    # /24 guess - typical home network
    except OSError:
        pass
    for t in targets:
        for port in (7, 9):
            try:
                s.sendto(packet, (t, port))
            except OSError:
                pass
    s.close()
    return sorted(targets)


def newer(a, b):
    pa, pb = [int(x) for x in re.findall(r'\d+', a)[:3]], [int(x) for x in re.findall(r'\d+', b)[:3]]
    return pa > pb


# ======================================================================================= model
class Plant:
    def __init__(self, host):
        self.host = host
        self.online = None          # None = checking
        self.cap = {}
        self.ticked = False
        self.working = ''           # current action label

    @property
    def owner_active(self):
        return 0 <= self.cap.get('owner_idle_s', -1) < 600

    @property
    def dot(self):
        if self.online is None:
            return FAINT
        if not self.online:
            return RED
        if self.cap.get('available') is False:
            return (110, 122, 156)
        return YELLOW if (self.cap.get('paused') or self.owner_active) else GREEN


class Config:
    def __init__(self):
        self.d = {'user': '', 'distro': 'Ubuntu-24.04', 'known': [], 'plants': {}, 'focus': ''}
        try:
            self.d.update(json.load(open(CFG_FILE)))
        except (OSError, ValueError):
            pass

    def save(self):
        os.makedirs(DATA, exist_ok=True)
        json.dump(self.d, open(CFG_FILE, 'w'), indent=1)

    def plant(self, host):
        return self.d['plants'].setdefault(host, {})


# ======================================================================================= UI bits
class Button:
    def __init__(self, label, action, color=BLUE, needs='focus', active=None):
        self.label, self.action, self.color, self.needs, self.active = label, action, color, needs, active
        self.rect = pygame.Rect(0, 0, 0, 0)
        self.enabled = True


def ellipsize(font, text, width):
    if font.size(text)[0] <= width:
        return text
    while text and font.size(text + '...')[0] > width:
        text = text[:-1]
    return text + '...'


# ======================================================================================= app
class Dashboard:
    def __init__(self, updated_from=None):
        pygame.init()
        pygame.display.set_caption(f'Computing Power Network  v{APP_VERSION}')
        self.screen = pygame.display.set_mode((1240, 780), pygame.RESIZABLE)
        f = 'segoeui,arial,helvetica'
        self.f_big = pygame.font.SysFont(f, 24, bold=True)
        self.f_mid = pygame.font.SysFont(f, 17, bold=True)
        self.f = pygame.font.SysFont(f, 15)
        self.f_small = pygame.font.SysFont(f, 13)
        self.f_mono = pygame.font.SysFont('consolas,couriernew,monospace', 14)
        self.cfg = Config()
        self.plants = {h: Plant(h) for h in self.cfg.d['known']}
        self.focus = self.cfg.d.get('focus') or (next(iter(self.plants)) if self.plants else '')
        self.q = queue.Queue()
        self.log_lines = []
        self.log_scroll = 0
        self.card_scroll = 0
        self.modal = None          # dict(kind='confirm'|'input', ...)
        self.update_note = f'updated to v{APP_VERSION}' if updated_from else ''
        self.running = True
        self._poll_event = threading.Event()
        self.buttons = [
            Button('Start', self.a_start, GREEN), Button('Status', self.a_status),
            Button('Running processes', self.a_processes), Button('Sleep', self.a_sleep, ORANGE),
            Button('Sleep after finish', self.a_sleep_after, ORANGE), Button('Sleep & wake at...', self.a_sleep_until, ORANGE),
            Button('Wake (any network)', self.a_wake, YELLOW, needs='focus_any'), Button('Resume paused job', self.a_resume),
            Button('Restart ROS', self.a_restart_ros), Button('Shut down', self.a_shutdown, RED),
        ]
        self.multi_buttons = [
            Button('Distribute work', self.a_distribute, GREEN, needs='ticked'),
            Button('Jobs status', self.a_jobs, needs='none'), Button('Stop work', self.a_stop_work, RED, needs='none'),
        ]
        self.top_buttons = [Button('Refresh', lambda: (self.poll_now(), self.poll_local()), needs='none'),
                            Button('Update kit', self.a_update_kit, ORANGE, needs='none')]
        # ---- tabs + My PC
        self.tab = 'network'
        self.local = {'installed': None}
        self._local_event = threading.Event()
        self.tab_buttons = [Button('Network', lambda: self.set_tab('network'), needs='none', active=lambda: self.tab == 'network'),
                            Button('My PC', lambda: self.set_tab('mypc'), needs='none', active=lambda: self.tab == 'mypc')]
        role = lambda r: (lambda: self.local.get('role') == r)
        self.role_buttons = [Button('NodeUser', lambda: self.a_role('nodeuser'), GREEN, 'local', role('nodeuser')),
                             Button('Both', lambda: self.a_role('both'), GREEN, 'local', role('both')),
                             Button('ProcessingNode', lambda: self.a_role('processing'), GREEN, 'local', role('processing'))]
        self.mode_buttons = [Button('Closed circuit', lambda: self.log('Closed circuit is on: only PCs on your own Tailscale account.'),
                                    GREEN, 'none', lambda: True),
                             Button('Global (credits) - planned', lambda: None, GREEN, 'never', lambda: False)]
        self.sched_buttons = [Button('Always', lambda: self.a_schedule('clear'), BLUE, 'local'),
                              Button('Nights + weekends', lambda: self.a_schedule('Mon-Fri 22:00-08:00; Sat-Sun 00:00-24:00'), BLUE, 'local'),
                              Button('Weekends only', lambda: self.a_schedule('Sat-Sun 00:00-24:00'), BLUE, 'local'),
                              Button('Custom...', self.a_schedule_custom, BLUE, 'local')]
        self.check_buttons = [Button('Run hardware check now', self.a_hwcheck_local, GREEN, 'local'),
                              Button('Refresh this PC', self.poll_local, BLUE, 'none')]
        self.log(f'Dashboard v{APP_VERSION}. Looking for nuclear powerplants...')
        if not self.cfg.d['user']:
            threading.Thread(target=self._guess_user, daemon=True).start()
        threading.Thread(target=self.poller, daemon=True).start()
        threading.Thread(target=self.check_dashboard_update, daemon=True).start()
        threading.Thread(target=self.local_poller, daemon=True).start()

    # ------------------------------------------------------------------ background work
    def log(self, text):
        for line in str(text).splitlines() or ['']:
            self.q.put(('log', line))

    def _guess_user(self):
        code, out, _ = wsl(self.cfg.d['distro'], 'whoami', 15)
        self.q.put(('ask_user', out if code == 0 and re.fullmatch(r'[a-z_][a-z0-9_-]*', out or '') else ''))

    def poll_now(self):
        self._poll_event.set()

    def poller(self):
        last_status = {}
        while self.running:
            hosts = sorted(set(self.cfg.d['known']) | set(discover()))
            self.q.put(('hosts', hosts))
            user = self.cfg.d['user']

            def check(h):
                if not reachable(h):
                    return h, False, None, None
                cap = status = None
                if user:
                    code, out, _ = ssh(user, h, f'{POWER} capacity', 40)
                    if code == 0 and out:
                        try:
                            cap = json.loads(out.splitlines()[-1])
                        except ValueError:
                            pass
                    if cap is None or time.time() - last_status.get(h, 0) > 300:      # MAC / wake topic every 5 min
                        code, out, _ = ssh(user, h, f'{POWER} status', 40)
                        if code == 0:
                            status = out; last_status[h] = time.time()
                return h, True, cap, status
            with cf.ThreadPoolExecutor(8) as ex:
                for res in ex.map(check, hosts):
                    self.q.put(('plant', res))
            self._poll_event.wait(25)
            self._poll_event.clear()

    def check_dashboard_update(self):
        while self.running:
            m = http_get(f'{RAW}/dashboard/manifest.json')
            try:
                latest = json.loads(m)['version'] if m else ''
            except ValueError:
                latest = ''
            if latest and newer(latest, APP_VERSION):
                self.q.put(('update_note', f'v{latest} available - restart the dashboard to update'))
            time.sleep(6 * 3600)

    # ------------------------------------------------------------------ this PC (My PC tab)
    LOCAL_POWER = 'bash ~/ros2-remote/processingoffloadPC/power.sh'

    def poll_local(self):
        self._local_event.set()

    def local_poller(self):
        win_specs = ''
        while self.running:
            d = self.cfg.d['distro']
            sep = 'echo @@@'
            cmd = (f'test -d ~/.offload-agent && echo yes; {sep}; {self.LOCAL_POWER} role 2>/dev/null; {sep}; '
                   f'{self.LOCAL_POWER} schedule 2>/dev/null; {sep}; cat ~/.offload-agent/hwcheck.json 2>/dev/null; {sep}; '
                   f'cat ~/.offload-agent/specs 2>/dev/null; {sep}; grep -o "^POWERPLANT_NAME=[^ ]*" ~/.offload-agent/guardian.conf 2>/dev/null')
            code, out, _ = wsl(d, cmd, 60)
            parts = [x.strip() for x in out.split('@@@')] + [''] * 6
            info = {'installed': parts[0] == 'yes', 'role': parts[1], 'schedule': parts[2], 'hw': None,
                    'specs': parts[4], 'name': parts[5].replace('POWERPLANT_NAME=', '')}
            try:
                info['hw'] = json.loads(parts[3]) if parts[3] else None
            except ValueError:
                pass
            if not info['specs']:
                if not win_specs:   # no powerplant part on this PC: ask Windows directly
                    _, win_specs, _ = run(['powershell', '-NoProfile', '-Command',
                        "$g=(Get-CimInstance Win32_VideoController|Select -First 1).Name; $c=(Get-CimInstance Win32_Processor|Select -First 1).Name; "
                        "$r=[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB); \"$g | $c | $r GB\""], 30)
                info['specs'] = win_specs
            self.q.put(('local', info))
            self._local_event.wait(30)
            self._local_event.clear()

    def set_tab(self, t):
        self.tab = t
        if t == 'mypc':
            self.poll_local()

    def _local(self, action, label):
        code, out, err = wsl(self.cfg.d['distro'], f'{self.LOCAL_POWER} {action}', 120)
        self.log(f'--- {label} (this PC) ---')
        self.log(out or err or f'(exit {code})')
        self.poll_local()
        self.poll_now()

    def a_role(self, r):
        names = {'nodeuser': 'NodeUser', 'both': 'Both', 'processing': 'ProcessingNode'}
        self.task(None, 'role', lambda: self._local(f'role {r}', f'role -> {names[r]}'))

    def a_schedule(self, spec):
        self.task(None, 'schedule', lambda: self._local(f'schedule {shlex.quote(spec)}', 'availability schedule'))

    def a_schedule_custom(self):
        cur = self.local.get('schedule', '').splitlines()
        cur = cur[0].replace('Schedule: ', '') if cur else ''
        self.modal = {'kind': 'input', 'title': 'Availability schedule (when others may use this PC)',
                      'text': 'Rules separated by ;   e.g.  Mon-Fri 22:00-08:00; Sat-Sun 00:00-24:00\n'
                              'Outside the windows the PC is not shared and sleeps once nobody uses it.',
                      'value': '' if cur.startswith('always') else cur, 'ok': lambda v: self.a_schedule(v or 'clear')}

    def a_hwcheck_local(self):
        self.task(None, 'hardware check', lambda: self._local('hwcheck', 'hardware check'))

    def task(self, plant, label, fn):
        """Run an action in the background; plant.working shows it on the card."""
        if plant:
            if plant.working:
                self.log(f'{short(plant.host)} is busy with: {plant.working}'); return
            plant.working = label

        def runner():
            try:
                fn()
            except Exception as e:
                self.log(f'! {label} failed: {e}')
            finally:
                if plant:
                    self.q.put(('done', plant.host))
                self.poll_now()
        threading.Thread(target=runner, daemon=True).start()

    def process_queue(self):
        while True:
            try:
                kind, val = self.q.get_nowait()
            except queue.Empty:
                return
            if kind == 'log':
                self.log_lines.append(val)
                self.log_lines = self.log_lines[-2000:]
                self.log_scroll = 0
            elif kind == 'hosts':
                for h in val:
                    self.plants.setdefault(h, Plant(h))
                    if h not in self.cfg.d['known']:
                        self.cfg.d['known'].append(h); self.cfg.save()
                if not self.focus and self.plants:
                    self.focus = next(iter(self.plants))
            elif kind == 'plant':
                h, online, cap, status = val
                p = self.plants.setdefault(h, Plant(h))
                p.online = online
                if cap:
                    p.cap = cap
                    if cap.get('specs'):
                        self.cfg.plant(h)['specs'] = cap['specs']
                if status:
                    for line in status.splitlines():
                        if line.startswith('MAC:'):
                            self.cfg.plant(h)['mac'] = line[4:].strip()
                        elif line.startswith('WakeTopic:'):
                            self.cfg.plant(h)['wake_topic'] = line[10:].strip()
                        elif line.startswith('Specs:') and not cap:
                            self.cfg.plant(h)['specs'] = line[6:].strip()
                    self.cfg.save()
            elif kind == 'done':
                if val in self.plants:
                    self.plants[val].working = ''
            elif kind == 'ask_user':
                self.modal = {'kind': 'input', 'title': 'Your Ubuntu username on the powerplants',
                              'text': 'The username you created in Ubuntu when setting them up.',
                              'value': val, 'ok': self._set_user}
            elif kind == 'confirm':
                self.modal = val
            elif kind == 'update_note':
                self.update_note = val
            elif kind == 'local':
                self.local = val

    def _set_user(self, v):
        if re.fullmatch(r'[a-z_][a-z0-9_-]*', v):
            self.cfg.d['user'] = v; self.cfg.save(); self.log(f'Ubuntu username: {v}'); self.poll_now()

    def ask(self, title, text, on_yes, yes='Yes'):
        """Confirm dialog from any thread."""
        self.q.put(('confirm', {'kind': 'confirm', 'title': title, 'text': text, 'yes': yes, 'ok': on_yes}))

    # ------------------------------------------------------------------ actions
    def focused(self):
        return self.plants.get(self.focus)

    def _power(self, p, action, label=None, timeout=90, force_prompt=True):
        user = self.cfg.d['user']
        code, out, err = ssh(user, p.host, f'{POWER} {action}', timeout)
        self.log(f'--- {label or action} on {short(p.host)} ---')
        self.log(out or err or f'(exit {code})')
        if code == 2 and force_prompt:      # refused: busy
            verdict = next((l for l in out.splitlines() if l.startswith('VERDICT')), 'It looks busy.')
            self.ask(f'{short(p.host)} is busy', f'{verdict}\nDo "{label or action}" anyway?',
                     lambda: self.task(p, label or action, lambda: self._power(p, action + ' --force', label, timeout, False)))
        return code, out

    def a_start(self):
        p = self.focused()

        def go():
            if not reachable(p.host):
                self.log(f'{short(p.host)} is offline - waking it first...')
                if not self._wake(p):
                    return
                time.sleep(20)
            self._power(p, 'start', 'start', 180)
            self.log(f"Open a ROS shell on it: in Ubuntu type  use-powerplant {short(p.host)} && offloadpc")
        self.task(p, 'starting', go)

    def a_status(self):
        p = self.focused(); self.task(p, 'status', lambda: self._power(p, 'status'))

    def a_processes(self):
        p = self.focused(); self.task(p, 'checking processes', lambda: self._power(p, 'processes', 'running processes'))

    def a_sleep(self):
        p = self.focused(); self.task(p, 'sleep', lambda: self._power(p, 'sleep'))

    def a_sleep_after(self):
        p = self.focused(); self.task(p, 'sleep after finish', lambda: self._power(p, 'sleep-after-finish', 'sleep after finish'))

    def a_sleep_until(self):
        p = self.focused()

        def ok(v):
            if re.fullmatch(r'([01]?\d|2[0-3]):[0-5]\d', v):
                self.task(p, f'sleep until {v}', lambda: self._power(p, f'sleep-until {v}', f'sleep, wake at {v}'))
            else:
                self.log('Time must be HH:MM, e.g. 22:30')
        self.modal = {'kind': 'input', 'title': f'Sleep {short(p.host)} and wake it at', 'text': '24h time, e.g. 22:30', 'value': '07:00', 'ok': ok}

    def _wake(self, p):
        info = self.cfg.plant(p.host)
        mac, topic = info.get('mac'), info.get('wake_topic')
        if not mac:
            self.log(f"MAC of {short(p.host)} unknown - it must have been online once while the dashboard ran."); return False
        self.log(f'Waking {short(p.host)} ({mac})')
        if topic:
            ok = http_post_ntfy(topic, f'wake {mac}')
            self.log(f"  via wake listener (internet): {'sent' if ok else 'could not reach ntfy.sh'}")
        else:
            self.log('  no wake topic known (powerplant set up before wake listeners existed - rerun its SETUP)')
        self.log(f"  on this network: sent to {', '.join(send_wol_direct(mac))}")
        for i in range(36):
            if reachable(p.host):
                self.log(f'  {short(p.host)} is online!'); return True
            time.sleep(5)
        self.log('  not online after 3 min. Wake listener running on its home network? Wake-on-LAN on in its BIOS? Wired?')
        return False

    def a_wake(self):
        p = self.focused(); self.task(p, 'waking', lambda: self._wake(p))

    def a_resume(self):
        p = self.focused(); self.task(p, 'resume', lambda: self._power(p, 'resume'))

    def a_restart_ros(self):
        p = self.focused()
        self.task(p, 'restart ROS', lambda: self.log(ssh(self.cfg.d['user'], p.host,
                  'cd ~/ros2-remote/docker && docker compose restart && docker compose ps', 120)[1]))

    def a_shutdown(self):
        p = self.focused()
        self.ask(f'Shut down {short(p.host)}?', 'It shuts down in 60 s. Starting it again needs Wake-on-LAN or its power button.',
                 lambda: self.task(p, 'shut down', lambda: self._power(p, 'off', 'shut down')), yes='Shut down')

    def a_distribute(self):
        hosts = [h for h, p in self.plants.items() if p.ticked and p.online]
        user, distro = self.cfg.d['user'], self.cfg.d['distro']
        base = f'python3 ~/ros2-remote/cluster/distribute.py --user {user} --on {",".join(hosts)}'

        def plan():
            self.log(f'Planning ws/jobs.yaml over {len(hosts)} PC(s) by their hardware...')
            code, out, err = wsl(distro, base + ' --json', 180)
            try:
                d = json.loads(out.splitlines()[-1])
            except (ValueError, IndexError):
                self.log(out or err or 'distribute-work failed'); return
            self.log('--- distribution plan ---')
            for j in d['plan']:
                self.log(f"  {j['name']:<18} -> {short(j['host']):<10} {j['why']}")
            for w in d['warnings']:
                self.log(f'  ! {w}')
            counts = {}
            for j in d['plan']:
                counts[short(j['host'])] = counts.get(short(j['host']), 0) + 1
            self.ask(f"Start {len(d['plan'])} job(s)?", ', '.join(f'{h}: {n}' for h, n in counts.items()) +
                     '\nSync code, build, link ROS routers, start jobs (see log).',
                     lambda: self.task(None, 'distribute', lambda: self._stream(['wsl.exe', '-d', distro, '--exec', 'bash', '-lc', base + ' --yes'])),
                     yes='Start')
        if not hosts:
            self.log('Tick (checkbox) 2-3 online powerplants first.'); return
        self.task(None, 'plan', plan)

    def _stream(self, args):
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, creationflags=NOWIN)
        for line in proc.stdout:
            self.log(re.sub(r'\x1b\[[0-9;]*m', '', line.decode('utf-8', 'replace').rstrip()))
        proc.wait()

    def a_jobs(self):
        u, d = self.cfg.d['user'], self.cfg.d['distro']
        self.task(None, 'jobs', lambda: self.log(wsl(d, f'python3 ~/ros2-remote/cluster/distribute.py --user {u} --status', 120)[1] or 'no answer'))

    def a_stop_work(self):
        u, d = self.cfg.d['user'], self.cfg.d['distro']
        self.ask('Stop all distributed jobs?', 'On every powerplant.',
                 lambda: self.task(None, 'stop', lambda: self.log(wsl(d, f'python3 ~/ros2-remote/cluster/distribute.py --user {u} --stop all', 120)[1])),
                 yes='Stop all')

    def a_update_kit(self):
        self.ask('Update everything from GitHub?',
                 'Downloads the latest repo and updates: this PC\'s Ubuntu scripts, every online powerplant\n'
                 '(scripts, guardian, ROS image), the VS Code extension and the Claude skill.',
                 lambda: self.task(None, 'update', self._update_kit), yes='Update')

    def _update_kit(self):
        user, distro = self.cfg.d['user'], self.cfg.d['distro']
        self.log('--- update kit ---')
        data = http_get(ZIP, 60)
        if not data:
            self.log('Download failed.'); return
        tmp = tempfile.mkdtemp(prefix='badger_')
        zipfile.ZipFile(io_bytes(data)).extractall(tmp)
        root = os.path.join(tmp, os.listdir(tmp)[0])
        self.log(f'Downloaded {len(data) // 1024} KB')
        # 1) this PC's Ubuntu
        code, me, _ = wsl(distro, 'whoami', 20)
        if code == 0 and me:
            r = subprocess.run(f'tar -C "{root}" --exclude=.git -cf - . | wsl.exe -d {distro} --exec tar -C /home/{me}/ros2-remote -xf -',
                               shell=True, capture_output=True, creationflags=NOWIN)
            wsl(distro, "find ~/ros2-remote -name '*.sh' -exec sed -i 's/\\r$//' {} +", 60)
            self.log(f"  this PC's Ubuntu: {'updated' if r.returncode == 0 else 'FAILED'}")
        # 2) powerplants
        for h, p in self.plants.items():
            if not p.online:
                self.log(f'  {short(h)}: offline - skipped'); continue
            code, out, err = wsl(distro, f"rsync -az -e 'ssh -o BatchMode=yes -o ConnectTimeout=6' "
                                         f"~/ros2-remote/processingoffloadPC ~/ros2-remote/docker ~/ros2-remote/cluster "
                                         f"~/ros2-remote/wake-listener {user}@{h}:ros2-remote/ && "
                                         f"ssh -o BatchMode=yes {user}@{h} \"find ~/ros2-remote -name '*.sh' -exec sed -i 's/\\r$//' {{}} +; "
                                         f"pkill -f processingoffloadPC/guardian.sh; cd ~/ros2-remote/docker && docker compose up -d --build >/dev/null 2>&1 && echo ok\"", 900)
            self.log(f"  {short(h)}: {'updated' if 'ok' in out else 'FAILED ' + (err or out)[-160:]}")
        # 3) VS Code extension
        vsix = sorted(f for f in os.listdir(os.path.join(root, 'vscode-extension')) if f.endswith('.vsix'))
        code_cli = shutil.which('code') or shutil.which('code.cmd')
        if vsix and code_cli:
            c, _, _ = run([code_cli, '--install-extension', os.path.join(root, 'vscode-extension', vsix[-1]), '--force'], 120)
            self.log(f"  VS Code extension {vsix[-1]}: {'installed' if c == 0 else 'failed'}")
        # 4) Claude skill
        src = os.path.join(root, 'claude-skill', 'computing-power-network')
        if os.path.isdir(src):
            dst = os.path.join(os.path.expanduser('~'), '.claude', 'skills', 'computing-power-network')
            shutil.rmtree(dst, ignore_errors=True); shutil.copytree(src, dst)
            self.log('  Claude skill: updated')
        shutil.rmtree(tmp, ignore_errors=True)
        self.log('Update finished. (The dashboard itself updates when you restart it.)')

    # ------------------------------------------------------------------ drawing
    def draw_text(self, text, font, color, pos, maxw=None):
        if maxw:
            text = ellipsize(font, text, maxw)
        surf = font.render(text, True, color)
        self.screen.blit(surf, pos)
        return surf.get_width()

    def draw_bar(self, x, y, w, frac, color, label):
        pygame.draw.rect(self.screen, (24, 26, 34), (x, y, w, 8), border_radius=4)
        frac = max(0.0, min(1.0, frac))
        if frac > 0:
            pygame.draw.rect(self.screen, color, (x, y, max(6, int(w * frac)), 8), border_radius=4)
        self.draw_text(label, self.f_small, DIM, (x, y + 10), w)

    def draw_card(self, p, rect):
        mouse = pygame.mouse.get_pos()
        hi = rect.collidepoint(mouse)
        col = CARD_SEL if p.host == self.focus else (CARD_HI if hi else CARD)
        pygame.draw.rect(self.screen, col, rect, border_radius=10)
        if p.host == self.focus:
            pygame.draw.rect(self.screen, BLUE, rect, 2, border_radius=10)
        x, y = rect.x + 14, rect.y + 12
        # checkbox (for distribute)
        cb = pygame.Rect(x, y + 2, 18, 18)
        pygame.draw.rect(self.screen, FAINT, cb, 2, border_radius=4)
        if p.ticked:
            pygame.draw.rect(self.screen, GREEN, cb.inflate(-6, -6), border_radius=2)
        p.cb_rect = cb
        pygame.draw.circle(self.screen, p.dot, (x + 34, y + 11), 7)
        info = self.cfg.plant(p.host)
        specs = (p.cap.get('specs') or info.get('specs') or '').split('|')
        gpu = specs[0].strip() if specs and specs[0].strip() else short(p.host)
        self.draw_text(gpu, self.f_mid, TEXT, (x + 48, y), rect.w - 260)
        if gpu != short(p.host):
            self.draw_text(short(p.host), self.f_small, DIM, (rect.right - 150, y + 3), 136)
        rest = ' · '.join(s.strip() for s in specs[1:] if s.strip())
        self.draw_text(rest or p.host, self.f_small, DIM, (x + 48, y + 24), rect.w - 80)
        y2 = y + 48
        bw = (rect.w - 28 - 30) // 4
        c = p.cap
        if p.online and c:
            vt, vu = c.get('vram_total_mb', 0) or 1, c.get('vram_used_mb', 0)
            th = c.get('threads', 1) or 1
            rt, ra = c.get('ram_total_gb', 0) or 1, c.get('ram_avail_gb', 0)
            self.draw_bar(x, y2, bw, c.get('gpu_util', 0) / 100, GREEN, f"GPU {c.get('gpu_util', 0):.0f}%")
            self.draw_bar(x + (bw + 10), y2, bw, vu / vt, BLUE, f'VRAM {vu / 1024:.1f}/{vt / 1024:.0f} GB')
            self.draw_bar(x + 2 * (bw + 10), y2, bw, c.get('load1', 0) / th, ORANGE, f"CPU {c.get('load1', 0):.1f}/{th}")
            self.draw_bar(x + 3 * (bw + 10), y2, bw, (rt - ra) / rt, YELLOW, f'RAM {rt - ra:.0f}/{rt:.0f} GB')
            idle = c.get('owner_idle_s', -1)
            owner = 'owner: unknown' if idle < 0 else ('owner ACTIVE now' if idle < 600 else f'owner away {idle // 60} min' if idle < 7200 else f'owner away {idle // 3600} h')
            bits = [owner, f"{c.get('jobs_running', 0)} job(s)"]
            if c.get('paused'):
                bits.insert(0, 'JOB PAUSED (owner using it)')
            if not c.get('guardian', True):
                bits.append('guardian off')
            if c.get('verified') is True:
                bits.append(f"hardware verified {c.get('hw_age_h', 0):.0f} h ago")
            elif c.get('verified') is False:
                bits.insert(0, 'HARDWARE NOT VERIFIED')
            if c.get('available') is False:
                bits.insert(0, 'NOT SHARED (NodeUser)' if c.get('role') == 'nodeuser' else 'outside its schedule')
            self.draw_text('  ·  '.join(bits), self.f_small, YELLOW if (c.get('paused') or 0 <= idle < 600) else DIM, (x, y2 + 30), rect.w - 28)
        elif p.online:
            self.draw_text('online - no details (set your username, or press Update kit)', self.f_small, DIM, (x, y2 + 6), rect.w - 28)
        elif p.online is False:
            self.draw_text('offline (asleep or off)  -  Wake works from any network with a wake listener', self.f_small, RED, (x, y2 + 6), rect.w - 28)
        else:
            self.draw_text('checking...', self.f_small, FAINT, (x, y2 + 6))
        if p.working:
            w = self.f_small.size(p.working)[0] + 16
            r = pygame.Rect(rect.right - w - 12, rect.bottom - 26, w, 20)
            pygame.draw.rect(self.screen, ORANGE, r, border_radius=10)
            self.draw_text(p.working, self.f_small, BG, (r.x + 8, r.y + 2))

    def layout_buttons(self, buttons, x, y, w, cols=2, h=34, gap=8):
        bw = (w - gap * (cols - 1)) // cols
        for i, b in enumerate(buttons):
            b.rect = pygame.Rect(x + (i % cols) * (bw + gap), y + (i // cols) * (h + gap), bw, h)
        rows = (len(buttons) + cols - 1) // cols
        return y + rows * (h + gap)

    def draw_button(self, b):
        p = self.focused()
        if b.needs == 'focus':
            b.enabled = bool(p and p.online and self.cfg.d['user'])
        elif b.needs == 'focus_any':
            b.enabled = bool(p and self.cfg.plant(p.host).get('mac'))
        elif b.needs == 'ticked':
            b.enabled = any(q.ticked and q.online for q in self.plants.values()) and bool(self.cfg.d['user'])
        elif b.needs == 'local':
            b.enabled = bool(self.local.get('installed'))
        elif b.needs == 'never':
            b.enabled = False
        else:
            b.enabled = True
        hi = b.rect.collidepoint(pygame.mouse.get_pos()) and b.enabled
        on = b.active() if b.active else True
        base = (b.color if on else (62, 66, 80)) if b.enabled else (44, 47, 58)
        col = tuple(min(255, int(c * (1.15 if hi else 0.85))) for c in base)
        pygame.draw.rect(self.screen, col, b.rect, border_radius=8)
        tc = (BG if on else TEXT) if b.enabled else FAINT
        t = ellipsize(self.f, b.label, b.rect.w - 12)
        tw, th = self.f.size(t)
        self.draw_text(t, self.f, tc, (b.rect.centerx - tw // 2, b.rect.centery - th // 2))

    def draw(self):
        W, H = self.screen.get_size()
        self.screen.fill(BG)
        # top bar
        pygame.draw.rect(self.screen, PANEL, (0, 0, W, 60))
        pygame.draw.circle(self.screen, ORANGE, (30, 30), 12)
        for k in range(3):     # tiny radiation trefoil
            ang = k * 2.0944
            pygame.draw.circle(self.screen, BG, (30 + int(6 * math.cos(ang)), 30 + int(6 * math.sin(ang))), 4)
        tw = self.draw_text('Computing Power Network', self.f_big, TEXT, (52, 14))
        online = sum(1 for p in self.plants.values() if p.online)
        sub = f"{online}/{len(self.plants)} online   ·   user: {self.cfg.d['user'] or '?'}   ·   v{APP_VERSION}"
        if self.update_note:
            sub += f'   ·   {self.update_note}'
        self.draw_text(sub, self.f_small, DIM, (52 + tw + 24, 23), W - (52 + tw + 24) - 230)
        tx = W - 214
        for b in self.top_buttons:
            b.rect = pygame.Rect(tx, 13, 98, 34); tx += 106
            self.draw_button(b)
        # tabs
        tx = 16
        for b in self.tab_buttons:
            b.rect = pygame.Rect(tx, 70, 130, 32); tx += 138
            self.draw_button(b)
        TOP = 112
        if self.tab == 'network':
            self.draw_network(W, H, TOP)
        else:
            self.draw_mypc(W, H, TOP)
        if self.modal:
            self.draw_modal()
        pygame.display.flip()

    def draw_network(self, W, H, TOP):
        # left: cards
        lw = int(W * 0.56)
        area = pygame.Rect(16, TOP, lw - 24, H - TOP - 16)
        self.card_area = area
        self.screen.set_clip(area)
        y = area.y - self.card_scroll
        self.card_rects = {}
        if not self.plants:
            self.draw_text('No powerplants found yet. Is Tailscale signed in? Set up one with SETUP-processingoffloadPC.cmd.',
                           self.f, DIM, (area.x, area.y + 10), area.w)
        for h, p in self.plants.items():
            r = pygame.Rect(area.x, y, area.w, 116)
            self.draw_card(p, r)
            self.card_rects[h] = r
            y += 126
        self.screen.set_clip(None)
        # right panel
        rx = lw + 4
        rw = W - rx - 16
        pygame.draw.rect(self.screen, PANEL, (rx, TOP, rw, H - TOP - 16), border_radius=12)
        p = self.focused()
        self.draw_text(f"Selected: {short(p.host) if p else '-'}", self.f_mid, TEXT, (rx + 16, TOP + 12), rw - 32)
        y = self.layout_buttons(self.buttons, rx + 16, TOP + 42, rw - 32)
        for b in self.buttons:
            self.draw_button(b)
        ticked = sum(1 for q in self.plants.values() if q.ticked)
        self.draw_text(f'Several PCs  (ticked: {ticked})  -  splits ws/jobs.yaml by hardware', self.f_mid, TEXT, (rx + 16, y + 6), rw - 32)
        y = self.layout_buttons(self.multi_buttons, rx + 16, y + 34, rw - 32, cols=3)
        for b in self.multi_buttons:
            self.draw_button(b)
        self.draw_log(pygame.Rect(rx + 16, y + 8, rw - 32, H - 16 - y - 24))

    def draw_log(self, log_rect):
        self.log_rect = log_rect
        pygame.draw.rect(self.screen, (12, 13, 18), log_rect, border_radius=8)
        lh = self.f_mono.get_linesize()
        visible = max(1, (log_rect.h - 12) // lh)
        maxw_chars = max(10, (log_rect.w - 16) // max(1, self.f_mono.size('M')[0]))
        wrapped = []
        for line in self.log_lines[-600:]:
            wrapped += [line[i:i + maxw_chars] for i in range(0, max(1, len(line)), maxw_chars)] or ['']
        self.log_scroll = max(0, min(self.log_scroll, max(0, len(wrapped) - visible)))
        start = max(0, len(wrapped) - visible - self.log_scroll)
        self.screen.set_clip(log_rect)
        for i, line in enumerate(wrapped[start:start + visible]):
            col = YELLOW if line.startswith(('!', '  !', 'VERDICT: BUSY')) else GREEN if 'VERDICT: IDLE' in line or line.endswith('online!') else TEXT if line.startswith('---') else DIM
            self.screen.blit(self.f_mono.render(line, True, col), (log_rect.x + 8, log_rect.y + 6 + i * lh))
        self.screen.set_clip(None)

    def draw_section(self, title, x, y, w):
        self.draw_text(title, self.f_mid, TEXT, (x, y), w)
        return y + 28

    def draw_mypc(self, W, H, TOP):
        L = self.local
        lw = int(W * 0.5)
        left = pygame.Rect(16, TOP, lw - 24, H - TOP - 16)
        right = pygame.Rect(lw + 4, TOP, W - lw - 20, H - TOP - 16)
        for r in (left, right):
            pygame.draw.rect(self.screen, PANEL, r, border_radius=12)
        x, w = left.x + 18, left.w - 36
        y = self.draw_section('This PC', x, left.y + 14, w)
        name = L.get('name') or socket.gethostname()
        self.draw_text(name, self.f, TEXT, (x, y), w); y += 22
        specs = [p.strip() for p in (L.get('specs') or 'reading hardware...').split('|')]
        for label, val in zip(('GPU', 'CPU', 'RAM'), specs + ['', '', '']):
            self.draw_text(f'{label}:  {val}', self.f, DIM, (x, y), w); y += 20
        hw = L.get('hw')
        if hw:
            age = (time.time() - hw.get('time', 0)) / 3600
            col = GREEN if hw.get('verified') else RED
            badge = f"{'VERIFIED' if hw.get('verified') else 'NOT VERIFIED'}  ·  checked {age:.0f} h ago"
            bw = self.f_small.size(badge)[0] + 18
            pygame.draw.rect(self.screen, col, (x, y + 4, bw, 22), border_radius=11)
            self.draw_text(badge, self.f_small, BG, (x + 9, y + 7)); y += 34
        elif L.get('installed') is False:
            self.draw_text('Sharing parts not installed here - run SETUP-everything.cmd to enable roles.', self.f_small, YELLOW, (x, y + 4), w); y += 30
        else:
            y += 8
        y = self.draw_section('Role', x, y + 10, w)
        y = self.layout_buttons(self.role_buttons, x, y, w, cols=3)
        for b in self.role_buttons:
            self.draw_button(b)
        desc = {'nodeuser': 'NodeUser: only USES the network (laptops). This PC is not shared.',
                'both': 'Both: uses the network AND shares this PC when it is available.',
                'processing': 'ProcessingNode: only SHARES this PC with your other PCs.'}.get(L.get('role'), 'Role unknown.')
        self.draw_text(desc, self.f_small, DIM, (x, y), w); y += 30
        y = self.draw_section('Network', x, y + 4, w)
        y = self.layout_buttons(self.mode_buttons, x, y, w, cols=2)
        for b in self.mode_buttons:
            self.draw_button(b)
        for line, col in (('Closed circuit: only PCs signed in to YOUR Tailscale account', DIM),
                          ('(your Google login) can see and use each other.', DIM),
                          ('Global: share with everyone, earn credits, spend them to use', FAINT),
                          ('others - planned, not available yet.', FAINT)):
            self.draw_text(line, self.f_small, col, (x, y), w); y += 18
        # right column: schedule + checker + log
        x, w = right.x + 18, right.w - 36
        y = self.draw_section('Availability schedule (when others may use this PC)', x, right.y + 14, w)
        for line in (L.get('schedule') or 'unknown').splitlines()[:2]:
            self.draw_text(line, self.f, TEXT if line.startswith('Schedule') else DIM, (x, y), w); y += 20
        y = self.layout_buttons(self.sched_buttons, x, y + 6, w, cols=2)
        for b in self.sched_buttons:
            self.draw_button(b)
        self.draw_text('Outside the window the PC is not shared and sleeps once nobody uses it; it wakes itself at the start.',
                       self.f_small, DIM, (x, y), w); y += 26
        y = self.draw_section('System checker (proves the hardware is real)', x, y + 6, w)
        if hw:
            g, c, r = hw.get('gpu', {}), hw.get('cpu', {}), hw.get('ram', {})
            rows = [(g.get('ok'), f"GPU  {g.get('cuda_name', '?')}: {g.get('allocated_mb', 0) / 1024:.1f} GB VRAM allocated, {g.get('copy_gb_s', '?')} GB/s"),
                    (c.get('ok'), f"CPU  {c.get('threads', '?')} threads, scaling x{c.get('scaling', '?')} ({c.get('sha256_mb_s_all', '?')} MB/s SHA-256)"),
                    (r.get('ok'), f"RAM  {r.get('tested_gb', '?')} GB written at {r.get('write_gb_s', '?')} GB/s")]
            for ok, text in rows:
                pygame.draw.circle(self.screen, GREEN if ok else RED, (x + 6, y + 9), 5)
                self.draw_text(text, self.f_small, DIM, (x + 18, y + 1), w - 18); y += 20
        else:
            self.draw_text('Not checked yet.', self.f_small, DIM, (x, y)); y += 20
        self.draw_text('Runs by itself once a day while nobody uses the PC (~10 s).', self.f_small, FAINT, (x, y + 2), w); y += 24
        y = self.layout_buttons(self.check_buttons, x, y, w, cols=2)
        for b in self.check_buttons:
            self.draw_button(b)
        self.draw_log(pygame.Rect(x, y + 4, w, right.bottom - y - 18))

    def draw_modal(self):
        W, H = self.screen.get_size()
        shade = pygame.Surface((W, H), pygame.SRCALPHA); shade.fill((0, 0, 0, 160)); self.screen.blit(shade, (0, 0))
        m = self.modal
        lines = m.get('text', '').splitlines()
        box = pygame.Rect(0, 0, 560, 150 + 20 * len(lines)); box.center = (W // 2, H // 2)
        pygame.draw.rect(self.screen, PANEL, box, border_radius=12)
        pygame.draw.rect(self.screen, BLUE, box, 2, border_radius=12)
        self.draw_text(m['title'], self.f_mid, TEXT, (box.x + 20, box.y + 16), box.w - 40)
        for i, l in enumerate(lines):
            self.draw_text(l, self.f, DIM, (box.x + 20, box.y + 48 + i * 20), box.w - 40)
        yb = box.bottom - 50
        if m['kind'] == 'input':
            inp = pygame.Rect(box.x + 20, yb - 46, box.w - 40, 34)
            pygame.draw.rect(self.screen, (12, 13, 18), inp, border_radius=6)
            cursor = '|' if int(time.time() * 2) % 2 else ''
            self.draw_text(m['value'] + cursor, self.f, TEXT, (inp.x + 10, inp.y + 7), inp.w - 20)
        m['yes_rect'] = pygame.Rect(box.right - 250, yb, 110, 34)
        m['no_rect'] = pygame.Rect(box.right - 130, yb, 110, 34)
        for r, label, col in ((m['yes_rect'], m.get('yes', 'OK'), GREEN), (m['no_rect'], 'Cancel', (70, 74, 88))):
            pygame.draw.rect(self.screen, col, r, border_radius=8)
            tw = self.f.size(label)[0]
            self.draw_text(label, self.f, BG, (r.centerx - tw // 2, r.y + 8))

    # ------------------------------------------------------------------ events
    def close_modal(self, accept):
        m, self.modal = self.modal, None
        if accept:
            if m['kind'] == 'input':
                m['ok'](m['value'].strip())
            else:
                m['ok']()

    def handle(self, e):
        if e.type == pygame.QUIT:
            self.running = False
        elif self.modal:
            if e.type == pygame.KEYDOWN:
                if e.key == pygame.K_RETURN:
                    self.close_modal(True)
                elif e.key == pygame.K_ESCAPE:
                    self.close_modal(False)
                elif self.modal['kind'] == 'input' and e.key == pygame.K_BACKSPACE:
                    self.modal['value'] = self.modal['value'][:-1]
            elif e.type == pygame.TEXTINPUT and self.modal['kind'] == 'input':
                self.modal['value'] += e.text
            elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
                if self.modal.get('yes_rect') and self.modal['yes_rect'].collidepoint(e.pos):
                    self.close_modal(True)
                elif self.modal.get('no_rect') and self.modal['no_rect'].collidepoint(e.pos):
                    self.close_modal(False)
        elif e.type == pygame.MOUSEWHEEL:
            pos = pygame.mouse.get_pos()
            if getattr(self, 'log_rect', None) and self.log_rect.collidepoint(pos):
                self.log_scroll += e.y * 3
            elif getattr(self, 'card_area', None) and self.card_area.collidepoint(pos):
                self.card_scroll = max(0, self.card_scroll - e.y * 40)
        elif e.type == pygame.MOUSEBUTTONDOWN and e.button == 1:
            visible = self.top_buttons + self.tab_buttons + (
                self.buttons + self.multi_buttons if self.tab == 'network'
                else self.role_buttons + self.mode_buttons + self.sched_buttons + self.check_buttons)
            for b in visible:
                if b.rect.collidepoint(e.pos) and b.enabled:
                    b.action(); return
            if self.tab != 'network':
                return
            for h, r in getattr(self, 'card_rects', {}).items():
                if r.collidepoint(e.pos) and self.card_area.collidepoint(e.pos):
                    p = self.plants[h]
                    if getattr(p, 'cb_rect', None) and p.cb_rect.inflate(10, 10).collidepoint(e.pos):
                        p.ticked = not p.ticked
                    else:
                        self.focus = h; self.cfg.d['focus'] = h; self.cfg.save()
                    return

    def loop(self, max_frames=None, screenshot=None):
        clock = pygame.time.Clock()
        frames = 0
        while self.running:
            self.process_queue()
            for e in pygame.event.get():
                self.handle(e)
            self.draw()
            clock.tick(30)
            frames += 1
            if max_frames and frames >= max_frames:
                if screenshot:
                    pygame.image.save(self.screen, screenshot)
                break
        self.running = False
        pygame.quit()


def io_bytes(b):
    import io
    return io.BytesIO(b)


def http_post_ntfy(topic, message):
    try:
        req = urllib.request.Request(f'https://ntfy.sh/{topic}', data=message.encode(), method='POST',
                                     headers={'User-Agent': 'ComputingPowerNetwork'})
        with urllib.request.urlopen(req, timeout=10) as r:
            return 200 <= r.status < 300
    except Exception:
        return False


def main(updated_from=None, max_frames=None, screenshot=None):
    Dashboard(updated_from).loop(max_frames, screenshot)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""distribute-work: spread ROS 2 jobs over several nuclear powerplants, by their hardware.

Runs on YOUR PC (inside Ubuntu/WSL). Reads a jobs file (default ~/ros2-remote/ws/jobs.yaml), asks
every selected powerplant for its hardware and current load, and assigns each job:
  * GPU jobs  -> the PC whose GPU has the most power left (GPU tier x free VRAM, current GPU jobs)
  * CPU jobs  -> the PC with the most free CPU threads left
  * PCs whose owner is using them right now count much less (the guardian would pause the job)
Then (after you confirm) it syncs your code, builds it on each PC, links their ROS routers so all
nodes see each other, and starts every job in its own tmux session (job_<name>) on its PC.

    distribute-work                         # all reachable powerplants, ws/jobs.yaml
    distribute-work --on 4090,desktop       # only these
    distribute-work my_jobs.yaml --plan     # just show who would run what
    cluster-status                          # what runs where
    stop-work [NAME]                        # stop all (or one) distributed jobs
    job-log NAME                            # last lines of a job's output

Note: this spreads separate jobs (nodes / launch files / scripts). It doesn't split ONE program
across PCs - that program must support it itself (e.g. PyTorch DDP), and home internet is slow for that.
"""
import argparse
import base64
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys

HOME = os.path.expanduser('~')
REPO = os.path.join(HOME, 'ros2-remote')
STATE = os.path.join(HOME, '.offloadpc-cluster.json')
PREFIX = 'processingoffloadpc'
POWER = 'bash ~/ros2-remote/processingoffloadPC/power.sh'

# Relative GPU power (RTX 4090 = 100). Rough gaming/compute averages; good enough to rank PCs.
GPU_TIERS = [
    ('5090', 130), ('4090', 100), ('5080', 85), ('4080 super', 78), ('4080', 75), ('5070 ti', 70),
    ('3090 ti', 65), ('4070 ti super', 65), ('4070 ti', 60), ('5070', 58), ('3090', 58), ('3080 ti', 55),
    ('4070 super', 55), ('3080', 50), ('4070', 45), ('5060 ti', 42), ('3070 ti', 40), ('3070', 37),
    ('4060 ti', 36), ('5060', 35), ('2080 ti', 35), ('3060 ti', 32), ('4060', 30), ('2080 super', 28),
    ('2080', 26), ('3060', 26), ('1080 ti', 25), ('2070 super', 25), ('2070', 22), ('1080', 20),
    ('2060', 18), ('1070 ti', 18), ('1070', 16), ('3050', 15), ('1660', 12), ('1060', 10), ('1650', 8),
    ('7900 xtx', 80), ('7900 xt', 70), ('9070 xt', 70), ('7800 xt', 50), ('6800 xt', 48), ('7700 xt', 42),
]


def gpu_score(name, vram_mb):
    n = (name or '').lower()
    if not n:
        return 0.0
    score = next((s for key, s in GPU_TIERS if key in n), None)
    if score is None:
        score = max(5.0, vram_mb / 1024 * 3)       # unknown GPU: guess from its memory
    if 'laptop' in n or 'mobile' in n:
        score *= 0.6
    return float(score)


def full_name(n):
    n = n.strip()
    return n if n.startswith(PREFIX) or n == 'local' else f'{PREFIX}-{n}'


def short(n):
    return 'main' if n == PREFIX else n.replace(PREFIX + '-', '')


# ---------------- talking to powerplants ----------------
def ssh(user, host, cmd, timeout=30):
    try:
        r = subprocess.run(['ssh', '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6',
                            '-o', 'StrictHostKeyChecking=accept-new', f'{user}@{host}', cmd],
                           capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, '', 'timeout'


def discover():
    names = set()
    import glob   # Windows Tailscale: PATH, C:/Program Files, or X:/Programs on the kit's drive
    ts = next((p for p in [shutil.which('tailscale.exe') or '', '/mnt/c/Program Files/Tailscale/tailscale.exe']
               + glob.glob('/mnt/?/Programs/Tailscale/tailscale.exe') if p and os.path.exists(p)), '')
    if ts:
        try:
            out = subprocess.run([ts, 'status'], capture_output=True, text=True, timeout=10).stdout
            names.update(l.split()[1] for l in out.splitlines() if len(l.split()) > 1 and l.split()[1].startswith(PREFIX))
        except Exception:
            pass
    for f in ('.offloadpc-known', '.offloadpc-target'):
        try:
            names.update(l.strip() for l in open(os.path.join(HOME, f)) if l.strip() and l.strip() != 'local')
        except OSError:
            pass
    return sorted(names)


def get_capacity(user, host):
    code, out, err = ssh(user, host, f'{POWER} capacity', timeout=40)
    if code != 0:
        return host, None, (err or out or f'exit {code}')[:200]
    try:
        return host, json.loads(out.splitlines()[-1]), None
    except (ValueError, IndexError):
        return host, None, 'bad answer: ' + out[:120]


# ---------------- scheduling ----------------
def load_jobs(path):
    with open(path) as f:
        text = f.read()
    if path.endswith('.json'):
        data = json.loads(text)
    else:
        try:
            import yaml
        except ImportError:
            sys.exit('PyYAML missing: sudo apt install python3-yaml   (or use a .json jobs file)')
        data = yaml.safe_load(text)
    jobs = data.get('jobs') if isinstance(data, dict) else data
    if not jobs:
        sys.exit(f'No jobs in {path}')
    out = []
    for j in jobs:
        name, run = str(j.get('name', '')), j.get('run')
        if not re.fullmatch(r'[A-Za-z0-9_-]+', name) or not run:
            sys.exit(f'Every job needs a name (letters, digits, - _) and a run command: {j}')
        gpu = bool(j.get('gpu', False))
        out.append({
            'name': name, 'run': str(run), 'gpu': gpu,
            'vram_gb': float(j.get('vram_gb', 2 if gpu else 0)), 'cpu': float(j.get('cpu', 1)),
            'ram_gb': float(j.get('ram_gb', 1)), 'weight': float(j.get('weight', 1)),
            # "pin: desktop" (YAML reads a bare "on:" key as True, so accept that spelling too)
            'on': full_name(str(pin)) if (pin := j.get('pin') or j.get('on') or j.get(True)) else None,
        })
    names = [j['name'] for j in out]
    if len(names) != len(set(names)):
        sys.exit('Job names must be unique')
    return out


def schedule(jobs, caps):
    """Greedy weighted balancing. caps: {host: capacity dict}. Returns (plan, warnings)."""
    hosts = {}
    for h, c in caps.items():
        owner_active = 0 <= c.get('owner_idle_s', -1) < 600 or c.get('paused')
        hosts[h] = {
            'cap': c,
            'gpu_power': gpu_score(c.get('gpu'), c.get('vram_total_mb', 0)),
            'vram_left': max(0.0, c.get('vram_total_mb', 0) - c.get('vram_used_mb', 0)) / 1024,
            'threads_free': max(0.5, c.get('threads', 1) - c.get('load1', 0)),
            'ram_left': c.get('ram_avail_gb', 0),
            'factor': 0.3 if owner_active else 1.0,      # avoid PCs someone is using right now
            'owner_active': owner_active,
            'gpu_load': c.get('gpu_util', 0) / 100 * 2,   # already-busy GPU counts as ~2 weight units at 100 %
            'cpu_load': 0.0, 'jobs': [],
        }
    plan, warnings = [], []
    order = sorted(jobs, key=lambda j: (j['on'] is None, not j['gpu'], -j['vram_gb'], -j['cpu'], -j['weight']))
    for j in order:
        cands = [j['on']] if j['on'] else list(hosts)
        cands = [h for h in cands if h in hosts]
        if j['on'] and not cands:  # pinned to a PC that isn't selected
            warnings.append(f"{j['name']}: pinned to {j['on']}, which isn't selected/reachable - skipped")
            continue

        def fits(h):
            s = hosts[h]
            if j['gpu'] and (s['gpu_power'] <= 0 or s['vram_left'] < j['vram_gb']):
                return False
            return s['ram_left'] >= j['ram_gb']

        ok = [h for h in cands if fits(h)]
        if not ok:
            ok = [h for h in cands if (hosts[h]['gpu_power'] > 0 or not j['gpu'])]
            if not ok:
                warnings.append(f"{j['name']}: no selected PC has a GPU - skipped")
                continue
            warnings.append(f"{j['name']}: doesn't fit anywhere comfortably (VRAM/RAM) - placed on the best PC anyway")

        def cost(h):
            s = hosts[h]
            if j['gpu']:
                return (s['gpu_load'] + j['weight']) / (s['gpu_power'] * s['factor'])
            return (s['cpu_load'] + j['cpu'] * j['weight']) / (s['threads_free'] * s['factor'])

        best = min(ok, key=cost)
        if j['on']:
            why_pin = ' (pinned)'
        else:
            why_pin = ''
        s = hosts[best]
        if j['gpu']:
            s['gpu_load'] += j['weight']; s['vram_left'] -= j['vram_gb']
            why = f"GPU job -> {(s['cap'].get('gpu') or 'GPU').replace('NVIDIA ', '').replace('GeForce ', '')} (power {s['gpu_power']:.0f}, {max(0, s['vram_left'] + j['vram_gb']):.1f} GB VRAM free)"
        else:
            s['cpu_load'] += j['cpu'] * j['weight']
            why = f"CPU job -> {s['threads_free']:.1f} free threads"
        s['ram_left'] -= j['ram_gb']
        why += why_pin
        if s['owner_active']:
            why += ' [owner using it - may be paused]'
        s['jobs'].append(j['name'])
        plan.append({**j, 'host': best, 'why': why})
    return plan, warnings


def print_plan(plan, caps, warnings, failed):
    print('\nNuclear powerplants:')
    for h, c in caps.items():
        dot = '\033[33m●\033[0m' if (0 <= c.get('owner_idle_s', -1) < 600 or c.get('paused')) else '\033[32m●\033[0m'
        print(f"  {dot} {short(h):<14} {c.get('specs') or c.get('gpu')}  | GPU {c.get('gpu_util', 0):.0f}%, "
              f"{(c.get('vram_total_mb', 0) - c.get('vram_used_mb', 0)) / 1024:.1f} GB VRAM free, "
              f"load {c.get('load1', 0):.1f}/{c.get('threads')} threads, {c.get('ram_avail_gb')} GB RAM free")
    for h, e in failed.items():
        print(f"  \033[31m●\033[0m {short(h):<14} not used: {e}")
    print('\nPlan:')
    for p in plan:
        print(f"  {p['name']:<20} -> {short(p['host']):<14} {p['why']}")
    for w in warnings:
        print(f'  ! {w}')
    print()


# ---------------- doing it ----------------
def has_packages(src):
    for root, _dirs, files in os.walk(src):
        if 'package.xml' in files:
            return True
    return False


def run_parallel(fn, items):
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        return list(ex.map(fn, items))


def execute(plan, user, src, do_sync, do_build):
    used = sorted({p['host'] for p in plan})
    if do_sync:
        if not os.path.isdir(src) or not has_packages(src):
            print(f'Code sync skipped: no ROS packages in {src} (using the code already on each PC).')
        elif not shutil.which('rsync'):
            print('Code sync skipped: rsync not installed (sudo apt install rsync).')
        else:
            def sync(h):
                r = subprocess.run(['rsync', '-az', '--exclude', 'build', '--exclude', 'install', '--exclude', 'log',
                                    '-e', 'ssh -o BatchMode=yes -o ConnectTimeout=6', src.rstrip('/') + '/',
                                    f'{user}@{h}:ros2-remote/ws/src/'], capture_output=True, text=True)
                return h, r.returncode, r.stderr.strip()
            for h, code, err in run_parallel(sync, used):
                print(f"  sync -> {short(h)}: {'ok' if code == 0 else 'FAILED ' + err[:150]}")
    if do_build:
        print('Building on each PC (colcon build)...')
        build = ("cd ~/ros2-remote/docker && docker compose exec -T dev bash -lc "
                 "'source /opt/ros/jazzy/setup.bash && cd /ws && colcon build --symlink-install 2>&1 | tail -n 5'")
        for h, (code, out, err) in zip(used, run_parallel(lambda h: ssh(user, h, build, timeout=3600), used)):
            print(f"  build on {short(h)}: {'ok' if code == 0 else 'FAILED'}")
            if code != 0:
                print('    ' + (out or err)[-400:].replace('\n', '\n    '))
                sys.exit('Fix the build error and run distribute-work again.')
    print('Linking ROS routers so nodes on all PCs see each other...')
    peers = ','.join(used)
    for h, (code, out, err) in zip(used, run_parallel(lambda h: ssh(user, h, f'{POWER} link {peers}'), used)):
        print(f"  {short(h)}: {(out or err).splitlines()[0] if (out or err) else code}")
    print('Starting jobs...')

    def start(p):
        b64 = base64.b64encode(p['run'].encode()).decode()
        return p, ssh(user, p['host'], f"{POWER} run-job {p['name']} {b64}")
    for p, (code, out, err) in run_parallel(start, plan):
        print(f"  {p['name']:<20} on {short(p['host']):<14} {(out or err).splitlines()[-1] if (out or err) else code}")
    json.dump({'user': user, 'hosts': used, 'jobs': [{'name': p['name'], 'host': p['host']} for p in plan]},
              open(STATE, 'w'), indent=1)
    print('\nDone. See it: cluster-status   Logs: job-log NAME   Stop: stop-work')
    print('Your own nodes connect to the current powerplant; its router is linked to the others.')


def load_state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return None


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')   # dots print even on odd consoles
    except Exception:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('jobs_file', nargs='?', default=os.path.join(REPO, 'ws', 'jobs.yaml'))
    ap.add_argument('--on', help='comma-separated powerplants (4090,desktop or full names); default: all reachable')
    ap.add_argument('--user', default=os.environ.get('OFFLOAD_USER') or os.environ.get('USER'))
    ap.add_argument('--src', default=os.path.join(REPO, 'ws', 'src'), help='your ROS packages to sync')
    ap.add_argument('--plan', action='store_true', help='only show the plan')
    ap.add_argument('--json', action='store_true', help='print the plan as JSON (for VS Code / dashboard)')
    ap.add_argument('--yes', '-y', action='store_true', help="don't ask before starting")
    ap.add_argument('--no-sync', action='store_true')
    ap.add_argument('--no-build', action='store_true')
    ap.add_argument('--status', action='store_true', help='show distributed jobs')
    ap.add_argument('--stop', nargs='?', const='all', help='stop all (or one) distributed jobs')
    ap.add_argument('--unlink', action='store_true', help='with --stop: also unlink the ROS routers')
    ap.add_argument('--log', metavar='NAME', help="show a job's output")
    ap.add_argument('--capacity-json', help=argparse.SUPPRESS)   # testing: {host: capacity} instead of ssh
    a = ap.parse_args()

    if a.status or a.stop or a.log:
        st = load_state()
        hosts = [full_name(h) for h in a.on.split(',')] if a.on else (st['hosts'] if st else discover())
        if a.log:
            host = next((j['host'] for j in (st or {}).get('jobs', []) if j['name'] == a.log), None)
            for h in ([host] if host else hosts):
                code, out, err = ssh(a.user, h, f'{POWER} job-log {a.log} 60')
                print(f'--- {a.log} on {short(h)} ---\n{out or err}')
            return
        cmd = 'jobs' if a.status else f'stop-jobs {a.stop}'
        for h, (code, out, err) in zip(hosts, run_parallel(lambda h: ssh(a.user, h, f'{POWER} {cmd}'), hosts)):
            print(f"--- {short(h)} ---\n{out or err or '(no answer)'}")
            if a.stop and a.unlink:
                ssh(a.user, h, f'{POWER} link none')
        return

    if not os.path.exists(a.jobs_file):
        example = os.path.join(REPO, 'ws', 'jobs.example.yaml')
        sys.exit(f'No jobs file at {a.jobs_file}.\nStart from the example:  cp {example} {a.jobs_file}  and edit it.')
    jobs = load_jobs(a.jobs_file)

    if a.capacity_json:
        caps, failed = json.load(open(a.capacity_json)), {}
    else:
        hosts = [full_name(h) for h in a.on.split(',')] if a.on else discover()
        if not hosts:
            sys.exit('No powerplants found. Use --on NAME,NAME (see list-powerplants).')
        if not a.json:
            print(f"Asking {len(hosts)} powerplant(s) for their hardware and load...")
        caps, failed = {}, {}
        for h, c, e in run_parallel(lambda h: get_capacity(a.user, h), hosts):
            (caps.__setitem__(h, c) if c else failed.__setitem__(h, e))
        if not caps:
            sys.exit('No powerplant answered: ' + '; '.join(f'{short(h)}: {e}' for h, e in failed.items()))

    plan, warnings = schedule(jobs, caps)
    if a.json:
        print(json.dumps({'plan': plan, 'warnings': warnings, 'capacity': caps, 'failed': failed}))
        return
    print_plan(plan, caps, warnings, failed)
    if a.plan or not plan:
        return
    if not a.yes and input(f"Start {len(plan)} job(s) on {len({p['host'] for p in plan})} PC(s)? [Y/n] ").strip().lower() in ('n', 'no'):
        print('Nothing started.'); return
    execute(plan, a.user, a.src, not a.no_sync, not a.no_build)


if __name__ == '__main__':
    main()

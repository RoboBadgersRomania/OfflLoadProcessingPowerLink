"""Computing Power Network dashboard launcher - THIS is the file you compile (build.bat / PyInstaller).

On every start it checks the GitHub repo for a newer dashboard (dashboard/manifest.json). If there
is one, it downloads the files, checks they are valid Python, and runs them; otherwise it runs the
newest copy it has (downloaded earlier, or the one compiled into the .exe). So you compile once and
the dashboard keeps updating itself. Recompile only if a new version needs a new Python package.

Trust: whatever is on the repo's main branch runs on this PC - only people you trust should be
able to push to it.
"""
import importlib.util
import json
import os
import re
import shutil
import sys
import traceback
import urllib.request

RAW = 'https://raw.githubusercontent.com/RoboBadgersRomania/PowerCluster/main/dashboard'
CACHE = os.path.join(os.environ.get('LOCALAPPDATA') or os.path.expanduser('~'), 'OffloadPC', 'dashboard_app')

try:                       # the copy compiled into the .exe (fallback, and makes PyInstaller bundle pygame)
    import app as bundled
except Exception:          # pragma: no cover
    bundled = None


def vtuple(v):
    return tuple(int(x) for x in re.findall(r'\d+', v or '0')[:3])


def fetch(url, timeout=10):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'ComputingPowerNetwork'}), timeout=timeout) as r:
            return r.read()
    except Exception:
        return None


def cached_version():
    try:
        return json.load(open(os.path.join(CACHE, 'manifest.json')))['version']
    except (OSError, ValueError, KeyError):
        return '0'


def update():
    """Download a newer dashboard from GitHub into CACHE. Returns the new version or None."""
    raw = fetch(f'{RAW}/manifest.json')
    if not raw:
        return None
    manifest = json.loads(raw)
    latest = manifest['version']
    have = max(vtuple(cached_version()), vtuple(getattr(bundled, 'APP_VERSION', '0')))
    if vtuple(latest) <= have:
        return None
    tmp = CACHE + '.new'
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    for name in manifest['files']:
        data = fetch(f'{RAW}/{name}', 30)
        if data is None:
            return None
        if name.endswith('.py'):
            compile(data, name, 'exec')            # refuse broken code: keeps the old version
        with open(os.path.join(tmp, name), 'wb') as f:
            f.write(data)
    with open(os.path.join(tmp, 'manifest.json'), 'wb') as f:
        f.write(raw)
    shutil.rmtree(CACHE, ignore_errors=True)
    os.replace(tmp, CACHE)
    return latest


def load_app():
    """The newest available app module: downloaded copy or the compiled-in one."""
    path = os.path.join(CACHE, 'app.py')
    if os.path.exists(path) and (bundled is None or vtuple(cached_version()) > vtuple(getattr(bundled, 'APP_VERSION', '0'))):
        sys.path.insert(0, CACHE)
        spec = importlib.util.spec_from_file_location('badger_app', path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    return bundled


def main():
    try:
        new = update()
    except Exception:
        new = None
    mod = load_app()
    if mod is None:
        sys.exit('Dashboard code missing and GitHub unreachable.')
    try:
        mod.main(updated_from=new)
    except SystemExit:
        raise
    except Exception:
        traceback.print_exc()
        if mod is not bundled and bundled is not None:     # a downloaded version crashed: fall back
            shutil.rmtree(CACHE, ignore_errors=True)
            bundled.main()


if __name__ == '__main__':
    main()

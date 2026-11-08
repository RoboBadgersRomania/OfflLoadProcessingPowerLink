#!/usr/bin/env python3
"""Wake listener: wakes nuclear powerplants from ANY network, over the internet.

A sleeping PC isn't on Tailscale or the internet, so the wake signal (Wake-on-LAN magic packet)
must come from a device on ITS home network. Run this on any always-on device there:
Raspberry Pi, old laptop, NAS, Android phone (Termux)...  Only Python 3 is needed (no installs,
no port forwarding, no Tailscale): it listens to a private ntfy.sh topic over HTTPS, and when you
press "Wake" anywhere (terminal, VS Code, dashboard) it receives "wake <MAC>" and sends the packet.

    python3 wake_listener.py --topic badger-wake-1a2b3c...          # topic: shown by list-powerplants
    python3 wake_listener.py --topic T1 --topic T2                   # several PCs in the same home
    python3 wake_listener.py --topic T --install-service             # Linux: start automatically (systemd)
"""
import argparse
import json
import os
import re
import socket
import sys
import time
import urllib.request

MAC_RE = re.compile(r'([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}')


def log(msg):
    print(time.strftime('%Y-%m-%d %H:%M:%S'), msg, flush=True)


def broadcasts():
    """255.255.255.255 plus every local subnet broadcast we can find."""
    out = {'255.255.255.255'}
    try:  # Linux: ask the kernel
        import subprocess
        txt = subprocess.run(['ip', '-4', '-o', 'addr'], capture_output=True, text=True, timeout=5).stdout
        out.update(re.findall(r'brd (\d+\.\d+\.\d+\.\d+)', txt))
    except Exception:
        pass
    return sorted(out)


def send_wol(mac):
    raw = bytes.fromhex(re.sub(r'[:-]', '', mac))
    packet = b'\xff' * 6 + raw * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    targets = broadcasts()
    for t in targets:
        for port in (7, 9):
            try:
                s.sendto(packet, (t, port))
            except OSError:
                pass
    s.close()
    log(f'magic packet for {mac} sent to {", ".join(targets)}')


def listen(server, topics):
    url = f'{server.rstrip("/")}/{",".join(topics)}/json'
    backoff = 2
    while True:
        try:
            log(f'listening on {len(topics)} topic(s) at {server}')
            req = urllib.request.Request(url, headers={'User-Agent': 'badger-wake-listener'})
            with urllib.request.urlopen(req, timeout=90) as resp:   # ntfy sends keepalives every ~45 s
                backoff = 2
                for line in resp:
                    try:
                        ev = json.loads(line.decode('utf-8'))
                    except ValueError:
                        continue
                    if ev.get('event') != 'message':
                        continue
                    text = ev.get('message', '')
                    m = MAC_RE.search(text)
                    if text.strip().lower().startswith('wake') and m:
                        send_wol(m.group(0))
                    else:
                        log(f'ignored message: {text[:60]!r}')
        except KeyboardInterrupt:
            log('stopped'); return
        except Exception as e:  # network down, timeout, server restart...
            log(f'connection lost ({e.__class__.__name__}: {e}); retrying in {backoff} s')
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


def install_service(topics, server):
    if os.geteuid() != 0:
        sys.exit('Run with sudo to install the service:  sudo python3 wake_listener.py --topic ... --install-service')
    script = os.path.abspath(__file__)
    args = ' '.join(f'--topic {t}' for t in topics) + f' --server {server}'
    unit = f"""[Unit]
Description=BadgerLabs wake listener (Wake-on-LAN over the internet via ntfy)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart={sys.executable} {script} {args}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
"""
    with open('/etc/systemd/system/badger-wake-listener.service', 'w') as f:
        f.write(unit)
    os.system('systemctl daemon-reload && systemctl enable --now badger-wake-listener.service')
    print('Installed and started. Logs: journalctl -u badger-wake-listener -f')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--topic', action='append', required=True, help='wake topic (repeat for several PCs)')
    ap.add_argument('--server', default='https://ntfy.sh')
    ap.add_argument('--install-service', action='store_true', help='Linux: run automatically at boot (systemd)')
    ap.add_argument('--test', metavar='MAC', help='just send one magic packet to MAC and exit')
    a = ap.parse_args()
    if a.test:
        send_wol(a.test); return
    if a.install_service:
        install_service(a.topic, a.server); return
    listen(a.server, a.topic)


if __name__ == '__main__':
    main()

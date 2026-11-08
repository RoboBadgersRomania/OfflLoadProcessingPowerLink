// BadgerLabsOffloadingPP - VS Code extension for the Computing Power Network.
// Runs on your Windows PC (extensionKind "ui") and talks to the nuclear powerplants (processing
// offload PCs) over Tailscale with Windows' built-in ssh.exe.
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const net = require('net');
const os = require('os');

const REPO_URL = 'https://github.com/RoboBadgersRomania/PowerCluster#readme';
const PREFIX = 'processingoffloadpc';
const WOL_PY = 'import socket,sys;m=bytes.fromhex(sys.argv[1].replace(":","").replace("-",""));' +
  's=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1);' +
  '[s.sendto(b"\\xff"*6+m*16,("255.255.255.255",p)) for p in (7,9)]';
const DOT = { on: '🟢', off: '🔴', paused: '🟡', unknown: '⚪' };

let ctx;
let statusItem;
let timer;
let output;
let last = { state: 'unknown', detail: '', gpu: '', paused: false };

// ---------- settings / memory ----------
function cfg() { return vscode.workspace.getConfiguration('badgerlabs'); }
function host() { return cfg().get('host') || PREFIX; }
function repo() { return cfg().get('remoteRepoPath') || '~/ros2-remote'; }
function shortName(h) { return h === PREFIX ? 'main' : h.replace(PREFIX + '-', ''); }
function specsOf(h) { return ctx.globalState.get(`specs:${h}`, ''); }
function prettySpecs(s) { return (s || '').split('|').map((x) => x.trim()).filter(Boolean).join(' · '); }
function gpuOf(h) { return (specsOf(h).split('|')[0] || '').trim() || shortName(h); }
function knownHosts() { return ctx.globalState.get('knownHosts', []); }
async function remember(h) { if (!knownHosts().includes(h)) await ctx.globalState.update('knownHosts', [...knownHosts(), h]); }

/** Best guess for the Ubuntu username: this PC's own Ubuntu user (usually the same everywhere). */
function guessUser() {
  try {
    const distro = cfg().get('wslDistro') || 'Ubuntu-24.04';
    const out = cp.execFileSync('wsl.exe', ['-d', distro, '--exec', 'whoami'],
      { timeout: 8000, windowsHide: true, env: { ...process.env, WSL_UTF8: '1' } }).toString().replace(/\0/g, '').trim();
    if (/^[a-z_][a-z0-9_-]*$/.test(out) && out !== 'root') return out;
  } catch (e) { /* no local Ubuntu */ }
  return (os.userInfo().username || '').toLowerCase().replace(/[^a-z0-9_-]/g, '');
}

async function askUser(title, prompt, value) {
  const user = await vscode.window.showInputBox({
    title, prompt, value, ignoreFocusOut: true,
    validateInput: (v) => (/^[a-z_][a-z0-9_-]*$/.test(v) ? undefined : 'Lowercase letters, digits, - and _ only'),
  });
  if (user) await cfg().update('remoteUser', user, vscode.ConfigurationTarget.Global);
  return user;
}

async function remoteUser() {
  const user = cfg().get('remoteUser');
  if (user) return user;
  return askUser('BadgerLabs: your Ubuntu username on the nuclear powerplants',
    'The username you created in Ubuntu on the powerplant(s) when setting them up', guessUser());
}

/** Tailscale says "policy does not permit you to SSH as user X" when X doesn't exist on that PC. */
const wrongUser = (res) => /does not permit you to SSH as user/i.test(res.err + res.out);
async function fixWrongUser() {
  const u = cfg().get('remoteUser');
  const p = await vscode.window.showErrorMessage(
    `The Ubuntu user "${u}" doesn't exist on ${host()}. Use the username you created in Ubuntu on that PC.`, 'Change username');
  if (p) await askUser(`Ubuntu username on ${host()}`, `Not "${u}" - the one you chose in that PC's Ubuntu setup`, guessUser());
}

// ---------- network helpers ----------
const SSH_OPTS = ['-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new'];
// Always Windows' own OpenSSH: Git's ssh (sometimes first in PATH) hangs with Tailscale SSH
const SSH = (() => { const p = require('path').join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'OpenSSH', 'ssh.exe'); return require('fs').existsSync(p) ? p : 'ssh'; })();

/** TCP check of port 22 - the green/red dot. No login needed. */
function reachable(h, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const s = net.connect({ host: h, port: 22 });
    const done = (ok) => { s.destroy(); resolve(ok); };
    s.setTimeout(timeoutMs, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}

/** Run a command over ssh without a terminal. Resolves {ok, out, err, code}. */
function sshExec(target, command, timeoutMs = 25000) {
  return new Promise((resolve) => {
    cp.execFile(SSH, ['-n', ...SSH_OPTS, '-o', 'BatchMode=yes', target, command],
      { timeout: timeoutMs, windowsHide: true },
      (error, stdout, stderr) => resolve({
        ok: !error, out: String(stdout || '').trim(), err: String(stderr || '').trim(),
        code: error ? (typeof error.code === 'number' ? error.code : -1) : 0,
      }));
  });
}
const onPlant = (user, command, timeoutMs, h = host()) => sshExec(`${user}@${h}`, command, timeoutMs);

function sshTerminal(user, name, command, h = host()) {
  const args = ['-t', ...SSH_OPTS, `${user}@${h}`];
  if (command) args.push(command);
  const term = vscode.window.createTerminal({ name, shellPath: SSH, shellArgs: args, iconPath: new vscode.ThemeIcon('server-process') });
  term.show();
  return term;
}

const power = (action, arg) => `bash ${repo()}/processingoffloadPC/power.sh ${action}${arg ? ' ' + arg : ''}`;
const DOCKER_DIR = () => `cd ${repo()}/docker`;
const needsLogin = (res) => /tailscale\.com|additional check|authenticate/i.test(res.err + res.out);

/** Powerplants known to Tailscale on Windows + ones used before. */
function discover() {
  return new Promise((resolve) => {
    const tryExe = (exes) => {
      if (!exes.length) return resolve([]);
      cp.execFile(exes[0], ['status'], { timeout: 8000, windowsHide: true }, (err, stdout) => {
        if (err && !stdout) return tryExe(exes.slice(1));
        resolve(String(stdout).split(/\r?\n/).map((l) => l.trim().split(/\s+/)[1]).filter((n) => n && n.startsWith(PREFIX)));
      });
    };
    const fs = require('fs');   // setup may install Tailscale on the kit's drive (X:\Programs\Tailscale)
    const onDrives = 'CDEFGHIJKLMNOPQRSTUVWXYZ'.split('').map((d) => `${d}:\\Programs\\Tailscale\\tailscale.exe`).filter((p) => fs.existsSync(p));
    tryExe(['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe', ...onDrives]);
  });
}

// ---------- status bar ----------
function render() {
  const h = host();
  const gpu = gpuOf(h);
  let text;
  if (last.state === 'checking') text = `$(sync~spin) ${gpu}`;
  else if (last.state === 'on') text = `${last.paused ? DOT.paused : DOT.on} ${gpu}${last.paused ? ' · paused' : last.gpu ? ' · ' + last.gpu : ''}`;
  else if (last.state === 'login') text = `$(key) ${gpu} · login`;
  else if (last.state === 'offline') text = `${DOT.off} ${gpu}`;
  else text = `${DOT.unknown} ${gpu}`;
  statusItem.text = text;
  statusItem.tooltip = new vscode.MarkdownString(
    `**Nuclear powerplant** \`${h}\`  \n${prettySpecs(specsOf(h)) || '_specs not known yet_'}\n\n` +
    `${last.detail ? '```\n' + last.detail + '\n```' : ''}\n\nClick for actions · switch powerplant in the menu`);
  statusItem.backgroundColor = (last.state === 'login' || last.paused) ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
}

async function refreshStatus(interactive = false) {
  const h = host();
  const user = interactive ? await remoteUser() : cfg().get('remoteUser');
  last = { ...last, state: 'checking' }; render();
  if (!(await reachable(h))) {
    last = { state: 'offline', detail: `${h} is not reachable (asleep, off, or Tailscale not signed in).`, gpu: '', paused: false };
    render(); return last;
  }
  if (!user) { last = { state: 'on', detail: 'Reachable. Set your Ubuntu username (BadgerLabs: Settings) for details.', gpu: '', paused: false }; render(); return last; }
  const res = await onPlant(user, power('status'));
  const wasPaused = last.paused;
  if (res.ok) {
    const lines = res.out.split(/\r?\n/);
    const specs = (lines.find((l) => l.startsWith('Specs:')) || '').replace('Specs:', '').trim();
    if (specs && specs !== 'unknown') await ctx.globalState.update(`specs:${h}`, specs);
    const gpuLine = lines.find((l) => /,\s*\d+\s*%/.test(l)) || '';
    const util = (gpuLine.split(',')[1] || '').trim().replace(' ', '');
    const paused = lines.some((l) => l.startsWith('Guardian: PAUSED'));
    const macLine = lines.find((l) => l.startsWith('MAC:'));
    if (macLine) await ctx.globalState.update(`mac:${h}`, macLine.replace('MAC:', '').trim());
    const topicLine = lines.find((l) => l.startsWith('WakeTopic:'));
    if (topicLine) await ctx.globalState.update(`wake:${h}`, topicLine.replace('WakeTopic:', '').trim());
    last = { state: 'on', gpu: util, detail: res.out, paused };
    if (paused && !wasPaused) {
      vscode.window.showWarningMessage(`Your job on ${h} is PAUSED: someone is using that PC. It resumes when they leave.`, 'Resume anyway', 'OK')
        .then((p) => p === 'Resume anyway' && commands['badgerlabs.resume']());
    }
  } else if (wrongUser(res)) {
    last = { state: 'login', detail: `Wrong Ubuntu username "${user}" for ${h}. Fix it: BadgerLabs: Settings > remoteUser (or run any command and choose "Change username").`, gpu: '', paused: false };
  } else if (needsLogin(res)) {
    last = { state: 'login', detail: 'Tailscale SSH wants you to confirm the login.\nRun "BadgerLabs: Open ROS shell on offload PC" and open the link it shows.', gpu: '', paused: false };
  } else {
    last = { state: 'on', detail: `Reachable, but the status command failed:\n${(res.err || res.out).slice(0, 400)}`, gpu: '', paused: false };
  }
  render();
  return last;
}

function restartTimer() {
  if (timer) clearInterval(timer);
  const secs = cfg().get('statusIntervalSeconds');
  if (secs && secs > 0) timer = setInterval(() => refreshStatus(false), Math.max(15, secs) * 1000);
}

// ---------- helpers for commands ----------
function showReport(title, text) {
  if (!output) output = vscode.window.createOutputChannel('BadgerLabs');
  output.clear();
  output.appendLine(`${title}  (${new Date().toLocaleString()})`);
  output.appendLine(text);
  output.show(true);
}
async function confirm(msg, button) {
  return (await vscode.window.showWarningMessage(msg, { modal: true }, button)) === button;
}
async function runPower(action, arg, doneMsg) {
  const user = await remoteUser(); if (!user) return;
  const label = `${action}${arg ? ' ' + arg : ''}`;
  let res = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `BadgerLabs (${shortName(host())}): ${label}...` },
    () => onPlant(user, power(action, arg), 60000));
  if (res.code === 2) {   // power.sh refused: the powerplant looks busy
    showReport(`${host()} is BUSY`, res.out);
    const verdict = (res.out.match(/VERDICT:.*$/m) || ['It looks busy.'])[0];
    if (!(await confirm(`${verdict}\n\nDo "${action}" anyway?`, 'Yes, do it'))) return;
    res = await onPlant(user, power(action, `${arg || ''} --force`.trim()), 60000);
  }
  if (res.ok) {
    vscode.window.showInformationMessage(doneMsg || res.out.split(/\r?\n/).slice(-2).join(' ') || 'Done.');
    if (['sleep', 'sleep-until', 'off'].includes(action)) {
      setTimeout(() => { last = { state: 'offline', detail: `Sent "${action}" at ${new Date().toLocaleTimeString()}`, gpu: '', paused: false }; render(); }, 7000);
    } else { setTimeout(() => refreshStatus(false), 1500); }
  } else if (wrongUser(res)) {
    await fixWrongUser();
  } else {
    const pick = await vscode.window.showErrorMessage(
      `BadgerLabs: "${action}" failed: ${(res.err || res.out || 'no answer').slice(0, 200)}`, 'Run in terminal');
    if (pick) sshTerminal(user, `${shortName(host())}: ${action}`, power(action, arg));
  }
}
const askTime = (title, placeHolder) => vscode.window.showInputBox({
  title, placeHolder, ignoreFocusOut: true,
  validateInput: (v) => (/^([01]?\d|2[0-3]):[0-5]\d$/.test(v) ? undefined : 'Use HH:MM (24h), e.g. 22:30'),
});
function relayFor(h) { return (cfg().get('wakeRelays') || {})[h]; }

/** Publish a message to an ntfy.sh topic (the wake listener on the powerplant's network listens there). */
function publishNtfy(topic, message) {
  return new Promise((resolve) => {
    const req = require('https').request(`https://ntfy.sh/${encodeURIComponent(topic)}`,
      { method: 'POST', timeout: 10000, headers: { 'Content-Type': 'text/plain' } },
      (res) => { res.resume(); resolve(res.statusCode >= 200 && res.statusCode < 300); });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.end(message);
  });
}

/** Wake-on-LAN magic packet from THIS PC to every local network (works on the same LAN/Wi-Fi). */
function sendWolDirect(mac) {
  const dgram = require('dgram');
  const bytes = Buffer.from(mac.replace(/[:-]/g, ''), 'hex');
  const packet = Buffer.concat([Buffer.alloc(6, 0xff), ...Array(16).fill(bytes)]);
  const targets = new Set(['255.255.255.255']);
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family !== 'IPv4' || a.internal || a.address.startsWith('100.')) continue;   // skip Tailscale
      const ip = a.address.split('.').map(Number), mask = a.netmask.split('.').map(Number);
      targets.add(ip.map((o, i) => (o | (~mask[i] & 255))).join('.'));
    }
  }
  return new Promise((resolve) => {
    const s = dgram.createSocket('udp4');
    s.bind(() => {
      s.setBroadcast(true);
      let pending = targets.size * 2;
      const done = () => { if (--pending === 0) { s.close(); resolve(targets.size); } };
      for (const t of targets) for (const port of [9, 7]) s.send(packet, port, t, done);
    });
    s.on('error', () => { try { s.close(); } catch (e) { /* closed */ } resolve(0); });
  });
}

// ---------- distributed work (runs cluster/distribute.py inside THIS PC's Ubuntu) ----------
function wslRun(cmd, timeoutMs = 180000) {
  const distro = cfg().get('wslDistro') || 'Ubuntu-24.04';
  return new Promise((resolve) => {
    cp.execFile('wsl.exe', ['-d', distro, '--exec', 'bash', '-lc', cmd],
      { timeout: timeoutMs, windowsHide: true, maxBuffer: 10 * 1024 * 1024, env: { ...process.env, WSL_UTF8: '1' } },
      (error, stdout, stderr) => resolve({ ok: !error, out: String(stdout || ''), err: String(stderr || '') }));
  });
}
function wslTerminal(name, cmd) {
  const distro = cfg().get('wslDistro') || 'Ubuntu-24.04';
  const t = vscode.window.createTerminal({ name, shellPath: 'wsl.exe', shellArgs: ['-d', distro, '--exec', 'bash', '-lc', `${cmd}; exec bash`],
    iconPath: new vscode.ThemeIcon('server-environment') });
  t.show();
}
const DISTRIBUTE = (user, args) => `python3 ~/ros2-remote/cluster/distribute.py --user ${user} ${args}`;

/** Multi-select of powerplants, each shown by its specs with a live green/red dot. */
async function pickPowerplants(title) {
  const user = cfg().get('remoteUser');
  const qp = vscode.window.createQuickPick();
  qp.title = title; qp.canSelectMany = true; qp.busy = true;
  qp.placeholder = 'Tick the PCs to use (Space), then Enter';
  qp.show();
  const names = [...new Set([...(await discover()), ...knownHosts(), host()])];
  const states = {};
  const build = () => names.map((n) => ({
    label: `${states[n] === undefined ? '$(sync~spin)' : states[n] ? DOT.on : DOT.off} ${prettySpecs(specsOf(n)) || n}`,
    description: n, name: n, picked: n === host() || qp.selectedItems.some((i) => i.name === n),
  }));
  qp.items = build();
  await Promise.all(names.map(async (n) => {
    states[n] = await reachable(n);
    if (states[n] && user && !specsOf(n)) {
      const r = await onPlant(user, 'cat ~/.offload-agent/specs 2>/dev/null', 10000, n);
      if (r.ok && r.out) await ctx.globalState.update(`specs:${n}`, r.out.trim());
    }
    qp.items = build();
    qp.selectedItems = qp.items.filter((i) => i.picked);
  }));
  qp.busy = false;
  const picked = await new Promise((resolve) => {
    qp.onDidAccept(() => { resolve(qp.selectedItems.map((i) => i.name)); qp.hide(); });
    qp.onDidHide(() => resolve(undefined));
  });
  qp.dispose();
  return picked && picked.filter((n) => states[n]);
}

// ---------- self-update from the GitHub repo ----------
const RAW = 'https://raw.githubusercontent.com/RoboBadgersRomania/PowerCluster/main/vscode-extension';
function httpsGet(url, binary = false) {
  return new Promise((resolve) => {
    require('https').get(url, { timeout: 15000, headers: { 'User-Agent': 'BadgerLabsOffloadingPP' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) { res.resume(); return resolve(httpsGet(res.headers.location, binary)); }
      if (res.statusCode !== 200) { res.resume(); return resolve(null); }
      const chunks = []; res.on('data', (c) => chunks.push(c)); res.on('end', () => resolve(binary ? Buffer.concat(chunks) : Buffer.concat(chunks).toString()));
    }).on('error', () => resolve(null)).on('timeout', function () { this.destroy(); resolve(null); });
  });
}
const newer = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); } return false; };
async function checkForUpdate(manual = false) {
  if (!manual && !cfg().get('autoUpdate')) return;
  const mine = ctx.extension.packageJSON.version;
  const pj = await httpsGet(`${RAW}/BadgerLabsOffloadingPP/package.json`);
  const latest = pj && (JSON.parse(pj).version || '');
  if (!latest) { if (manual) vscode.window.showWarningMessage("Couldn't check GitHub for updates."); return; }
  if (!newer(latest, mine)) { if (manual) vscode.window.showInformationMessage(`BadgerLabsOffloadingPP ${mine} is up to date.`); return; }
  const p = await vscode.window.showInformationMessage(`BadgerLabsOffloadingPP ${latest} is available (you have ${mine}).`, 'Update now', 'Later');
  if (p !== 'Update now') return;
  const vsix = await httpsGet(`${RAW}/BadgerLabsOffloadingPP-${latest}.vsix`, true);
  if (!vsix) { vscode.window.showErrorMessage('Download failed - try again later.'); return; }
  const file = require('path').join(os.tmpdir(), `BadgerLabsOffloadingPP-${latest}.vsix`);
  require('fs').writeFileSync(file, vsix);
  await vscode.commands.executeCommand('workbench.extensions.installExtension', vscode.Uri.file(file));
  if ((await vscode.window.showInformationMessage(`Updated to ${latest}. Reload to use it.`, 'Reload')) === 'Reload')
    vscode.commands.executeCommand('workbench.action.reloadWindow');
}

// ---------- commands ----------
const commands = {
  'badgerlabs.distribute': async () => {
    const user = await remoteUser(); if (!user) return;
    const hosts = await pickPowerplants('Distribute work: which nuclear powerplants?');
    if (!hosts) return;
    if (!hosts.length) { vscode.window.showWarningMessage('None of the ticked powerplants is reachable.'); return; }
    const r = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Planning jobs over ${hosts.length} PC(s) by their hardware...` },
      () => wslRun(DISTRIBUTE(user, `--on ${hosts.join(',')} --json`)));
    let d;
    try { d = JSON.parse(r.out.trim().split(/\r?\n/).pop()); } catch (e) { d = null; }
    if (!d) {
      const msg = (r.out + r.err).trim();
      if (/No jobs file/.test(msg)) {
        const p = await vscode.window.showWarningMessage('No ws/jobs.yaml yet on this PC. Create it from the example?', 'Create & open');
        if (p) {
          await wslRun('cp -n ~/ros2-remote/ws/jobs.example.yaml ~/ros2-remote/ws/jobs.yaml');
          const u = (await wslRun('whoami')).out.trim();
          vscode.commands.executeCommand('vscode.open', vscode.Uri.parse(`vscode-remote://wsl+${cfg().get('wslDistro') || 'Ubuntu-24.04'}/home/${u}/ros2-remote/ws/jobs.yaml`));
        }
      } else showReport('Distribute work failed', msg);
      return;
    }
    const lines = d.plan.map((p) => `  ${p.name.padEnd(20)} -> ${shortName(p.host).padEnd(12)} ${p.why}`);
    showReport('Distribution plan', ['Plan:', ...lines, ...d.warnings.map((w) => `  ! ${w}`),
      ...Object.entries(d.failed || {}).map(([h, e]) => `  not used: ${h}: ${e}`)].join('\n'));
    const perHost = {};
    d.plan.forEach((p) => { perHost[shortName(p.host)] = (perHost[shortName(p.host)] || 0) + 1; });
    const summary = Object.entries(perHost).map(([h, n]) => `${h}: ${n}`).join(', ');
    if (!(await confirm(`Start ${d.plan.length} job(s)?  ${summary}\n\n(sync code, build, link ROS routers, start jobs - see the BadgerLabs output for the plan)`, 'Start')))
      return;
    wslTerminal('Distribute work', DISTRIBUTE(user, `--on ${hosts.join(',')} --yes`));
  },
  'badgerlabs.clusterStatus': async () => {
    const user = await remoteUser(); if (!user) return;
    const r = await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: 'Asking the powerplants...' },
      () => wslRun(DISTRIBUTE(user, '--status')));
    showReport('Distributed jobs', (r.out + r.err).trim() || 'No answer.');
  },
  'badgerlabs.stopWork': async () => {
    const user = await remoteUser(); if (!user) return;
    if (!(await confirm('Stop all distributed jobs on all powerplants?', 'Stop all'))) return;
    const r = await wslRun(DISTRIBUTE(user, '--stop all'));
    showReport('Stopped distributed jobs', (r.out + r.err).trim());
  },
  'badgerlabs.checkUpdate': () => checkForUpdate(true),

  'badgerlabs.choose': async () => {
    const user = cfg().get('remoteUser');
    const qp = vscode.window.createQuickPick();
    qp.title = 'Choose your nuclear powerplant';
    qp.placeholder = 'Which PC should do the heavy work?';
    qp.busy = true;
    qp.show();
    const names = [...new Set([...(await discover()), ...knownHosts(), host()])];
    const build = (states) => names.map((n) => ({
      label: `${states[n] === undefined ? '$(sync~spin)' : states[n] ? DOT.on : DOT.off} ${prettySpecs(specsOf(n)) || n}`,
      description: `${n}${n === host() ? '  $(check) current' : ''}`,
      detail: states[n] === undefined ? 'checking...' : states[n] ? 'reachable' : 'offline (asleep or off)',
      name: n,
    })).concat([{ label: '$(add) Enter a name...', name: '__new' }, { label: '$(vm) This PC only (local)', name: 'local' }]);
    const states = {};
    qp.items = build(states);
    await Promise.all(names.map(async (n) => {
      states[n] = await reachable(n);
      if (states[n] && user) {
        const r = await onPlant(user, 'cat ~/.offload-agent/specs 2>/dev/null', 10000, n);
        if (r.ok && r.out) await ctx.globalState.update(`specs:${n}`, r.out.trim());
      }
      qp.items = build(states);
    }));
    qp.busy = false;
    const pick = await new Promise((resolve) => {
      qp.onDidAccept(() => { resolve(qp.selectedItems[0]); qp.hide(); });
      qp.onDidHide(() => resolve(undefined));
    });
    qp.dispose();
    if (!pick) return;
    let name = pick.name;
    if (name === '__new') {
      const v = await vscode.window.showInputBox({ title: 'Powerplant name', placeHolder: 'processingoffloadpc-4090  or just  4090' });
      if (!v) return;
      name = v.startsWith(PREFIX) ? v : `${PREFIX}-${v}`;
    }
    if (name === 'local') {
      vscode.window.showInformationMessage('Local only: in your Ubuntu terminals run "use-powerplant local". The extension keeps showing the last powerplant.');
      return;
    }
    await remember(name);
    await cfg().update('host', name, vscode.ConfigurationTarget.Global);
    vscode.window.showInformationMessage(`Now using ${name}. In Ubuntu terminals run: use-powerplant ${shortName(name) === 'main' ? name : shortName(name)}`);
  },

  'badgerlabs.start': async () => {
    const user = await remoteUser(); if (!user) return;
    const h = host();
    if (!(await reachable(h))) {
      const p = await vscode.window.showWarningMessage(`${h} is offline (asleep or off).`, 'Wake it');
      if (p) await commands['badgerlabs.wake']();
      if (!(await reachable(h))) return;
    }
    const res = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Starting nuclear powerplant ${shortName(h)}...` },
      () => onPlant(user, power('start'), 90000));
    if (res.ok) {
      const warn = res.out.split(/\r?\n/).find((l) => l.startsWith('WARNING'));
      if (warn) vscode.window.showWarningMessage(warn.replace('WARNING: ', ''));
      else vscode.window.showInformationMessage(`${h} online - ROS containers running.`);
      const mac = await onPlant(user, power('mac'), 10000);
      if (mac.ok && mac.out) await ctx.globalState.update(`mac:${h}`, mac.out);
      refreshStatus(false);
      sshTerminal(user, `ROS (${shortName(h)})`, `${DOCKER_DIR()} && docker compose exec dev bash`);
    } else if (wrongUser(res)) {
      await fixWrongUser();
    } else if (needsLogin(res)) {
      vscode.window.showWarningMessage('Tailscale wants you to confirm the login. Opening a terminal: open the link it shows.');
      sshTerminal(user, 'Offload login', power('start'));
    } else {
      vscode.window.showErrorMessage(`Couldn't start: ${(res.err || res.out).slice(0, 200)}`);
    }
  },

  'badgerlabs.processes': async () => {
    const user = await remoteUser(); if (!user) return;
    const res = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Checking running processes on ${shortName(host())}...` },
      () => onPlant(user, power('processes'), 60000));
    if (res.out && /VERDICT/.test(res.out)) {
      showReport(`${host()} activity`, res.out);
      const verdict = res.out.match(/VERDICT:.*$/m)[0];
      if (res.ok) vscode.window.showInformationMessage(verdict); else vscode.window.showWarningMessage(verdict);
    } else if (wrongUser(res)) {
      await fixWrongUser();
    } else {
      vscode.window.showErrorMessage(`Couldn't get the process list: ${(res.err || res.out || 'offline?').slice(0, 200)}`);
    }
  },

  'badgerlabs.status': async () => {
    const s = await refreshStatus(true);
    if (s.state === 'on') showReport(`${host()} status`, s.detail);
    else vscode.window.showWarningMessage(s.detail);
  },

  'badgerlabs.openRemote': async () => {
    const user = await remoteUser(); if (!user) return;
    if (!vscode.extensions.getExtension('ms-vscode-remote.remote-ssh')) {
      const pick = await vscode.window.showWarningMessage('This needs the "Remote - SSH" extension.', 'Install');
      if (pick) await vscode.commands.executeCommand('workbench.extensions.installExtension', 'ms-vscode-remote.remote-ssh');
      return;
    }
    const abs = `${repo().replace(/^~/, `/home/${user}`)}/ws`;
    await vscode.commands.executeCommand('vscode.openFolder', vscode.Uri.parse(`vscode-remote://ssh-remote+${user}@${host()}${abs}`), { forceNewWindow: true });
  },

  'badgerlabs.rosShell': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, `ROS (${shortName(host())})`, `${DOCKER_DIR()} && docker compose exec dev bash`);
  },

  'badgerlabs.localShell': () => {
    const distro = cfg().get('wslDistro') || 'Ubuntu-24.04';
    vscode.window.createTerminal({ name: 'ROS (this PC)', shellPath: 'wsl.exe', shellArgs: ['-d', distro, '--cd', '~'],
      iconPath: new vscode.ThemeIcon('terminal-linux') }).show();
  },

  'badgerlabs.build': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, `colcon build (${shortName(host())})`,
      `${DOCKER_DIR()} && docker compose exec dev bash -lc 'source /opt/ros/jazzy/setup.bash && cd /ws && colcon build --symlink-install'`);
  },

  'badgerlabs.restartRos': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, `Restart ROS (${shortName(host())})`, `${DOCKER_DIR()} && docker compose restart && docker compose ps`);
  },

  'badgerlabs.foxglove': () =>
    vscode.env.openExternal(vscode.Uri.parse(`https://app.foxglove.dev/view?ds=foxglove-websocket&ds.url=ws://${host()}:8765`)),

  'badgerlabs.sleep': () => runPower('sleep', '', `${host()} is going to sleep.`),

  'badgerlabs.sleepUntil': async () => {
    const t = await askTime('Sleep the nuclear powerplant and wake it at (24h)', '22:30');
    if (t) runPower('sleep-until', t);
  },

  'badgerlabs.sleepAfterFinish': async () => {
    const pick = await vscode.window.showQuickPick([
      { label: '$(watch) Sleep when work is done', value: 'start' },
      { label: '$(history) Sleep when work is done, wake at...', value: 'wake' },
      { label: '$(info) Is it waiting? (status)', value: 'status' },
      { label: '$(close) Cancel', value: 'cancel' },
    ], { title: 'Sleep nuclear powerplant after work finishes', placeHolder: 'Sleeps once idle 5 min in a row: GPU/CPU quiet, no ROS nodes or running tmux jobs, nobody at the PC' });
    if (!pick) return;
    if (pick.value === 'start') return runPower('sleep-after-finish');
    if (pick.value === 'status' || pick.value === 'cancel') return runPower('sleep-after-finish', pick.value);
    const t = await askTime('Wake the nuclear powerplant again at (24h)', '07:00');
    if (t) runPower('sleep-after-finish', t);
  },

  'badgerlabs.resume': () => runPower('resume'),

  'badgerlabs.guardian': async () => {
    const pick = await vscode.window.showQuickPick([
      { label: '$(info) Guardian status', value: '' },
      { label: '$(shield) Turn guardian ON (pause my job while the owner uses the PC)', value: 'on' },
      { label: '$(circle-slash) Turn guardian OFF', value: 'off' },
    ], { title: `Guardian on ${host()}` });
    if (!pick) return;
    if (!pick.value) {
      const user = await remoteUser(); if (!user) return;
      const r = await onPlant(user, power('guardian', 'status'), 20000);
      showReport(`Guardian on ${host()}`, r.out || r.err);
    } else runPower('guardian', pick.value);
  },

  'badgerlabs.notifications': async () => {
    const user = await remoteUser(); if (!user) return;
    const r = await onPlant(user, power('notify-info'), 20000);
    const topic = (r.out.match(/^\s+(badger-[0-9a-f]+)\s*$/m) || [])[1];
    if (!topic) { showReport('Notifications', r.out || r.err); return; }
    const p = await vscode.window.showInformationMessage(
      `Phone notifications for ${host()}: install the "ntfy" app and subscribe to topic ${topic}`, 'Copy topic', 'Open in browser', 'Send test');
    if (p === 'Copy topic') vscode.env.clipboard.writeText(topic);
    if (p === 'Open in browser') vscode.env.openExternal(vscode.Uri.parse(`https://ntfy.sh/${topic}`));
    if (p === 'Send test') runPower('notify-test');
  },

  'badgerlabs.wake': async () => {
    const h = host();
    const mac = ((ctx.globalState.get(`mac:${h}`) || '').match(/([0-9a-f]{2}[:-]){5}[0-9a-f]{2}/i) || [])[0];
    if (!mac) { vscode.window.showWarningMessage(`MAC address of ${h} unknown: let the status bar show it as 🟢 once (or Start nuclear powerplant), then try again.`); return; }
    const relay = relayFor(h);
    const ok = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Waking ${h}...`, cancellable: true },
      async (progress, token) => {
        // 0) through the wake listener on the powerplant's home network (ntfy.sh): works from any network
        const topic = ctx.globalState.get(`wake:${h}`);
        if (topic) {
          const okNtfy = await publishNtfy(topic, `wake ${mac}`);
          progress.report({ message: okNtfy ? 'sent to the wake listener over the internet' : 'could not reach ntfy.sh' });
        }
        // 1) directly on this network (works when this PC is on the same LAN/Wi-Fi as the powerplant)
        const sent = await sendWolDirect(mac);
        progress.report({ message: `magic packet sent on this network (${sent} interface(s))` });
        // 2) through the wake relay on the powerplant's own network (works from anywhere)
        if (relay) {
          const r = await sshExec(relay, `python3 -c '${WOL_PY}' ${mac}`, 20000);
          if (!r.ok) vscode.window.showWarningMessage(`Couldn't reach the wake relay ${relay}: ${(r.err || r.out).slice(0, 150)}`);
          else progress.report({ message: `also sent through relay ${relay}` });
        }
        for (let i = 0; i < 36 && !token.isCancellationRequested; i++) {
          progress.report({ message: `waiting for it to come online (${i * 5}s)` });
          if (await reachable(h)) return true;
          await new Promise((r2) => setTimeout(r2, 5000));
        }
        return false;
      });
    if (ok) { vscode.window.showInformationMessage(`${DOT.on} ${h} is online.`); refreshStatus(false); return; }
    const hasListener = !!ctx.globalState.get(`wake:${h}`);
    const p = await vscode.window.showWarningMessage(
      (relay || hasListener)
        ? `${h} didn't come online. Is the wake listener running on its home network? Wake-on-LAN on in its BIOS (Power On By PCI-E on, ErP off)? Wired?`
        : `${h} didn't come online. From another network, a wake listener on its home network must send the signal (a sleeping PC isn't on the internet).`,
      'How to set up', ...(relay ? [] : ['Set Tailscale relay']));
    if (p === 'How to set up') {
      vscode.env.openExternal(vscode.Uri.parse('https://github.com/RoboBadgersRomania/PowerCluster#wake-over-the-internet'));
    } else if (p) {
      const v = await vscode.window.showInputBox({
        title: `Wake relay for ${h}`, ignoreFocusOut: true, placeHolder: 'pi@wakepi',
        prompt: 'An always-on Tailscale device on that PC\'s home network (e.g. a Raspberry Pi). See README > Wake over the internet.',
      });
      if (v) await cfg().update('wakeRelays', { ...(cfg().get('wakeRelays') || {}), [h]: v }, vscode.ConfigurationTarget.Global);
    }
  },

  'badgerlabs.shutdown': async () => {
    if (await confirm(`Shut down ${host()} in 60 s? It can only be started again with Wake-on-LAN or its power button.`, 'Shut down'))
      runPower('off');
  },
  'badgerlabs.restart': async () => {
    if (await confirm(`Restart ${host()} in 60 s? Windows must log in again before ROS is back.`, 'Restart'))
      runPower('restart');
  },
  'badgerlabs.cancel': () => runPower('cancel'),
  'badgerlabs.mac': () => runPower('mac'),
  'badgerlabs.settings': () => vscode.commands.executeCommand('workbench.action.openSettings', 'badgerlabs'),
  'badgerlabs.readme': () => vscode.env.openExternal(vscode.Uri.parse(REPO_URL)),

  'badgerlabs.menu': async () => {
    const h = host();
    const items = [
      { label: `$(server-environment) ${prettySpecs(specsOf(h)) || h}`, description: 'switch powerplant...', cmd: 'badgerlabs.choose' },
      { label: '', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(zap) Start nuclear powerplant', cmd: 'badgerlabs.start', description: 'start ROS + open shell' },
      { label: '$(list-tree) Show running processes', cmd: 'badgerlabs.processes', description: 'safe to power off?' },
      { label: '$(refresh) Status', cmd: 'badgerlabs.status', description: last.state },
      { label: '$(remote-explorer) Open powerplant workspace', cmd: 'badgerlabs.openRemote', description: 'new window, Remote-SSH' },
      { label: '$(server-process) ROS shell on powerplant', cmd: 'badgerlabs.rosShell', description: 'heavy nodes + GPU' },
      { label: '$(terminal-linux) ROS shell on this PC', cmd: 'badgerlabs.localShell', description: 'Gazebo / RViz / light nodes' },
      { label: '$(tools) Build workspace on powerplant', cmd: 'badgerlabs.build', description: 'colcon build' },
      { label: '$(type-hierarchy) Distribute work across powerplants', cmd: 'badgerlabs.distribute', description: 'pick 2-3 PCs, split ws/jobs.yaml by hardware' },
      { label: '$(list-unordered) Distributed jobs status', cmd: 'badgerlabs.clusterStatus' },
      { label: '$(debug-stop) Stop distributed work', cmd: 'badgerlabs.stopWork' },
      { label: '$(eye) Open Foxglove viewer', cmd: 'badgerlabs.foxglove' },
      { label: '', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(debug-pause) Sleep nuclear powerplant', cmd: 'badgerlabs.sleep' },
      { label: '$(watch) Sleep nuclear powerplant and wake at...', cmd: 'badgerlabs.sleepUntil' },
      { label: '$(check-all) Sleep nuclear powerplant after work finishes', cmd: 'badgerlabs.sleepAfterFinish' },
      { label: '$(sun) Wake nuclear powerplant', cmd: 'badgerlabs.wake', description: 'via wake relay' },
      { label: '$(play) Resume paused job', cmd: 'badgerlabs.resume', description: last.paused ? 'PAUSED now' : '' },
      { label: '$(shield) Guardian', cmd: 'badgerlabs.guardian', description: 'auto-pause while the owner uses the PC' },
      { label: '$(bell) Phone notifications', cmd: 'badgerlabs.notifications' },
      { label: '', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(debug-restart) Restart ROS containers', cmd: 'badgerlabs.restartRos' },
      { label: '$(debug-restart-frame) Restart PC', cmd: 'badgerlabs.restart' },
      { label: '$(circle-slash) Shut down PC', cmd: 'badgerlabs.shutdown' },
      { label: '$(close) Cancel shutdown/restart', cmd: 'badgerlabs.cancel' },
      { label: '$(plug) Show MAC (Wake-on-LAN)', cmd: 'badgerlabs.mac' },
      { label: '$(gear) Settings', cmd: 'badgerlabs.settings' },
      { label: '$(book) Setup guide', cmd: 'badgerlabs.readme' },
      { label: '$(cloud-download) Check for extension update', cmd: 'badgerlabs.checkUpdate', description: `v${ctx.extension.packageJSON.version}` },
    ];
    const pick = await vscode.window.showQuickPick(items, { title: `${last.paused ? DOT.paused : last.state === 'on' ? DOT.on : DOT.off} ${h}`, placeHolder: 'Choose an action' });
    if (pick && pick.cmd) vscode.commands.executeCommand(pick.cmd);
  },
};

function activate(context) {
  ctx = context;
  // ssh.exe can't save known hosts if %USERPROFILE%\.ssh is missing
  try { require('fs').mkdirSync(require('path').join(os.homedir(), '.ssh'), { recursive: true }); } catch (e) { /* ignore */ }
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  statusItem.command = 'badgerlabs.menu';
  render();
  statusItem.show();
  context.subscriptions.push(statusItem);
  for (const [id, fn] of Object.entries(commands)) context.subscriptions.push(vscode.commands.registerCommand(id, fn));
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration((e) => {
    if (e.affectsConfiguration('badgerlabs')) { restartTimer(); refreshStatus(false); }
  }));
  restartTimer();
  refreshStatus(false);
  setTimeout(() => checkForUpdate(false), 20000);                       // once after startup...
  context.subscriptions.push({ dispose: clearInterval.bind(null, setInterval(() => checkForUpdate(false), 6 * 3600 * 1000)) });  // ...and every 6 h
}

function deactivate() { if (timer) clearInterval(timer); }

module.exports = { activate, deactivate };

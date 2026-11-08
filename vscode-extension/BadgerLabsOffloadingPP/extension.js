// BadgerLabsOffloadingPP - VS Code extension for OffLoad Processing Power Link.
// Runs on your Windows PC (extensionKind "ui") and talks to the nuclear powerplants (processing
// offload PCs) over Tailscale with Windows' built-in ssh.exe.
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const net = require('net');
const os = require('os');

const REPO_URL = 'https://github.com/RoboBadgersRomania/OfflLoadProcessingPowerLink#readme';
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
    cp.execFile('ssh', [...SSH_OPTS, '-o', 'BatchMode=yes', target, command],
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
  const term = vscode.window.createTerminal({ name, shellPath: 'ssh', shellArgs: args, iconPath: new vscode.ThemeIcon('server-process') });
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
    tryExe(['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe']);
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

// ---------- commands ----------
const commands = {
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
      const opts = relayFor(h) ? ['Wake it'] : ['Set up wake relay'];
      const p = await vscode.window.showWarningMessage(`${h} is offline (asleep or off).`, ...opts);
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
    let relay = relayFor(h);
    if (!relay) {
      relay = await vscode.window.showInputBox({
        title: `Wake relay for ${h}`, ignoreFocusOut: true, placeHolder: 'pi@wakepi',
        prompt: 'An always-on Tailscale device on that PC\'s home network (e.g. a Raspberry Pi). See README > Wake over the internet.',
      });
      if (!relay) return;
      await cfg().update('wakeRelays', { ...(cfg().get('wakeRelays') || {}), [h]: relay }, vscode.ConfigurationTarget.Global);
    }
    const mac = ((ctx.globalState.get(`mac:${h}`) || '').match(/([0-9a-f]{2}[:-]){5}[0-9a-f]{2}/i) || [])[0];
    if (!mac) { vscode.window.showWarningMessage(`MAC address of ${h} unknown: use "Start nuclear powerplant" once while it is on.`); return; }
    const ok = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: `Waking ${h} via ${relay}...`, cancellable: true },
      async (progress, token) => {
        const r = await sshExec(relay, `python3 -c '${WOL_PY}' ${mac}`, 20000);
        if (!r.ok) { vscode.window.showErrorMessage(`Couldn't reach the relay ${relay}: ${(r.err || r.out).slice(0, 150)}`); return false; }
        for (let i = 0; i < 36 && !token.isCancellationRequested; i++) {
          progress.report({ message: `waiting for it to come online (${i * 5}s)` });
          if (await reachable(h)) return true;
          await new Promise((r2) => setTimeout(r2, 5000));
        }
        return false;
      });
    if (ok) { vscode.window.showInformationMessage(`${DOT.on} ${h} is online.`); refreshStatus(false); }
    else vscode.window.showWarningMessage(`${h} didn't come online. Wake-on-LAN enabled in its BIOS? Wired network?`);
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
}

function deactivate() { if (timer) clearInterval(timer); }

module.exports = { activate, deactivate };

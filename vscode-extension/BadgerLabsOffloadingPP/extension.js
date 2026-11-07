// BadgerLabsOffloadingPP - VS Code extension for OffLoad Processing Power Link.
// Runs on your Windows PC (extensionKind "ui") and talks to the processing offload PC
// over Tailscale SSH using Windows' built-in ssh.exe.
'use strict';
const vscode = require('vscode');
const cp = require('child_process');
const os = require('os');

const REPO_URL = 'https://github.com/RoboBadgersRomania/OfflLoadProcessingPowerLink#readme';
let statusItem;
let timer;
let lastStatus = { state: 'unknown', detail: '' };

// ---------- settings ----------
function cfg() { return vscode.workspace.getConfiguration('badgerlabs'); }
function host() { return cfg().get('host') || 'processingoffloadpc'; }
function repo() { return cfg().get('remoteRepoPath') || '~/ros2-remote'; }

async function remoteUser() {
  let user = cfg().get('remoteUser');
  if (user) return user;
  const guess = (os.userInfo().username || '').toLowerCase().replace(/[^a-z0-9_-]/g, '');
  user = await vscode.window.showInputBox({
    title: 'BadgerLabs: Ubuntu username on the offload PC',
    prompt: 'The username you created in Ubuntu on the processing offload PC',
    value: guess,
    ignoreFocusOut: true,
    validateInput: (v) => (/^[a-z_][a-z0-9_-]*$/.test(v) ? undefined : 'Lowercase letters, digits, - and _ only'),
  });
  if (!user) return undefined;
  await cfg().update('remoteUser', user, vscode.ConfigurationTarget.Global);
  return user;
}

// ---------- ssh helpers ----------
const SSH_OPTS = ['-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new'];

/** Run a command on the offload PC without a terminal. Resolves {ok, out, err, code}. */
function sshExec(user, command, timeoutMs = 25000) {
  return new Promise((resolve) => {
    cp.execFile('ssh', [...SSH_OPTS, '-o', 'BatchMode=yes', `${user}@${host()}`, command],
      { timeout: timeoutMs, windowsHide: true },
      (error, stdout, stderr) => resolve({
        ok: !error, out: String(stdout || '').trim(), err: String(stderr || '').trim(),
        code: error ? (error.code ?? -1) : 0, killed: !!(error && error.killed),
      }));
  });
}

/** Open an interactive terminal on the offload PC running `command` (or a login shell). */
function sshTerminal(user, name, command) {
  const args = ['-t', ...SSH_OPTS, `${user}@${host()}`];
  if (command) args.push(command);
  const term = vscode.window.createTerminal({ name, shellPath: 'ssh', shellArgs: args, iconPath: new vscode.ThemeIcon('server-process') });
  term.show();
  return term;
}

function power(action, arg) {
  return `bash ${repo()}/processingoffloadPC/power.sh ${action}${arg ? ' ' + arg : ''}`;
}
const DOCKER_DIR = () => `cd ${repo()}/docker`;

function needsLogin(res) { return /tailscale\.com|additional check|authenticate/i.test(res.err + res.out); }

// ---------- status bar ----------
function render() {
  const s = lastStatus;
  const icons = { on: '$(server-process)', offline: '$(debug-disconnect)', checking: '$(sync~spin)', login: '$(key)', unknown: '$(server)' };
  let text = `${icons[s.state] || icons.unknown} Offload`;
  if (s.state === 'on') text += s.gpu ? `: GPU ${s.gpu}` : ': ON';
  if (s.state === 'offline') text += ': offline';
  if (s.state === 'login') text += ': login needed';
  statusItem.text = text;
  statusItem.tooltip = new vscode.MarkdownString(
    `**BadgerLabs offload PC** \`${host()}\`\n\n${s.detail ? '```\n' + s.detail + '\n```' : '_not checked yet_'}\n\nClick for actions`);
  statusItem.backgroundColor = s.state === 'login' ? new vscode.ThemeColor('statusBarItem.warningBackground') : undefined;
}

async function refreshStatus(interactive = false) {
  const user = interactive ? await remoteUser() : cfg().get('remoteUser');
  if (!user) { lastStatus = { state: 'unknown', detail: 'Set your Ubuntu username: BadgerLabs: Settings' }; render(); return lastStatus; }
  lastStatus = { ...lastStatus, state: 'checking' }; render();
  const res = await sshExec(user, power('status'));
  if (res.ok) {
    // Expected: "Offload PC is ON - up 3 hours" + "NVIDIA GeForce RTX 4090, 12 %, 1234 MiB, 24564 MiB, 45, 60.10 W"
    const gpuLine = res.out.split(/\r?\n/).find((l) => l.includes(',')) || '';
    const util = (gpuLine.split(',')[1] || '').trim().replace(' ', '');
    lastStatus = { state: 'on', gpu: util, detail: res.out };
  } else if (needsLogin(res)) {
    lastStatus = { state: 'login', detail: 'Tailscale SSH wants you to confirm the login.\nRun "BadgerLabs: Open ROS shell on offload PC" and open the link it shows.' };
  } else {
    lastStatus = { state: 'offline', detail: (res.err || res.out || 'No answer (asleep, off, or Tailscale not signed in).').slice(0, 600) };
  }
  render();
  return lastStatus;
}

function restartTimer() {
  if (timer) clearInterval(timer);
  const secs = cfg().get('statusIntervalSeconds');
  if (secs && secs > 0) timer = setInterval(() => refreshStatus(false), Math.max(15, secs) * 1000);
}

// ---------- commands ----------
let output;
function showReport(title, text) {
  if (!output) output = vscode.window.createOutputChannel('BadgerLabs');
  output.clear();
  output.appendLine(`${title}  (${new Date().toLocaleString()})`);
  output.appendLine(text);
  output.show(true);
}

async function runPower(action, arg, doneMsg) {
  const user = await remoteUser(); if (!user) return;
  const label = `${action}${arg ? ' ' + arg : ''}`;
  let res = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: `BadgerLabs: ${label}...` },
    () => sshExec(user, power(action, arg), 60000));
  if (res.code === 2) {
    // power.sh refused: the nuclear powerplant looks busy. Show why and ask.
    showReport('Nuclear powerplant is BUSY', res.out);
    const verdict = (res.out.match(/VERDICT:.*$/m) || ['It looks busy.'])[0];
    if (!(await confirm(`${verdict}\n\nDo "${action}" anyway?`, 'Yes, do it'))) return;
    res = await sshExec(user, power(action, `${arg || ''} --force`.trim()), 60000);
  }
  if (res.ok) {
    vscode.window.showInformationMessage(doneMsg || res.out || 'Done.');
    if (['sleep', 'sleep-until', 'off'].includes(action)) {
      setTimeout(() => { lastStatus = { state: 'offline', detail: `Sent "${action}" at ${new Date().toLocaleTimeString()}` }; render(); }, 7000);
    }
  } else {
    const pick = await vscode.window.showErrorMessage(
      `BadgerLabs: "${action}" failed: ${(res.err || res.out || 'no answer').slice(0, 200)}`, 'Run in terminal');
    if (pick) sshTerminal(user, `Offload: ${action}`, power(action, arg));
  }
}

async function confirm(msg, button) {
  return (await vscode.window.showWarningMessage(msg, { modal: true }, button)) === button;
}

const commands = {
  'badgerlabs.status': async () => {
    const s = await refreshStatus(true);
    if (s.state === 'on') vscode.window.showInformationMessage(`Offload PC: ${s.detail.replace(/\r?\n/g, ' | ')}`);
    else if (s.state === 'login') vscode.window.showWarningMessage(s.detail);
    else if (s.state === 'offline') vscode.window.showWarningMessage(`Offload PC is offline: ${s.detail}`);
  },

  'badgerlabs.openRemote': async () => {
    const user = await remoteUser(); if (!user) return;
    if (!vscode.extensions.getExtension('ms-vscode-remote.remote-ssh')) {
      const pick = await vscode.window.showWarningMessage('This needs the "Remote - SSH" extension.', 'Install');
      if (pick) await vscode.commands.executeCommand('workbench.extensions.installExtension', 'ms-vscode-remote.remote-ssh');
      return;
    }
    const abs = `${repo().replace(/^~/, `/home/${user}`)}/ws`;
    const uri = vscode.Uri.parse(`vscode-remote://ssh-remote+${user}@${host()}${abs}`);
    await vscode.commands.executeCommand('vscode.openFolder', uri, { forceNewWindow: true });
  },

  'badgerlabs.start': async () => {
    const user = await remoteUser(); if (!user) return;
    const res = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Starting the nuclear powerplant...' },
      () => sshExec(user, power('start'), 90000));
    if (res.ok) {
      vscode.window.showInformationMessage('Nuclear powerplant online. ROS containers running.');
      refreshStatus(false);
      sshTerminal(user, 'ROS (offload PC)', `${DOCKER_DIR()} && docker compose exec dev bash`);
    } else if (needsLogin(res)) {
      vscode.window.showWarningMessage('Tailscale wants you to confirm the login. Opening a terminal: open the link it shows.');
      sshTerminal(user, 'Offload login', power('start'));
    } else {
      vscode.window.showWarningMessage(
        'Nuclear powerplant is offline (asleep or off). Wake it with Wake-on-LAN from its home network, ' +
        'or next time use "Sleep nuclear powerplant and wake at...".', 'Show MAC')
        .then((p) => p && runPower('mac'));
    }
  },

  'badgerlabs.processes': async () => {
    const user = await remoteUser(); if (!user) return;
    const res = await vscode.window.withProgress(
      { location: vscode.ProgressLocation.Notification, title: 'Checking running processes on the nuclear powerplant...' },
      () => sshExec(user, power('processes'), 60000));
    if (res.out && /VERDICT/.test(res.out)) {
      showReport('Nuclear powerplant activity', res.out);
      const verdict = res.out.match(/VERDICT:.*$/m)[0];
      if (res.ok) vscode.window.showInformationMessage(verdict); else vscode.window.showWarningMessage(verdict);
    } else {
      vscode.window.showErrorMessage(`Couldn't get the process list: ${(res.err || res.out || 'offline?').slice(0, 200)}`);
    }
  },

  'badgerlabs.rosShell': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, 'ROS (offload PC)', `${DOCKER_DIR()} && docker compose exec dev bash`);
  },

  'badgerlabs.localShell': () => {
    const distro = cfg().get('wslDistro') || 'Ubuntu-24.04';
    vscode.window.createTerminal({ name: 'ROS (this PC)', shellPath: 'wsl.exe', shellArgs: ['-d', distro, '--cd', '~'],
      iconPath: new vscode.ThemeIcon('terminal-linux') }).show();
  },

  'badgerlabs.build': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, 'colcon build (offload PC)',
      `${DOCKER_DIR()} && docker compose exec dev bash -lc 'source /opt/ros/jazzy/setup.bash && cd /ws && colcon build --symlink-install'`);
  },

  'badgerlabs.restartRos': async () => {
    const user = await remoteUser(); if (!user) return;
    sshTerminal(user, 'Restart ROS (offload PC)', `${DOCKER_DIR()} && docker compose restart && docker compose ps`);
  },

  'badgerlabs.foxglove': () =>
    vscode.env.openExternal(vscode.Uri.parse(`https://app.foxglove.dev/view?ds=foxglove-websocket&ds.url=ws://${host()}:8765`)),

  'badgerlabs.sleep': () => runPower('sleep', '', 'Nuclear powerplant is going to sleep.'),

  'badgerlabs.sleepUntil': async () => {
    const t = await vscode.window.showInputBox({
      title: 'Sleep the nuclear powerplant and wake it at (24h)', placeHolder: '22:30', ignoreFocusOut: true,
      validateInput: (v) => (/^([01]?\d|2[0-3]):[0-5]\d$/.test(v) ? undefined : 'Use HH:MM, e.g. 22:30'),
    });
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
    const t = await vscode.window.showInputBox({
      title: 'Wake the nuclear powerplant again at (24h)', placeHolder: '07:00', ignoreFocusOut: true,
      validateInput: (v) => (/^([01]?\d|2[0-3]):[0-5]\d$/.test(v) ? undefined : 'Use HH:MM, e.g. 07:00'),
    });
    if (t) runPower('sleep-after-finish', t);
  },

  'badgerlabs.shutdown': async () => {
    if (await confirm('Shut down the offload PC in 60 s? It can only be started again with Wake-on-LAN or its power button.', 'Shut down'))
      runPower('off');
  },

  'badgerlabs.restart': async () => {
    if (await confirm('Restart the offload PC in 60 s? Windows must log in again before ROS is back.', 'Restart'))
      runPower('restart');
  },

  'badgerlabs.cancel': () => runPower('cancel'),
  'badgerlabs.mac': () => runPower('mac'),
  'badgerlabs.settings': () => vscode.commands.executeCommand('workbench.action.openSettings', 'badgerlabs'),
  'badgerlabs.readme': () => vscode.env.openExternal(vscode.Uri.parse(REPO_URL)),

  'badgerlabs.menu': async () => {
    const items = [
      { label: '$(zap) Start nuclear powerplant', cmd: 'badgerlabs.start', description: 'start ROS + open shell' },
      { label: '$(list-tree) Show running processes', cmd: 'badgerlabs.processes', description: 'safe to power off?' },
      { label: '$(refresh) Check status', cmd: 'badgerlabs.status', description: lastStatus.state },
      { label: '$(remote-explorer) Open offload PC workspace', cmd: 'badgerlabs.openRemote', description: 'new window, Remote-SSH' },
      { label: '$(server-process) ROS shell on offload PC', cmd: 'badgerlabs.rosShell', description: 'heavy nodes + GPU' },
      { label: '$(terminal-linux) ROS shell on this PC', cmd: 'badgerlabs.localShell', description: 'Gazebo / RViz / light nodes' },
      { label: '$(tools) Build workspace on offload PC', cmd: 'badgerlabs.build', description: 'colcon build' },
      { label: '$(eye) Open Foxglove viewer', cmd: 'badgerlabs.foxglove' },
      { label: '$(debug-restart) Restart ROS containers', cmd: 'badgerlabs.restartRos' },
      { label: '', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(debug-pause) Sleep nuclear powerplant', cmd: 'badgerlabs.sleep' },
      { label: '$(watch) Sleep nuclear powerplant and wake at...', cmd: 'badgerlabs.sleepUntil' },
      { label: '$(check-all) Sleep nuclear powerplant after work finishes', cmd: 'badgerlabs.sleepAfterFinish' },
      { label: '$(debug-restart-frame) Restart PC', cmd: 'badgerlabs.restart' },
      { label: '$(circle-slash) Shut down PC', cmd: 'badgerlabs.shutdown' },
      { label: '$(close) Cancel shutdown/restart', cmd: 'badgerlabs.cancel' },
      { label: '$(plug) Show MAC (Wake-on-LAN)', cmd: 'badgerlabs.mac' },
      { label: '', kind: vscode.QuickPickItemKind.Separator },
      { label: '$(gear) Settings', cmd: 'badgerlabs.settings' },
      { label: '$(book) Setup guide', cmd: 'badgerlabs.readme' },
    ];
    const pick = await vscode.window.showQuickPick(items, { title: `BadgerLabs offload PC (${host()})`, placeHolder: 'Choose an action' });
    if (pick && pick.cmd) vscode.commands.executeCommand(pick.cmd);
  },
};

function activate(context) {
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

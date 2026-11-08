// Computing Power Network - side panel next to the Claude chat.
// Lists your nuclear powerplants (Tailscale names processingoffloadpc*) with a live dot and their
// specs, and runs quick actions on the selected one through Windows' own ssh.exe and the
// powerplant's power.sh. Open it with /cpn.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Panel, Plant } from '../types'

type $T = EngineInterface

const PANE = 'computing-power-network'
const PREFIX = 'processingoffloadpc'
const SSH = 'C:\\Windows\\System32\\OpenSSH\\ssh.exe'   // Git's ssh hangs with Tailscale SSH
const POWER = 'bash ~/ros2-remote/processingoffloadPC/power.sh'
const TAILSCALE = ['tailscale', 'C:\\Program Files\\Tailscale\\tailscale.exe',
  ...'DEFGHIJ'.split('').map(d => `${d}:\\Programs\\Tailscale\\tailscale.exe`)]

const plants = atom({ plugin: 'computing-power-network', key: 'plants' } as const, [] as Plant[], { shape: 'plants-1' })
const panel = atom({ plugin: 'computing-power-network', key: 'panel' } as const,
  { selected: '', busy: '', output: [], canForce: '', user: '', lastRefresh: 0 } as Panel, { shape: 'panel-1' })

const short = (h: string) => (h === PREFIX ? 'main' : h.replace(`${PREFIX}-`, ''))

async function run($: $T, argv: string[], timeoutMs = 30000) {
  try {
    return await $.process.run(argv, { timeoutMs })
  } catch (err) {
    return { exitCode: 124, stdout: '', stderr: String(err) }
  }
}

async function ssh($: $T, user: string, host: string, cmd: string, timeoutMs = 40000) {
  return run($, [SSH, '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new',
    `${user}@${host}`, cmd], timeoutMs)
}

async function ubuntuUser($: $T): Promise<string> {
  const saved = (await $.store.get('user')) as string | undefined
  if (saved) return saved
  const r = await run($, ['wsl.exe', '-d', 'Ubuntu-24.04', '--exec', 'whoami'], 15000)
  const guess = r.stdout.replace(/\0/g, '').trim()
  if (/^[a-z_][a-z0-9_-]*$/.test(guess) && guess !== 'root') {
    await $.store.set('user', guess)
    return guess
  }
  return ''
}

async function discover($: $T): Promise<string[]> {
  for (const exe of TAILSCALE) {
    const r = await run($, [exe, 'status'], 10000)
    if (r.exitCode === 0 && r.stdout) {
      return [...new Set(r.stdout.split(/\r?\n/).map(l => l.trim().split(/\s+/)[1] ?? '')
        .filter(n => n.startsWith(PREFIX)))].sort()
    }
  }
  return []
}

async function refresh($: $T) {
  const user = await ubuntuUser($)
  await update($, panel, p => ({ ...p, user }))
  const hosts = await discover($)
  const list = await Promise.all(hosts.map(async (host): Promise<Plant> => {
    const blank: Plant = { host, online: false, specs: '', gpuUtil: 0, vramUsedGb: 0, vramTotalGb: 0, load: 0,
      threads: 0, ownerActive: false, paused: false, available: true, verified: null, jobs: 0 }
    if (!user) return blank
    const r = await ssh($, user, host, `${POWER} capacity`, 40000)
    if (r.exitCode !== 0) return blank
    try {
      const c = JSON.parse(r.stdout.trim().split(/\r?\n/).pop() ?? '{}')
      return {
        ...blank, online: true, specs: c.specs ?? '', gpuUtil: c.gpu_util ?? 0,
        vramUsedGb: (c.vram_used_mb ?? 0) / 1024, vramTotalGb: (c.vram_total_mb ?? 0) / 1024,
        load: c.load1 ?? 0, threads: c.threads ?? 0, ownerActive: c.owner_idle_s >= 0 && c.owner_idle_s < 600,
        paused: !!c.paused, available: c.available !== false, verified: c.verified ?? null, jobs: c.jobs_running ?? 0,
      }
    } catch {
      return { ...blank, online: true }   // reachable, old scripts without "capacity"
    }
  }))
  await update($, plants, () => list)
  await update($, panel, p => ({ ...p, lastRefresh: Date.now(), selected: p.selected || list[0]?.host || '' }))
}

async function action($: $T, label: string, cmd: string, force = '') {
  const p = await read($, panel)
  if (!p.selected || !p.user || p.busy) return
  await update($, panel, x => ({ ...x, busy: label, canForce: '', output: [`${label} on ${short(x.selected)}...`] }))
  const r = await ssh($, p.user, p.selected, cmd, 180000)
  const lines = `${r.stdout}\n${r.stderr}`.replace(/\x1b\[[0-9;]*m/g, '').split(/\r?\n/).filter(l => l.trim())
  await update($, panel, x => ({ ...x, busy: '', output: lines.slice(-24), canForce: r.exitCode === 2 ? force : '' }))
  if (r.exitCode === 2) $.ui.toast(`${short(p.selected)} is busy - not done`)
  void refresh($)
}

async function wake($: $T) {
  const p = await read($, panel)
  if (!p.selected || !p.user) return
  const info = ((await $.store.get(`wake:${p.selected}`)) ?? {}) as { mac?: string; topic?: string }
  if (!info.mac || !info.topic) {
    await update($, panel, x => ({ ...x, output: ['MAC / wake topic unknown: press Status once while it is online.'] }))
    return
  }
  const res = await $.http.fetch(`https://ntfy.sh/${info.topic}`, { method: 'POST', body: `wake ${info.mac}` })
  await update($, panel, x => ({ ...x, output: [res.ok ? `Wake sent to ${short(x.selected)}'s wake listener (${info.mac}).`
    : `Could not reach ntfy.sh (${res.status}).`, 'It needs a wake listener running on its home network.'] }))
}

async function status($: $T) {
  await action($, 'status', `${POWER} status`)
  const p = await read($, panel)
  const mac = p.output.find(l => l.startsWith('MAC:'))?.slice(4).trim()
  const topic = p.output.find(l => l.startsWith('WakeTopic:'))?.slice(10).trim()
  if (mac && topic) await $.store.set(`wake:${p.selected}`, { mac, topic })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'cpn', description: 'Computing Power Network: show your nuclear powerplants' })
    void $.ui.open({ id: PANE, title: 'Computing Power Network' })
    void refresh($)
    $.clock.every(60000, () => { void refresh($) })
    return next(e)
  })

  on('command.run', { command: 'cpn' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Computing Power Network' })
    void refresh($)
    return { text: 'Computing Power Network panel opened.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const list = await read($, plants)
    const p = await read($, panel)
    const sel = list.find(x => x.host === p.selected)
    const dot = (x: Plant) => (!x.online ? 'red' : !x.available ? 'blue' : x.paused || x.ownerActive ? 'yellow' : 'green')
    const act = (label: string, fn: () => unknown) => (
      <Button key={label} label={p.busy === label ? `${label}...` : label} onPress={() => { void fn() }} />
    )
    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="column">
          <Text bold>Nuclear powerplants</Text>
          <Text dimColor>
            {p.user ? `user ${p.user}` : 'Ubuntu user unknown (run SETUP-my-PC)'} · {list.filter(x => x.online).length}/{list.length} online
          </Text>
        </Box>
        <Box flexDirection="column">
          {list.length === 0 && <Text dimColor>No powerplants found (is Tailscale signed in?).</Text>}
          {list.map(x => (
            <Button key={x.host} onPress={() => update($, panel, q => ({ ...q, selected: x.host, output: [], canForce: '' }))}>
              <Text color={dot(x)}>● </Text>
              <Text bold={x.host === p.selected}>{(x.specs.split('|')[0] ?? '').trim() || short(x.host)}</Text>
              <Text dimColor> {short(x.host)}</Text>
            </Button>
          ))}
        </Box>
        {sel && (
          <Box flexDirection="column">
            <Text>{sel.specs.split('|').map(s => s.trim()).filter(Boolean).join(' · ') || sel.host}</Text>
            {sel.online ? (
              <Text dimColor>
                GPU {sel.gpuUtil.toFixed(0)}% · VRAM {sel.vramUsedGb.toFixed(1)}/{sel.vramTotalGb.toFixed(0)} GB · CPU {sel.load.toFixed(1)}/{sel.threads}
                {' · '}{sel.jobs} job(s){sel.paused ? ' · JOB PAUSED' : ''}{sel.ownerActive ? ' · owner active' : ''}
                {!sel.available ? ' · not shared' : ''}{sel.verified === true ? ' · hw verified' : sel.verified === false ? ' · HW NOT VERIFIED' : ''}
              </Text>
            ) : (
              <Text color="red">offline (asleep or off)</Text>
            )}
          </Box>
        )}
        {sel && (
          <Box flexDirection="row" gap={1} wrap="wrap">
            {act('Status', () => status($))}
            {act('Processes', () => action($, 'Processes', `${POWER} processes`))}
            {act('Start', () => action($, 'Start', `${POWER} start`))}
            {act('Sleep', () => action($, 'Sleep', `${POWER} sleep`, 'sleep'))}
            {act('Sleep after finish', () => action($, 'Sleep after finish', `${POWER} sleep-after-finish`))}
            {act('Wake', () => wake($))}
            {act('Resume job', () => action($, 'Resume job', `${POWER} resume`))}
            {act('Refresh', () => refresh($))}
          </Box>
        )}
        {p.canForce && (
          <Button key="force" label={`${p.canForce} anyway`} onPress={() => { void action($, `${p.canForce} (forced)`, `${POWER} ${p.canForce} --force`) }} />
        )}
        {p.output.length > 0 && (
          <Box flexDirection="column">
            {p.output.map((l, i) => (
              <Text key={String(i)} dimColor={!l.startsWith('VERDICT')} color={l.startsWith('VERDICT: BUSY') ? 'yellow' : l.startsWith('VERDICT: IDLE') ? 'green' : undefined}>
                {l}
              </Text>
            ))}
          </Box>
        )}
      </Box>
    )
  })
}

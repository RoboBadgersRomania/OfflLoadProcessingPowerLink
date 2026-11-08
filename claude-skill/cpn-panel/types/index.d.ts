export type Plant = {
  host: string
  online: boolean
  specs: string
  gpuUtil: number
  vramUsedGb: number
  vramTotalGb: number
  load: number
  threads: number
  ownerActive: boolean
  paused: boolean
  available: boolean
  verified: boolean | null
  jobs: number
}

export type Panel = {
  selected: string
  busy: string
  output: string[]
  /** a refused (busy) action the user may force: "sleep" | "sleep-after-finish" | "off" | "" */
  canForce: string
  user: string
  lastRefresh: number
}

declare module 'claude-code' {
  interface PluginState {
    'computing-power-network': { plants: Shaped<Plant[]>; panel: Shaped<Panel> }
  }
}

import { create } from 'zustand'
import {
  REMOTE_CLIENT_HEADER,
  type RemoteCommand,
  type RemoteQuery,
  type RemoteQueryResultMap,
  type RemoteQueue,
  type RemoteState,
} from './protocol'

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message)
  }
}

/** What last went wrong, shown under "Details" so a failure can be diagnosed. */
function noteProblem(problem: string) {
  useRemote.setState((current) => ({ diag: { ...current.diag, lastProblem: `${clock()} ${problem}` } }))
}

function clock(): string {
  return new Date().toLocaleTimeString('en-GB', { hour12: false })
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const kind = (body as { type?: string } | null)?.type ?? '?'
  let response: Response
  try {
    response = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', [REMOTE_CLIENT_HEADER]: '1' },
      body: JSON.stringify(body),
      cache: 'no-store',
    })
  } catch (error) {
    noteProblem(`${path} ${kind}: connection failed (${error instanceof Error ? error.message : String(error)})`)
    throw new ApiError('Couldn’t send that to the Mac (connection failed).', 0)
  }
  const payload = await response.json().catch(() => null) as { value?: T; error?: string } | null
  if (!response.ok) {
    noteProblem(`${path} ${kind}: HTTP ${response.status} ${payload?.error ?? ''}`.trim())
    throw new ApiError(payload?.error ?? `Request failed (${response.status})`, response.status)
  }
  return payload?.value as T
}

export function query<K extends RemoteQuery['type']>(q: Extract<RemoteQuery, { type: K }>): Promise<RemoteQueryResultMap[K]> {
  return post<RemoteQueryResultMap[K]>('/api/query', q)
}

export async function command(c: RemoteCommand): Promise<void> {
  try {
    await post<null>('/api/command', c)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'That didn’t work'
    useRemote.getState().showToast(message, true)
    // A queue edit refused as out of date: fetch the current queue.
    if (error instanceof ApiError && error.status === 409) void refreshQueue()
    throw error
  }
}

/** A command whose answer matters ("Play on this iPhone"); errors are thrown, not shown. */
export function call<T>(c: RemoteCommand): Promise<T> {
  return post<T>('/api/command', c)
}

/** Fire-and-forget command for buttons; errors already show as a toast. */
export function send(c: RemoteCommand) {
  command(c).catch(() => {})
}

interface Toast { id: number; text: string; error: boolean }

export interface Diagnostics {
  mode: 'starting' | 'stream' | 'polling'
  streamOpens: number
  streamErrors: number
  lastStream: string | null
  lastProblem: string | null
}

interface RemoteStore {
  diag: Diagnostics
  connected: boolean
  everConnected: boolean
  state: RemoteState | null
  /** Local clock (ms) when `state` arrived; position is extrapolated from it. */
  receivedAt: number
  queue: RemoteQueue | null
  libraryVersion: number
  toast: Toast | null
  /** Local overrides while a slider is being dragged or a command is in flight. */
  optimistic: Partial<Pick<RemoteState, 'isPlaying' | 'volume' | 'shuffle' | 'repeat'>> & { positionSec?: number; positionAt?: number }
  showToast: (text: string, error?: boolean) => void
  setOptimistic: (patch: RemoteStore['optimistic']) => void
}

let toastId = 0
let toastTimer: ReturnType<typeof setTimeout> | null = null

export const useRemote = create<RemoteStore>((set) => ({
  diag: { mode: 'starting', streamOpens: 0, streamErrors: 0, lastStream: null, lastProblem: null },
  connected: false,
  everConnected: false,
  state: null,
  receivedAt: 0,
  queue: null,
  libraryVersion: 0,
  toast: null,
  optimistic: {},
  showToast: (text, error = false) => {
    const id = ++toastId
    set({ toast: { id, text, error } })
    if (toastTimer) clearTimeout(toastTimer)
    toastTimer = setTimeout(() => {
      set((current) => (current.toast?.id === id ? { toast: null } : {}))
    }, error ? 8000 : 2400)
  },
  setOptimistic: (patch) => set((current) => ({ optimistic: { ...current.optimistic, ...patch } })),
}))

export async function refreshQueue() {
  try {
    const queue = await query({ type: 'queue' })
    useRemote.setState({ queue })
  } catch {
    // The event stream will deliver it when the Mac is back.
  }
}

let lastNotification: string | null = null

function applyState(state: RemoteState, ageMs = 0) {
  lastStateRevision = state.revision
  const previous = useRemote.getState()
  // The server is the truth: clear optimistic values it has now caught up with.
  const optimistic = { ...previous.optimistic }
  if (optimistic.isPlaying === state.isPlaying) delete optimistic.isPlaying
  if (optimistic.shuffle === state.shuffle) delete optimistic.shuffle
  if (optimistic.repeat === state.repeat) delete optimistic.repeat
  if (optimistic.volume !== undefined && Math.abs(optimistic.volume - state.volume) < 0.01) delete optimistic.volume
  if (optimistic.positionSec !== undefined && Math.abs(optimistic.positionSec - state.positionSec) < 2) {
    delete optimistic.positionSec
    delete optimistic.positionAt
  }
  // Back-date by the snapshot's age so the position does not lag when polling.
  useRemote.setState({ state, receivedAt: performance.now() - ageMs, optimistic })

  document.documentElement.style.setProperty('--accent', state.accent)
  document.documentElement.style.setProperty('--accent-ink', inkFor(state.accent))

  // Mac notices ("Added to queue: …") appear as toasts here too.
  if (state.notification && state.notification !== lastNotification) {
    useRemote.getState().showToast(state.notification)
  }
  lastNotification = state.notification

  if (previous.queue && state.queueRevision !== previous.queue.revision) void refreshQueue()
}

/** Dark text on light accents (yellow, graphite), white otherwise. */
function inkFor(hex: string): string {
  const match = /^#?([0-9a-f]{6})$/i.exec(hex.trim())
  if (!match) return '#ffffff'
  const value = parseInt(match[1], 16)
  const r = (value >> 16) & 255
  const g = (value >> 8) & 255
  const b = value & 255
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 165 ? '#121317' : '#ffffff'
}

// ---------------------------------------------------------------------------
// Live updates
//
// The browser's EventSource is not used: Safari on Gavin's iPhone refused to
// open it from this page (the same stream opened fine as a plain tab), while
// ordinary fetch requests worked. So the stream is read with fetch, and if no
// data arrives promptly the remote polls /api/snapshot once a second instead.
// ---------------------------------------------------------------------------

const STREAM_FIRST_DATA_MS = 4000
const STREAM_RETRY_MS = 2000
const POLL_MS = 1000
/** The Mac sends a keep-alive every 15 s; this much silence means the stream is dead. */
const STREAM_SILENCE_MS = 35000

type Mode = 'starting' | 'stream' | 'polling'
let mode: Mode = 'starting'
let started = false
let streamAbort: AbortController | null = null
let pollTimer: ReturnType<typeof setTimeout> | null = null
let lastStateRevision = -1

function setMode(next: Mode) {
  mode = next
  useRemote.setState((current) => ({ diag: { ...current.diag, mode: next } }))
}

function markConnected(connected: boolean, event?: string) {
  useRemote.setState((current) => ({
    connected,
    everConnected: current.everConnected || connected,
    diag: {
      ...current.diag,
      streamOpens: current.diag.streamOpens + (connected && !current.connected ? 1 : 0),
      streamErrors: current.diag.streamErrors + (!connected && current.connected ? 1 : 0),
      lastStream: event ? `${clock()} ${event}` : current.diag.lastStream,
    },
  }))
}

function handleEvent(name: string, data: string) {
  if (name === 'state') applyState(JSON.parse(data) as RemoteState)
  else if (name === 'queue') useRemote.setState({ queue: JSON.parse(data) as RemoteQueue })
  else if (name === 'library') useRemote.setState((current) => ({ libraryVersion: current.libraryVersion + 1 }))
}

/** Splits Server-Sent Events text into events; returns the unfinished remainder. */
function parseFrames(buffer: string, onEvent: (name: string, data: string) => void): string {
  let rest = buffer.replace(/\r\n/g, '\n')
  let end = rest.indexOf('\n\n')
  while (end >= 0) {
    const frame = rest.slice(0, end)
    rest = rest.slice(end + 2)
    let name = 'message'
    const data: string[] = []
    for (const line of frame.split('\n')) {
      if (line.startsWith(':')) continue
      const colon = line.indexOf(':')
      const field = colon >= 0 ? line.slice(0, colon) : line
      const value = colon >= 0 ? line.slice(colon + 1).replace(/^ /, '') : ''
      if (field === 'event') name = value
      else if (field === 'data') data.push(value)
    }
    if (data.length) onEvent(name, data.join('\n'))
    end = rest.indexOf('\n\n')
  }
  return rest
}

async function runStream(): Promise<boolean> {
  const abort = new AbortController()
  streamAbort = abort
  let gotData = false
  const firstDataTimer = setTimeout(() => { if (!gotData) abort.abort() }, STREAM_FIRST_DATA_MS)
  try {
    const response = await fetch('/api/events', { cache: 'no-store', signal: abort.signal, headers: { Accept: 'text/event-stream' } })
    if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    let silenceTimer: ReturnType<typeof setTimeout> | null = null
    const armSilenceTimer = () => {
      if (silenceTimer) clearTimeout(silenceTimer)
      silenceTimer = setTimeout(() => abort.abort(), STREAM_SILENCE_MS)
    }
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      armSilenceTimer()
      if (!gotData) {
        gotData = true
        clearTimeout(firstDataTimer)
        setMode('stream')
        markConnected(true, 'live stream opened')
      }
      buffer = parseFrames(buffer + decoder.decode(value, { stream: true }), handleEvent)
    }
    if (silenceTimer) clearTimeout(silenceTimer)
    markConnected(false, 'live stream ended')
  } catch (error) {
    if (gotData) markConnected(false, `live stream lost (${error instanceof Error ? error.message : String(error)})`)
    else noteProblem(`/api/events: ${abort.signal.aborted ? 'no data within 4 s' : (error instanceof Error ? error.message : String(error))}`)
  } finally {
    clearTimeout(firstDataTimer)
    if (streamAbort === abort) streamAbort = null
  }
  return gotData
}

async function streamLoop() {
  // Keep the stream going while it works; fall back to polling when it doesn't.
  for (;;) {
    const worked = await runStream()
    if (!worked) {
      startPolling()
      return
    }
    await new Promise((resolve) => setTimeout(resolve, STREAM_RETRY_MS))
    if (document.visibilityState === 'hidden') {
      // Resume when the remote is visible again (see connect()).
      setMode('starting')
      return
    }
  }
}

interface Snapshot {
  now: number
  state: RemoteState | null
  queue?: RemoteQueue | null
  library: number
}

let lastLibrary: number | null = null

async function poll() {
  pollTimer = null
  if (mode !== 'polling') return
  try {
    const known = useRemote.getState().queue?.revision
    const response = await fetch(`/api/snapshot${known !== undefined ? `?queue=${known}` : ''}`, { cache: 'no-store' })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const snapshot = await response.json() as Snapshot
    if (!useRemote.getState().connected) markConnected(true, 'checking every second')
    if (snapshot.state && snapshot.state.revision !== lastStateRevision) {
      applyState(snapshot.state, Math.max(0, snapshot.now - snapshot.state.sentAt))
    }
    if (snapshot.queue) useRemote.setState({ queue: snapshot.queue })
    if (lastLibrary !== null && snapshot.library !== lastLibrary) {
      useRemote.setState((current) => ({ libraryVersion: current.libraryVersion + 1 }))
    }
    lastLibrary = snapshot.library
  } catch (error) {
    if (useRemote.getState().connected) markConnected(false, `check failed (${error instanceof Error ? error.message : String(error)})`)
  }
  if (mode === 'polling' && document.visibilityState === 'visible') pollTimer = setTimeout(poll, POLL_MS)
}

/**
 * Fetches the latest state once, whatever the connection mode. Used while the
 * iPhone plays with its screen locked, when Safari pauses the live stream.
 */
export async function pollOnce(): Promise<void> {
  try {
    const response = await fetch('/api/snapshot', { cache: 'no-store' })
    if (!response.ok) return
    const snapshot = await response.json() as Snapshot
    if (snapshot.state && snapshot.state.revision !== lastStateRevision) {
      applyState(snapshot.state, Math.max(0, snapshot.now - snapshot.state.sentAt))
    }
    if (snapshot.queue) useRemote.setState({ queue: snapshot.queue })
  } catch {
    // The next check or the live stream catches up.
  }
}

function startPolling() {
  setMode('polling')
  if (!pollTimer) void poll()
}

export function connect() {
  if (started) return
  started = true
  setMode('starting')
  void streamLoop()
  // iOS suspends pages in the background; catch up straight away on return.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible') return
    if (mode === 'polling') {
      if (!pollTimer) void poll()
    } else if (!streamAbort) {
      void streamLoop()
    }
  })
}

/** The playback position right now, extrapolated between updates while playing. */
export function currentPosition(store: Pick<RemoteStore, 'state' | 'receivedAt' | 'optimistic'>, now = performance.now()): number {
  const { state, optimistic } = store
  if (!state) return 0
  const playing = optimistic.isPlaying ?? state.isPlaying
  if (optimistic.positionSec !== undefined) {
    const since = playing && optimistic.positionAt ? (now - optimistic.positionAt) / 1000 : 0
    return clampPosition(optimistic.positionSec + since, state.durationSec)
  }
  const elapsed = playing && !state.track?.isRadio ? (now - store.receivedAt) / 1000 : 0
  return clampPosition(state.positionSec + elapsed, state.durationSec)
}

function clampPosition(value: number, duration: number) {
  return duration > 0 ? Math.max(0, Math.min(value, duration)) : Math.max(0, value)
}

export function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0
  const whole = Math.floor(seconds)
  const h = Math.floor(whole / 3600)
  const m = Math.floor((whole % 3600) / 60)
  const s = whole % 60
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`
}

export function formatTotal(seconds: number): string {
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return rest ? `${hours} hr ${rest} min` : `${hours} hr`
}

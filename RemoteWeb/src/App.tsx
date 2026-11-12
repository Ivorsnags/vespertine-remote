import { useEffect, useState } from 'react'
import { AudioLines, ChevronDown, Library, Loader2, Search, WifiOff } from 'lucide-react'
import { useRemote } from './api'
import { useNav, type Tab } from './nav'
import { SheetHost, useSheet } from './ui'
import NowPlaying, { MiniPlayer } from './components/NowPlaying'
import Queue from './components/Queue'
import { LibraryRoot, RoutePage } from './components/Library'
import { SearchRoot } from './components/Search'

const TABS: Array<{ id: Tab; label: string; icon: typeof Library; className?: string }> = [
  { id: 'now', label: 'Playing', icon: AudioLines, className: 'tab-now' },
  { id: 'library', label: 'Library', icon: Library },
  { id: 'search', label: 'Search', icon: Search },
]

const ROOTS: Record<Exclude<Tab, 'now'>, () => JSX.Element> = {
  library: () => <LibraryRoot />,
  search: () => <SearchRoot />,
}

/** The queue, opened from Now Playing, over everything (like Apple Music). */
function QueuePanel() {
  const open = useNav((s) => s.queueOpen)
  const setOpen = useNav((s) => s.setQueueOpen)
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false) }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, setOpen])
  if (!open) return null
  return (
    <div className="queue-panel" role="dialog" aria-modal="true" aria-label="Queue">
      <div className="queue-panel-bar">
        <button type="button" className="queue-panel-close" onClick={() => setOpen(false)} aria-label="Close queue">
          <ChevronDown size={26} strokeWidth={2.2} aria-hidden />
        </button>
        <button type="button" className="queue-panel-done" onClick={() => setOpen(false)}>Done</button>
      </div>
      <div className="scroll">
        <Queue />
      </div>
    </div>
  )
}

/** iPad and wide windows show Now Playing permanently beside the content. */
function useWideLayout(): boolean {
  const query = '(min-width: 900px)'
  const [wide, setWide] = useState(() => window.matchMedia(query).matches)
  useEffect(() => {
    const media = window.matchMedia(query)
    const update = () => setWide(media.matches)
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])
  return wide
}

function ConnectionNotice() {
  const connected = useRemote((s) => s.connected)
  const everConnected = useRemote((s) => s.everConnected)
  const [patient, setPatient] = useState(false)

  useEffect(() => {
    if (connected) {
      setPatient(false)
      return
    }
    const timer = window.setTimeout(() => setPatient(true), 4000)
    return () => window.clearTimeout(timer)
  }, [connected])

  if (connected) return null
  if (everConnected || !patient) {
    return (
      <div className="banner" role="status">
        <Loader2 size={15} className="spin" aria-hidden />
        {everConnected ? 'Reconnecting to the Mac…' : 'Connecting to the Mac…'}
      </div>
    )
  }
  return (
    <div className="offline" role="alert">
      <WifiOff size={40} strokeWidth={1.5} aria-hidden />
      <strong>Can’t reach the Mac</strong>
      <span>Make sure the Mac is awake, GR Player is switched on in the Mac app, and this device is on the same Wi-Fi.</span>
      <span className="offline-hint">It will reconnect by itself.</span>
      <ConnectionDetails />
    </div>
  )
}

/** Plain facts about the connection, for diagnosing problems. */
export function ConnectionDetails({ open = false }: { open?: boolean }) {
  const diag = useRemote((s) => s.diag)
  const connected = useRemote((s) => s.connected)
  return (
    <details className="details" open={open}>
      <summary>Details</summary>
      <dl>
        <dt>Address</dt><dd>{window.location.host}</dd>
        <dt>Live updates</dt><dd>{connected ? 'connected' : 'not connected'} · {diag.mode === 'stream' ? 'live stream' : diag.mode === 'polling' ? 'checking every second' : 'starting'} · connected {diag.streamOpens}× · lost {diag.streamErrors}×</dd>
        <dt>Last event</dt><dd>{diag.lastStream ?? 'none yet'}</dd>
        <dt>Last problem</dt><dd>{diag.lastProblem ?? 'none'}</dd>
        <dt>Browser</dt><dd>{navigator.userAgent}</dd>
      </dl>
    </details>
  )
}

function Toast() {
  const toast = useRemote((s) => s.toast)
  if (!toast) return null
  if (!toast.error) return <div key={toast.id} className="toast" role="status">{toast.text}</div>
  // Error toasts open the connection details, so a failure can be reported precisely.
  return (
    <button
      key={toast.id}
      type="button"
      className="toast error"
      role="alert"
      onClick={() => {
        useRemote.setState({ toast: null })
        useSheet.getState().open({ title: 'What went wrong', subtitle: toast.text, actions: [], body: <ConnectionDetails open /> })
      }}
    >
      {toast.text} <span style={{ opacity: 0.7 }}>· Details</span>
    </button>
  )
}

export default function App() {
  const wide = useWideLayout()
  const tab = useNav((s) => s.tab)
  const stacks = useNav((s) => s.stacks)
  const setTab = useNav((s) => s.setTab)
  const hasTrack = useRemote((s) => !!s.state?.track)

  // The Now Playing tab does not exist in the two-column layout.
  const activeTab: Tab = wide && tab === 'now' ? 'library' : tab
  const stack = activeTab === 'now' ? null : stacks[activeTab]
  const route = stack ? stack[stack.length - 1] : null

  return (
    <div className="app">
      <div className="panes">
        {wide && (
          <aside className="pane-now" aria-label="Now Playing">
            <NowPlaying />
          </aside>
        )}
        <main className="pane-main">
          {activeTab === 'now'
            ? <NowPlaying />
            : (
              <div className="scroll" key={`${activeTab}:${stack!.length}`}>
                <RoutePage route={route!} root={ROOTS[activeTab]} />
              </div>
            )}
          {!wide && activeTab !== 'now' && hasTrack && <MiniPlayer onOpen={() => setTab('now')} />}
        </main>
      </div>
      <nav className="tabbar" aria-label="Sections">
        {TABS.filter((entry) => !(wide && entry.id === 'now')).map((entry) => (
          <button
            key={entry.id}
            type="button"
            className={entry.className}
            aria-current={activeTab === entry.id ? 'page' : undefined}
            onClick={() => setTab(entry.id)}
          >
            <entry.icon size={24} strokeWidth={activeTab === entry.id ? 2.2 : 1.8} aria-hidden />
            {entry.label}
          </button>
        ))}
      </nav>
      <QueuePanel />
      <ConnectionNotice />
      <Toast />
      <SheetHost />
    </div>
  )
}

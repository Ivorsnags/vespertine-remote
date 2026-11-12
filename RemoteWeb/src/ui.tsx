import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { create } from 'zustand'
import { Disc3, Music2, User, type LucideIcon } from 'lucide-react'
import { ApiError, useRemote } from './api'

// ---------------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------------

export function Artwork({
  src,
  className = '',
  kind = 'album',
  alt = '',
}: {
  src: string | null | undefined
  className?: string
  kind?: 'album' | 'artist' | 'track'
  alt?: string
}) {
  const [failed, setFailed] = useState(false)
  useEffect(() => setFailed(false), [src])
  const Fallback = kind === 'artist' ? User : kind === 'track' ? Music2 : Disc3
  return (
    <div className={`art ${className}`}>
      {src && !failed
        ? <img src={src} alt={alt} loading="lazy" decoding="async" onError={() => setFailed(true)} draggable={false} />
        : <span className="art-fallback"><Fallback size={28} strokeWidth={1.5} /></span>}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Slider: thin track, large touch area, commits on release
// ---------------------------------------------------------------------------

export function Slider({
  value,
  onChange,
  onCommit,
  disabled = false,
  label,
  valueText,
}: {
  value: number
  onChange?: (value: number) => void
  onCommit: (value: number) => void
  disabled?: boolean
  label: string
  valueText?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [drag, setDrag] = useState<number | null>(null)
  const shown = drag ?? value

  const fractionAt = (clientX: number) => {
    const rect = ref.current!.getBoundingClientRect()
    return Math.max(0, Math.min(1, (clientX - rect.left) / rect.width))
  }

  return (
    <div
      ref={ref}
      className={`slider ${drag !== null ? 'active' : ''} ${disabled ? 'disabled' : ''}`}
      role="slider"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(shown * 100)}
      aria-valuetext={valueText}
      aria-disabled={disabled}
      tabIndex={disabled ? -1 : 0}
      onPointerDown={(event) => {
        if (disabled) return
        event.currentTarget.setPointerCapture(event.pointerId)
        const next = fractionAt(event.clientX)
        setDrag(next)
        onChange?.(next)
      }}
      onPointerMove={(event) => {
        if (drag === null) return
        const next = fractionAt(event.clientX)
        setDrag(next)
        onChange?.(next)
      }}
      onPointerUp={(event) => {
        if (drag === null) return
        const next = fractionAt(event.clientX)
        setDrag(null)
        onCommit(next)
      }}
      onPointerCancel={() => setDrag(null)}
      onKeyDown={(event) => {
        if (disabled) return
        const step = event.key === 'ArrowRight' || event.key === 'ArrowUp' ? 0.05 : event.key === 'ArrowLeft' || event.key === 'ArrowDown' ? -0.05 : 0
        if (step) {
          event.preventDefault()
          onCommit(Math.max(0, Math.min(1, value + step)))
        }
      }}
    >
      <div className="slider-track">
        <div className="slider-fill" style={{ width: `${shown * 100}%` }} />
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Action sheets
// ---------------------------------------------------------------------------

export interface SheetAction {
  label: string
  icon: LucideIcon
  run: () => void
  selected?: boolean
  disabled?: boolean
}

export interface SheetContent {
  title: string
  subtitle?: string | null
  artwork?: string | null
  artworkKind?: 'album' | 'artist' | 'track'
  actions: SheetAction[]
  note?: string | null
  body?: ReactNode
}

export const useSheet = create<{ sheet: SheetContent | null; open: (sheet: SheetContent) => void; close: () => void }>((set) => ({
  sheet: null,
  open: (sheet) => set({ sheet }),
  close: () => set({ sheet: null }),
}))

export function SheetHost() {
  const sheet = useSheet((s) => s.sheet)
  const close = useSheet((s) => s.close)
  useEffect(() => {
    if (!sheet) return
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') close() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [sheet, close])
  if (!sheet) return null
  return (
    <div className="sheet-scrim" onClick={close} role="presentation">
      <div className="sheet" role="dialog" aria-modal="true" aria-label={sheet.title} onClick={(event) => event.stopPropagation()}>
        <div className="sheet-grabber" />
        <div className="sheet-head">
          {sheet.artwork !== undefined && <Artwork src={sheet.artwork} kind={sheet.artworkKind} />}
          <div className="row-text">
            <div className="row-title" style={{ fontWeight: 600 }}>{sheet.title}</div>
            {sheet.subtitle && <div className="row-sub">{sheet.subtitle}</div>}
          </div>
        </div>
        {sheet.body}
        {sheet.actions.map((action) => (
          <button
            key={action.label}
            type="button"
            className={`sheet-action ${action.selected ? 'selected' : ''}`}
            disabled={action.disabled}
            onClick={() => {
              close()
              action.run()
            }}
          >
            <action.icon size={22} />
            <span>{action.label}</span>
          </button>
        ))}
        {sheet.note && <p className="sheet-note">{sheet.note}</p>}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Data loading with a small cache, refreshed when the library changes
// ---------------------------------------------------------------------------

const cache = new Map<string, { version: number; value: unknown }>()

export function useLoad<T>(key: string, load: () => Promise<T>): {
  data: T | undefined
  error: string | null
  loading: boolean
  reload: () => void
} {
  const libraryVersion = useRemote((s) => s.libraryVersion)
  const cached = cache.get(key)
  const [data, setData] = useState<T | undefined>(cached?.value as T | undefined)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(!cached)
  const [nonce, setNonce] = useState(0)
  const loadRef = useRef(load)
  loadRef.current = load

  useEffect(() => {
    const entry = cache.get(key)
    if (entry) setData(entry.value as T)
    if (entry && entry.version === libraryVersion && nonce === 0) {
      setLoading(false)
      return
    }
    let cancelled = false
    setLoading(!entry)
    loadRef.current().then((value) => {
      if (cancelled) return
      cache.set(key, { version: libraryVersion, value })
      setData(value)
      setError(null)
      setLoading(false)
    }).catch((reason: unknown) => {
      if (cancelled) return
      setError(reason instanceof ApiError || reason instanceof Error ? reason.message : 'Could not load this')
      setLoading(false)
    })
    return () => { cancelled = true }
  }, [key, libraryVersion, nonce])

  const reload = useCallback(() => setNonce((n) => n + 1), [])
  return { data, error, loading, reload }
}

export function Status({ loading, error, empty, emptyTitle, emptyHint, onRetry }: {
  loading: boolean
  error: string | null
  empty: boolean
  emptyTitle: string
  emptyHint?: string
  onRetry?: () => void
}) {
  if (loading) return <div className="empty">Loading…</div>
  if (error) {
    return (
      <div className="empty">
        <strong>Couldn’t load this</strong>
        {error}
        {onRetry && <div className="button-row" style={{ justifyContent: 'center' }}><button type="button" className="button" style={{ flex: '0 0 auto', padding: '0 20px' }} onClick={onRetry}>Try again</button></div>}
      </div>
    )
  }
  if (empty) return <div className="empty"><strong>{emptyTitle}</strong>{emptyHint}</div>
  return null
}

/** Long-press (or right-click) opens a menu; a normal tap does `onTap`. */
export function usePress(onTap: () => void, onLongPress: () => void) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const fired = useRef(false)
  const start = useRef<{ x: number; y: number } | null>(null)
  const clear = () => {
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
  }
  return {
    onPointerDown: (event: React.PointerEvent) => {
      fired.current = false
      start.current = { x: event.clientX, y: event.clientY }
      clear()
      timer.current = setTimeout(() => {
        fired.current = true
        navigator.vibrate?.(10)
        onLongPress()
      }, 480)
    },
    onPointerMove: (event: React.PointerEvent) => {
      if (start.current && Math.hypot(event.clientX - start.current.x, event.clientY - start.current.y) > 10) clear()
    },
    onPointerUp: clear,
    onPointerCancel: clear,
    onClick: () => {
      if (fired.current) return
      onTap()
    },
    onContextMenu: (event: React.MouseEvent) => {
      event.preventDefault()
      clear()
      fired.current = true
      onLongPress()
    },
  }
}

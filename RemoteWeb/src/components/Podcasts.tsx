import { useEffect, useRef, useState } from 'react'
import {
  ArrowDownToLine, Check, CircleAlert, CircleCheck, Loader2, Pause, Play, Plus, Search as SearchIcon, Square, Trash2, X,
} from 'lucide-react'
import type { RemotePodcastDirectoryShow, RemotePodcastEpisode } from '../protocol'
import { PODCAST_GENRES } from '../podcastGenres'
import { command, query, send, useRemote } from '../api'
import { useNav, type PodcastSection } from '../nav'
import { Artwork, Status, useLoad, usePress, useSheet } from '../ui'
import { BackButton } from './common'

// ---------------------------------------------------------------------------
// Wording
// ---------------------------------------------------------------------------

function episodeDate(at: number | null): string {
  if (!at) return ''
  const date = new Date(at)
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const days = Math.floor((today.getTime() - new Date(at).setHours(0, 0, 0, 0)) / 86_400_000)
  if (days <= 0) return 'TODAY'
  if (days === 1) return 'YESTERDAY'
  if (days < 7) return date.toLocaleDateString('en-GB', { weekday: 'long' }).toUpperCase()
  const sameYear = date.getFullYear() === today.getFullYear()
  return date.toLocaleDateString('en-GB', sameYear ? { day: 'numeric', month: 'short' } : { day: 'numeric', month: 'short', year: 'numeric' })
    .replace('Sept', 'Sep').toUpperCase()
}

function length(seconds: number | null | undefined): string {
  if (!seconds || seconds <= 0) return ''
  const minutes = Math.round(seconds / 60)
  if (minutes < 1) return 'under 1 min'
  const hours = Math.floor(minutes / 60)
  if (hours === 0) return `${minutes} min`
  return minutes % 60 === 0 ? `${hours} hr` : `${hours} hr ${minutes % 60} min`
}

function playLabel(episode: RemotePodcastEpisode): string {
  if (episode.played) return 'Played'
  if (episode.positionSec > 0 && episode.durationSec) return `${length(Math.max(0, episode.durationSec - episode.positionSec)) || 'under 1 min'} left`
  return length(episode.durationSec) || 'Play'
}

/** While a download runs, the page reloads every couple of seconds to show its progress. */
function useRefreshWhileDownloading(episodes: RemotePodcastEpisode[] | undefined, reload: () => void) {
  const active = !!episodes?.some((episode) => episode.download === 'downloading' || episode.download === 'queued')
  useEffect(() => {
    if (!active) return
    const timer = window.setInterval(reload, 2000)
    return () => window.clearInterval(timer)
  }, [active, reload])
}

// ---------------------------------------------------------------------------
// Episodes
// ---------------------------------------------------------------------------

function useEpisodeState(episodeId: string): 'playing' | 'paused' | null {
  return useRemote((s) => {
    const track = s.state?.track
    if (!track?.isPodcast || track.podcastEpisodeId !== episodeId) return null
    const playing = s.optimistic.isPlaying ?? s.state?.isPlaying
    return playing ? 'playing' : 'paused'
  })
}

function openEpisodeSheet(episode: RemotePodcastEpisode) {
  const downloaded = episode.download === 'downloaded'
  const busy = episode.download === 'downloading' || episode.download === 'queued'
  useSheet.getState().open({
    title: episode.title,
    subtitle: [episode.showTitle, episodeDate(episode.publishedAt), length(episode.durationSec)].filter(Boolean).join(' · '),
    artwork: episode.artwork,
    artworkKind: 'album',
    body: episode.summary ? <p className="episode-notes">{episode.summary}</p> : undefined,
    actions: [
      { label: episode.positionSec > 0 && !episode.played ? 'Resume' : 'Play', icon: Play, run: () => send({ type: 'podcast-play', episodeId: episode.id }) },
      episode.played
        ? { label: 'Mark as Unplayed', icon: X, run: () => send({ type: 'podcast-played', episodeId: episode.id, played: false }) }
        : { label: 'Mark as Played', icon: Check, run: () => send({ type: 'podcast-played', episodeId: episode.id, played: true }) },
      downloaded
        ? { label: 'Remove Download', icon: Trash2, run: () => send({ type: 'podcast-delete-download', episodeId: episode.id }) }
        : busy
          ? { label: 'Stop Download', icon: Square, run: () => send({ type: 'podcast-cancel-download', episodeId: episode.id }) }
          : { label: 'Download to the Mac', icon: ArrowDownToLine, run: () => send({ type: 'podcast-download', episodeId: episode.id }) },
    ],
  })
}

function DownloadMark({ episode }: { episode: RemotePodcastEpisode }) {
  if (episode.download === 'downloaded') return <CircleCheck size={16} className="episode-mark" aria-label="Downloaded" />
  if (episode.download === 'failed') return <CircleAlert size={16} className="episode-mark failed" aria-label="Download failed" />
  if (episode.download === 'downloading' || episode.download === 'queued') {
    const pct = Math.round((episode.downloadProgress ?? 0) * 100)
    return (
      <span className="episode-mark" aria-label={`Downloading ${pct}%`}>
        <Loader2 size={14} className="spin" aria-hidden /> {episode.download === 'downloading' && pct > 0 ? `${pct}%` : ''}
      </span>
    )
  }
  return null
}

function EpisodeRow({ episode, showShow = false }: { episode: RemotePodcastEpisode; showShow?: boolean }) {
  const state = useEpisodeState(episode.id)
  const setOptimistic = useRemote((s) => s.setOptimistic)
  const press = usePress(() => openEpisodeSheet(episode), () => openEpisodeSheet(episode))
  const fraction = episode.durationSec && episode.positionSec > 0 && !episode.played ? Math.min(1, episode.positionSec / episode.durationSec) : 0
  const meta = [showShow ? episode.showTitle : null, episodeDate(episode.publishedAt)].filter(Boolean).join(' · ')

  return (
    <div className="episode">
      {showShow && <Artwork src={episode.artwork} className="episode-art" />}
      <div className="episode-body">
        <button type="button" className="episode-text" {...press} aria-label={`${episode.title}. Show notes and options`}>
          <span className="episode-meta">
            {episode.isNew && !episode.played && <span className="episode-dot" aria-label="New" />}
            {meta}
          </span>
          <span className={`episode-title ${episode.played ? 'played' : ''}`}>{episode.title}</span>
          {episode.summary && <span className="episode-summary">{episode.summary}</span>}
        </button>
        <div className="episode-controls">
          <button
            type="button"
            className={`episode-play ${state ? 'current' : ''}`}
            onClick={() => {
              if (state) {
                setOptimistic({ isPlaying: state !== 'playing' })
                send({ type: 'toggle' })
              } else {
                send({ type: 'podcast-play', episodeId: episode.id })
              }
            }}
          >
            {state === 'playing' ? <Pause size={12} fill="currentColor" strokeWidth={0} /> : episode.played && !state ? <Check size={13} strokeWidth={2.6} /> : <Play size={12} fill="currentColor" strokeWidth={0} />}
            {fraction > 0 && !state && <span className="episode-bar"><span style={{ width: `${Math.max(6, fraction * 100)}%` }} /></span>}
            <span>{state === 'playing' ? 'Playing' : state === 'paused' ? 'Paused' : playLabel(episode)}</span>
          </button>
          <DownloadMark episode={episode} />
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Root: Listen Now, Shows, Browse, Downloads
// ---------------------------------------------------------------------------

const SECTIONS: Array<{ id: PodcastSection; label: string }> = [
  { id: 'listen', label: 'Listen Now' },
  { id: 'shows', label: 'Shows' },
  { id: 'browse', label: 'Browse' },
  { id: 'downloads', label: 'Downloads' },
]

export function PodcastsRoot() {
  const section = useNav((s) => s.podcastSection)
  const setSection = useNav((s) => s.setPodcastSection)
  return (
    <>
      <h1 className="page-title">Podcasts</h1>
      <div className="segmented" role="group" aria-label="Podcasts section">
        {SECTIONS.map((entry) => (
          <button key={entry.id} type="button" aria-pressed={section === entry.id} onClick={() => setSection(entry.id)}>
            {entry.label}
          </button>
        ))}
      </div>
      {section === 'listen' && <ListenNow />}
      {section === 'shows' && <Shows />}
      {section === 'browse' && <Browse />}
      {section === 'downloads' && <Downloads />}
    </>
  )
}

function ListenNow() {
  const { data, error, loading, reload } = useLoad('podcast-home', () => query({ type: 'podcast-home' }))
  useRefreshWhileDownloading(data ? [...data.inProgress, ...data.newEpisodes] : undefined, reload)
  const setSection = useNav((s) => s.setPodcastSection)
  if (!data) return <Status loading={loading} error={error} empty={false} emptyTitle="" onRetry={reload} />
  if (data.inProgress.length === 0 && data.newEpisodes.length === 0) {
    return (
      <div className="empty">
        <strong>You’re up to date</strong>
        New episodes from your shows appear here.
        <div className="button-row" style={{ justifyContent: 'center' }}>
          <button type="button" className="button" style={{ flex: '0 0 auto', padding: '0 20px' }} onClick={() => setSection('browse')}>Browse Podcasts</button>
        </div>
      </div>
    )
  }
  return (
    <>
      {data.inProgress.length > 0 && (
        <>
          <h2 className="section-title">Continue Listening</h2>
          {data.inProgress.map((episode) => <EpisodeRow key={episode.id} episode={episode} showShow />)}
        </>
      )}
      {data.newEpisodes.length > 0 && (
        <>
          <h2 className="section-title">New Episodes</h2>
          {data.newEpisodes.map((episode) => <EpisodeRow key={episode.id} episode={episode} showShow />)}
        </>
      )}
    </>
  )
}

function Shows() {
  const { data, error, loading, reload } = useLoad('podcast-shows', () => query({ type: 'podcast-shows' }))
  const push = useNav((s) => s.push)
  return (
    <>
      <Status
        loading={loading && !data}
        error={data ? null : error}
        empty={!!data && data.length === 0}
        emptyTitle="No shows yet"
        emptyHint="Subscribe from Browse, or import your Apple Podcasts shows on the Mac."
        onRetry={reload}
      />
      {data && data.length > 0 && (
        <div className="grid">
          {data.map((show) => (
            <button key={show.id} type="button" className="tile" onClick={() => push({ kind: 'podcast-show', id: show.id })} aria-label={`${show.title}${show.newCount ? `, ${show.newCount} new` : ''}`}>
              <div className="tile-art-wrap">
                <Artwork src={show.artwork} alt="" />
                {show.newCount > 0 && <span className="tile-badge">{show.newCount > 99 ? '99+' : show.newCount}</span>}
              </div>
              <div className="tile-title">{show.title}</div>
              <div className="tile-sub">{show.author ?? ''}</div>
            </button>
          ))}
        </div>
      )}
    </>
  )
}

let rememberedSearch = ''
let rememberedGenre: number | null = null

function Browse() {
  const [text, setText] = useState(rememberedSearch)
  const [genre, setGenre] = useState<number | null>(rememberedGenre)
  const [results, setResults] = useState<RemotePodcastDirectoryShow[] | null>(null)
  const [busy, setBusy] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [opening, setOpening] = useState<number | null>(null)
  const libraryVersion = useRemote((s) => s.libraryVersion)
  const push = useNav((s) => s.push)
  const request = useRef(0)
  const input = useRef<HTMLInputElement>(null)
  const term = text.trim()

  useEffect(() => {
    rememberedSearch = text
    rememberedGenre = genre
    const id = ++request.current
    setBusy(true)
    setError(null)
    const timer = window.setTimeout(() => {
      const load = term.length >= 2 ? query({ type: 'podcast-search', query: term }) : query({ type: 'podcast-top', genreId: genre })
      load.then((value) => {
        if (id !== request.current) return
        setResults(value)
        setBusy(false)
      }).catch((reason: unknown) => {
        if (id !== request.current) return
        setError(reason instanceof Error ? reason.message : 'Couldn’t load podcasts')
        setBusy(false)
      })
    }, term.length >= 2 ? 400 : 0)
    return () => window.clearTimeout(timer)
    // libraryVersion refreshes the "subscribed" ticks after subscribing.
  }, [term, genre, libraryVersion, text])

  const open = async (show: RemotePodcastDirectoryShow) => {
    if (show.showId) {
      push({ kind: 'podcast-show', id: show.showId })
      return
    }
    setOpening(show.appleId)
    try {
      const detail = await query({ type: 'podcast-open', appleId: show.appleId })
      push({ kind: 'podcast-show', id: detail.id })
    } catch (reason) {
      useRemote.getState().showToast(reason instanceof Error ? reason.message : 'Couldn’t open this show', true)
    } finally {
      setOpening(null)
    }
  }

  return (
    <>
      <label className="search">
        <SearchIcon size={18} aria-hidden />
        <input
          ref={input}
          type="search"
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="Search podcasts"
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="none"
          spellCheck={false}
          enterKeyHint="search"
          onKeyDown={(event) => { if (event.key === 'Enter') input.current?.blur() }}
        />
        {text && (
          <button type="button" className="search-clear" aria-label="Clear search" onClick={() => { setText(''); input.current?.focus() }}>
            <X size={16} />
          </button>
        )}
      </label>

      {term.length < 2 && (
        <div className="chips" role="group" aria-label="Category">
          <button type="button" aria-pressed={genre === null} onClick={() => setGenre(null)}>Top Shows</button>
          {PODCAST_GENRES.map((entry) => (
            <button key={entry.id} type="button" aria-pressed={genre === entry.id} onClick={() => setGenre(entry.id)}>{entry.name}</button>
          ))}
        </div>
      )}

      <h2 className="section-title">
        {term.length >= 2 ? 'Results' : genre ? `Top ${PODCAST_GENRES.find((g) => g.id === genre)?.name ?? ''}` : 'Top Shows'}
      </h2>
      {busy && !results && <div className="empty">Loading…</div>}
      {error && !busy && <div className="empty"><strong>Couldn’t load podcasts</strong>{error}</div>}
      {results && results.length === 0 && !busy && <div className="empty"><strong>No podcasts found</strong>Try fewer words, or the show’s exact name.</div>}
      {results && results.length > 0 && (
        <div className={`grid ${busy ? 'loading' : ''}`}>
          {results.map((show) => (
            <button key={show.appleId} type="button" className="tile" onClick={() => { void open(show) }} aria-label={`${show.title}${show.subscribed ? ', subscribed' : ''}`}>
              <div className="tile-art-wrap">
                <Artwork src={show.artwork} alt="" />
                {opening === show.appleId
                  ? <span className="tile-badge"><Loader2 size={13} className="spin" /></span>
                  : show.subscribed ? <span className="tile-badge"><Check size={13} strokeWidth={3} /></span> : null}
              </div>
              <div className="tile-title">{show.title}</div>
              <div className="tile-sub">{show.author ?? ''}</div>
            </button>
          ))}
        </div>
      )}
    </>
  )
}

function Downloads() {
  const { data, error, loading, reload } = useLoad('podcast-downloads', () => query({ type: 'podcast-downloads' }))
  useRefreshWhileDownloading(data, reload)
  return (
    <>
      <Status
        loading={loading && !data}
        error={data ? null : error}
        empty={!!data && data.length === 0}
        emptyTitle="No downloads"
        emptyHint="Downloaded episodes are kept on the Mac and play without waiting."
        onRetry={reload}
      />
      {data?.map((episode) => <EpisodeRow key={episode.id} episode={episode} showShow />)}
    </>
  )
}

// ---------------------------------------------------------------------------
// Show page
// ---------------------------------------------------------------------------

type EpisodeFilter = 'all' | 'unplayed' | 'downloaded'

export function PodcastShowPage({ id }: { id: string }) {
  const { data: show, error, loading, reload } = useLoad(`podcast-show:${id}`, () => query({ type: 'podcast-show', id }))
  const [filter, setFilter] = useState<EpisodeFilter>('all')
  const [expanded, setExpanded] = useState(false)
  const [limit, setLimit] = useState(60)
  const [subscribing, setSubscribing] = useState(false)
  useRefreshWhileDownloading(show?.episodes, reload)

  if (!show) {
    return (
      <>
        <BackButton />
        <Status loading={loading} error={error} empty={!loading && !error} emptyTitle="Show not found" onRetry={reload} />
      </>
    )
  }

  const episodes = show.episodes.filter((episode) => filter === 'unplayed' ? !episode.played : filter === 'downloaded' ? episode.download === 'downloaded' : true)
  const start = show.episodes.find((e) => e.positionSec > 0 && !e.played) ?? show.episodes.find((e) => !e.played) ?? show.episodes[0]

  const toggleSubscription = async () => {
    setSubscribing(true)
    try {
      await command(show.subscribed ? { type: 'podcast-unsubscribe', showId: show.id } : { type: 'podcast-subscribe', showId: show.id })
      useRemote.getState().showToast(show.subscribed ? `Unsubscribed from ${show.title}` : `Subscribed to ${show.title}`)
      reload()
    } catch {
      // The error toast is already showing.
    } finally {
      setSubscribing(false)
    }
  }

  return (
    <>
      <BackButton />
      <div className="hero">
        <Artwork src={show.artwork} alt={show.title} />
        <div className="row-text">
          <div className="hero-title">{show.title}</div>
          {show.author && <div className="hero-sub">{show.author}</div>}
          <div className="hero-meta">{show.episodeTotal} {show.episodeTotal === 1 ? 'episode' : 'episodes'}</div>
        </div>
      </div>
      <div className="button-row">
        {start && (
          <button type="button" className="button primary" onClick={() => send({ type: 'podcast-play', episodeId: start.id })}>
            <Play size={18} fill="currentColor" aria-hidden /> {start.positionSec > 0 && !start.played ? 'Resume' : start.played ? 'Play Latest' : 'Play'}
          </button>
        )}
        <button type="button" className="button" disabled={subscribing} onClick={() => { void toggleSubscription() }}>
          {subscribing ? <Loader2 size={18} className="spin" aria-hidden /> : show.subscribed ? <Check size={18} aria-hidden /> : <Plus size={18} aria-hidden />}
          {show.subscribed ? 'Subscribed' : 'Subscribe'}
        </button>
      </div>
      {show.description && (
        <button type="button" className={`show-description ${expanded ? 'open' : ''}`} onClick={() => setExpanded((v) => !v)}>
          {show.description}
        </button>
      )}
      <ShowFilter value={filter} onChange={(value) => { setFilter(value); setLimit(60) }} />
      {episodes.length === 0 && (
        <div className="empty">
          <strong>{filter === 'downloaded' ? 'No downloaded episodes' : filter === 'unplayed' ? 'All played' : 'No episodes yet'}</strong>
        </div>
      )}
      {episodes.slice(0, limit).map((episode) => <EpisodeRow key={episode.id} episode={episode} />)}
      {episodes.length > limit && (
        <div className="button-row" style={{ justifyContent: 'center' }}>
          <button type="button" className="button" style={{ flex: '0 0 auto', padding: '0 20px' }} onClick={() => setLimit((n) => n + 120)}>Show More</button>
        </div>
      )}
      {show.episodeTotal > show.episodes.length && episodes.length <= limit && (
        <p className="sheet-note" style={{ textAlign: 'center' }}>The newest {show.episodes.length} episodes are shown here; the Mac has all {show.episodeTotal}.</p>
      )}
    </>
  )
}

function ShowFilter({ value, onChange }: { value: EpisodeFilter; onChange: (value: EpisodeFilter) => void }) {
  return (
    <div className="segmented" role="group" aria-label="Episodes" style={{ marginTop: 18 }}>
      {([['all', 'Episodes'], ['unplayed', 'Unplayed'], ['downloaded', 'Downloaded']] as Array<[EpisodeFilter, string]>).map(([id, label]) => (
        <button key={id} type="button" aria-pressed={value === id} onClick={() => onChange(id)}>{label}</button>
      ))}
    </div>
  )
}


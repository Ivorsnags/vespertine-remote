import { useEffect, useRef, useState } from 'react'
import {
  ListMusic,
  Pause,
  Play,
  Repeat,
  Repeat1,
  Shuffle,
  SkipBack,
  SkipForward,
  Volume1,
  Volume2,
} from 'lucide-react'
import type { RemoteFormat, RemoteState } from '../protocol'
import { currentPosition, formatTime, query, send, useRemote } from '../api'
import { openInLibrary, useNav } from '../nav'
import { Artwork, Slider, Status, useLoad } from '../ui'
import { TrackRow } from './common'

/** Re-renders a few times a second while playing so the position moves smoothly. */
export function usePlaybackClock(active: boolean) {
  const [, setTick] = useState(0)
  useEffect(() => {
    if (!active) return
    const timer = window.setInterval(() => setTick((tick) => tick + 1), 250)
    return () => window.clearInterval(timer)
  }, [active])
}

const QUALITY_TEXT: Record<NonNullable<RemoteFormat['quality']>, string> = {
  'bit-perfect': 'Bit-perfect',
  'native-rate': 'Native rate',
  processed: 'Processed',
  resampled: 'Resampled',
  'system-mixer': 'System mixer',
}

function pathLabel(state: RemoteState): string {
  if (state.outputMode === 'exclusive') return 'Exclusive'
  if (state.outputMode === 'shared') return 'Shared'
  return 'Output closed'
}

export function SignalLine({ state }: { state: RemoteState }) {
  const format = state.format
  const quality = format?.quality ?? null
  const source = state.track?.isRadio
    ? [format?.codec, format?.bitrate].filter(Boolean).join(' ')
    : [format?.codec, format?.bitDepth, format?.sampleRate].filter(Boolean).join(' ')

  return (
    <div
      className="signal"
      role="note"
      aria-label={`${quality ? QUALITY_TEXT[quality] : 'Signal'}: ${source || 'unknown format'}, ${pathLabel(state)}, ${state.outputName ?? 'output'}.`}
    >
      <span className={`lamp ${quality ?? ''}`} aria-hidden />
      {source && <span className="signal-source tabular">{source}</span>}
      <span className="signal-step" aria-hidden>›</span>
      <span className="signal-path">{pathLabel(state)}</span>
      {state.outputName && (
        <>
          <span className="signal-step" aria-hidden>›</span>
          <span className="signal-output">{state.outputName}</span>
        </>
      )}
    </div>
  )
}

export default function NowPlaying() {
  const state = useRemote((s) => s.state)
  const receivedAt = useRemote((s) => s.receivedAt)
  const optimistic = useRemote((s) => s.optimistic)
  const setOptimistic = useRemote((s) => s.setOptimistic)
  const [scrub, setScrub] = useState<number | null>(null)
  const [tracksOpen, setTracksOpen] = useState(false)
  const isPlaying = optimistic.isPlaying ?? state?.isPlaying ?? false
  usePlaybackClock(isPlaying && scrub === null)

  if (!state || !state.track) {
    return (
      <div className="now">
        <div className="now-empty">
          <strong>Nothing playing</strong>
          <span>Choose an album from the Library to start.</span>
        </div>
      </div>
    )
  }

  const track = state.track
  // Tapping the cover lists the album's tracks.
  const albumId = track.catalogAlbumId
  const albumTracksOpen = tracksOpen && !!albumId
  const duration = state.durationSec || track.durationSec
  const position = currentPosition({ state, receivedAt, optimistic })
  const shownPosition = scrub !== null ? scrub * duration : position
  const shuffle = optimistic.shuffle ?? state.shuffle
  const repeat = optimistic.repeat ?? state.repeat
  const volume = optimistic.volume ?? state.volume

  const toggle = () => {
    setOptimistic({ isPlaying: !isPlaying })
    send({ type: 'toggle' })
  }

  return (
    <div className="now">
      {track.artwork && <div className="now-backdrop" style={{ backgroundImage: `url("${track.artwork}")` }} aria-hidden />}
      <div className="now-art-wrap">
        {albumTracksOpen && albumId ? (
          <AlbumTracks albumId={albumId} artwork={track.artwork} onClose={() => setTracksOpen(false)} />
        ) : albumId ? (
          <button
            type="button"
            className="now-art-button"
            onClick={() => setTracksOpen(true)}
            aria-label={`Show the tracks on ${track.album}`}
          >
            <Artwork src={track.artwork} className={`now-art ${isPlaying ? '' : 'paused'}`} kind="album" alt={track.album} />
          </button>
        ) : (
          <Artwork src={track.artwork} className={`now-art ${isPlaying ? '' : 'paused'}`} kind="album" alt={track.album} />
        )}
      </div>

      <div className="now-titles">
        <div className="row-text">
          <div className="now-title">{track.title}</div>
          <div className="now-artist">
            {track.catalogArtistId
              ? <button type="button" onClick={() => openInLibrary({ kind: 'artist', id: track.catalogArtistId! })}>{track.artist}</button>
              : track.artist}
            {track.album && (
              <>
                {' – '}
                {track.catalogAlbumId
                  ? <button type="button" onClick={() => openInLibrary({ kind: 'album', id: track.catalogAlbumId! })}>{track.album}</button>
                  : track.album}
              </>
            )}
          </div>
        </div>
      </div>

      <SignalLine state={state} />
      {state.error && <div className="now-error" role="alert">{state.error}</div>}

      {duration > 0 ? (
        <div className="progress">
          <Slider
            label="Position"
            value={duration > 0 ? shownPosition / duration : 0}
            valueText={`${formatTime(shownPosition)} of ${formatTime(duration)}`}
            onChange={(fraction) => setScrub(fraction)}
            onCommit={(fraction) => {
              setScrub(null)
              const target = fraction * duration
              setOptimistic({ positionSec: target, positionAt: performance.now() })
              send({ type: 'seek', positionSec: target })
            }}
          />
          <div className="times tabular">
            <span>{formatTime(shownPosition)}</span>
            <span>-{formatTime(Math.max(0, duration - shownPosition))}</span>
          </div>
        </div>
      ) : (
        <div className="times" style={{ marginTop: 14 }}><span /></div>
      )}

      <div className="transport">
        <button
          type="button"
          className={`icon-button mode ${shuffle ? 'on' : ''}`}
          aria-label={shuffle ? 'Shuffle on' : 'Shuffle off'}
          aria-pressed={shuffle}
          onClick={() => {
            setOptimistic({ shuffle: !shuffle })
            send({ type: 'shuffle', enabled: !shuffle })
          }}
        >
          <Shuffle size={22} />
        </button>
        <button type="button" className="icon-button" aria-label="Previous" onClick={() => send({ type: 'previous' })}>
          <SkipBack size={30} fill="currentColor" />
        </button>
        <button type="button" className="play-button" aria-label={isPlaying ? 'Pause' : 'Play'} onClick={toggle}>
          {isPlaying ? <Pause size={34} fill="currentColor" /> : <Play size={34} fill="currentColor" style={{ marginLeft: 4 }} />}
        </button>
        <button type="button" className="icon-button" aria-label="Next" onClick={() => send({ type: 'next' })}>
          <SkipForward size={30} fill="currentColor" />
        </button>
        <button
          type="button"
          className={`icon-button mode ${repeat !== 'off' ? 'on' : ''}`}
          aria-label={repeat === 'one' ? 'Repeat one' : repeat === 'all' ? 'Repeat all' : 'Repeat off'}
          onClick={() => {
            const next = repeat === 'off' ? 'all' : repeat === 'all' ? 'one' : 'off'
            setOptimistic({ repeat: next })
            send({ type: 'repeat', mode: next })
          }}
        >
          {repeat === 'one' ? <Repeat1 size={22} /> : <Repeat size={22} />}
        </button>
      </div>

      <div className="volume">
        <Volume1 size={18} aria-hidden />
        <Slider
          label={state.volumeLocked ? 'Volume (fixed on this output)' : 'Volume'}
          value={state.volumeLocked ? 1 : volume}
          disabled={state.volumeLocked}
          valueText={state.volumeLocked ? 'Fixed' : `${Math.round(volume * 100)}%`}
          onChange={(value) => setOptimistic({ volume: value })}
          onCommit={(value) => {
            setOptimistic({ volume: value })
            send({ type: 'volume', volume: value })
          }}
        />
        <Volume2 size={18} aria-hidden />
      </div>

      <QueueButton />
    </div>
  )
}

/** The playing album's tracks, in place of the big cover; tap a track to play from there. */
function AlbumTracks({ albumId, artwork, onClose }: { albumId: string; artwork: string | null; onClose: () => void }) {
  const { data: album, error, loading, reload } = useLoad(`album:${albumId}`, () => query({ type: 'album', id: albumId }))
  const listRef = useRef<HTMLDivElement>(null)
  // Open at the track that's playing.
  useEffect(() => {
    if (album) listRef.current?.querySelector('.row.current')?.scrollIntoView({ block: 'center' })
  }, [album])
  return (
    <div className="now-tracks">
      <button type="button" className="now-tracks-head" onClick={onClose} aria-label="Show the cover again">
        <Artwork src={artwork} className="now-tracks-art" kind="album" alt="" />
        <span className="row-text">
          <span className="row-title">{album?.title ?? ''}</span>
          <span className="row-sub">{album ? `${album.artist} · ${album.tracks.length} ${album.tracks.length === 1 ? 'track' : 'tracks'}` : ''}</span>
        </span>
      </button>
      <div className="now-tracks-list" ref={listRef}>
        {album ? album.tracks.map((albumTrack) => (
          <TrackRow
            key={albumTrack.id}
            track={albumTrack}
            number={albumTrack.trackNumber}
            showArtwork={false}
            showArtist={albumTrack.artist !== album.artist}
            onPlay={() => send({ type: 'play-album', albumId: album.id, startTrackId: albumTrack.id })}
          />
        )) : <Status loading={loading} error={error} empty={false} emptyTitle="" onRetry={reload} />}
      </div>
    </div>
  )
}

/** Opens the queue . */
function QueueButton() {
  const setQueueOpen = useNav((s) => s.setQueueOpen)
  const upNext = useRemote((s) => (s.queue && s.queue.currentIndex >= 0 ? Math.max(0, s.queue.total - s.queue.currentIndex - 1) : 0))
  return (
    <button type="button" className="queue-button" onClick={() => setQueueOpen(true)}>
      <ListMusic size={20} aria-hidden />
      <span>Queue</span>
      {upNext > 0 && <span className="queue-button-count">{upNext} up next</span>}
    </button>
  )
}

export function MiniPlayer({ onOpen }: { onOpen: () => void }) {
  const state = useRemote((s) => s.state)
  const receivedAt = useRemote((s) => s.receivedAt)
  const optimistic = useRemote((s) => s.optimistic)
  const setOptimistic = useRemote((s) => s.setOptimistic)
  const isPlaying = optimistic.isPlaying ?? state?.isPlaying ?? false
  usePlaybackClock(isPlaying)
  if (!state?.track) return null
  const duration = state.durationSec || state.track.durationSec
  const position = currentPosition({ state, receivedAt, optimistic })
  const progress = duration > 0 ? position / duration : 0
  return (
    <div className="mini-player">
      <div className="mini-progress" aria-hidden><span style={{ width: `${progress * 100}%` }} /></div>
      <button type="button" className="mini-text" onClick={onOpen} style={{ display: 'flex', alignItems: 'center', gap: 12 }} aria-label="Show Now Playing">
        <Artwork src={state.track.artwork} kind="album" />
        <span className="row-text">
          <span className="row-title" style={{ display: 'block', fontWeight: 600 }}>{state.track.title}</span>
          <span className="row-sub" style={{ display: 'block' }}>{state.track.artist}</span>
        </span>
      </button>
      <button
        type="button"
        className="icon-button"
        style={{ color: 'var(--text)' }}
        aria-label={isPlaying ? 'Pause' : 'Play'}
        onClick={() => {
          setOptimistic({ isPlaying: !isPlaying })
          send({ type: 'toggle' })
        }}
      >
        {isPlaying ? <Pause size={24} fill="currentColor" /> : <Play size={24} fill="currentColor" />}
      </button>
      <button type="button" className="icon-button" style={{ color: 'var(--text)' }} aria-label="Next" onClick={() => send({ type: 'next' })}>
        <SkipForward size={24} fill="currentColor" />
      </button>
    </div>
  )
}

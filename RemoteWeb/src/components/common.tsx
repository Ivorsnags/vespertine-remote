import { type ReactNode } from 'react'
import {
  ChevronLeft,
  Disc3,
  ListEnd,
  ListStart,
  Play,
  Shuffle,
  User,
} from 'lucide-react'
import type {
  RemoteAlbum,
  RemoteArtist,
  RemoteLibraryTrack,
} from '../protocol'
import { formatTime, send, useRemote } from '../api'
import { openInLibrary, useNav, type Route } from '../nav'
import { Artwork, useSheet, usePress } from '../ui'

// ---------------------------------------------------------------------------
// Page header with a back button (shown on every page below a tab's root)
// ---------------------------------------------------------------------------

export function BackButton({ label = 'Back' }: { label?: string }) {
  const pop = useNav((s) => s.pop)
  return (
    <button type="button" className="back" onClick={pop}>
      <ChevronLeft size={26} strokeWidth={2.2} aria-hidden />
      {label}
    </button>
  )
}

// ---------------------------------------------------------------------------
// Long-press menus
// ---------------------------------------------------------------------------

export function openTrackSheet(track: RemoteLibraryTrack, options: { play?: () => void } = {}) {
  useSheet.getState().open({
    title: track.title,
    subtitle: [track.artist, track.album].filter(Boolean).join(' – '),
    artwork: track.artwork,
    artworkKind: 'track',
    actions: [
      ...(options.play ? [{ label: 'Play', icon: Play, run: options.play, disabled: !track.playable }] : []),
      { label: 'Play next', icon: ListStart, disabled: !track.playable, run: () => send({ type: 'enqueue-track', trackId: track.id, next: true }) },
      { label: 'Play last', icon: ListEnd, disabled: !track.playable, run: () => send({ type: 'enqueue-track', trackId: track.id, next: false }) },
      ...(track.albumId ? [{ label: 'Go to album', icon: Disc3, run: () => openInLibrary({ kind: 'album', id: track.albumId! }) }] : []),
      ...(track.artistId ? [{ label: 'Go to artist', icon: User, run: () => openInLibrary({ kind: 'artist', id: track.artistId! }) }] : []),
    ],
  })
}

export function openAlbumSheet(album: RemoteAlbum) {
  useSheet.getState().open({
    title: album.title,
    subtitle: [album.artist, album.year].filter(Boolean).join(' · '),
    artwork: album.artwork,
    actions: [
      { label: 'Play', icon: Play, run: () => send({ type: 'play-album', albumId: album.id }) },
      { label: 'Shuffle', icon: Shuffle, run: () => send({ type: 'play-album', albumId: album.id, shuffle: true }) },
      { label: 'Play next', icon: ListStart, run: () => send({ type: 'enqueue-album', albumId: album.id, next: true }) },
      { label: 'Play last', icon: ListEnd, run: () => send({ type: 'enqueue-album', albumId: album.id, next: false }) },
      ...(album.artistId ? [{ label: 'Go to artist', icon: User, run: () => openInLibrary({ kind: 'artist', id: album.artistId! }) }] : []),
    ],
  })
}

export function openArtistSheet(artist: RemoteArtist) {
  useSheet.getState().open({
    title: artist.name,
    subtitle: artistCounts(artist),
    artwork: artist.artwork,
    artworkKind: 'artist',
    actions: [
      { label: 'Play all', icon: Play, run: () => send({ type: 'play-artist', artistId: artist.id }) },
      { label: 'Shuffle all', icon: Shuffle, run: () => send({ type: 'play-artist', artistId: artist.id, shuffle: true }) },
    ],
  })
}

export function artistCounts(artist: Pick<RemoteArtist, 'albumCount' | 'trackCount'>): string {
  if (artist.albumCount > 0) return `${artist.albumCount} ${artist.albumCount === 1 ? 'album' : 'albums'}`
  if (artist.trackCount > 0) return `${artist.trackCount} ${artist.trackCount === 1 ? 'track' : 'tracks'}`
  return ''
}

// ---------------------------------------------------------------------------
// Tiles
// ---------------------------------------------------------------------------

export function AlbumTile({ album }: { album: RemoteAlbum }) {
  const push = useNav((s) => s.push)
  const press = usePress(() => push({ kind: 'album', id: album.id }), () => openAlbumSheet(album))
  return (
    <button type="button" className="tile" {...press} aria-label={`${album.title}${album.artist ? `, ${album.artist}` : ''}`}>
      <Artwork src={album.artwork} alt="" />
      <div className="tile-title">{album.title}</div>
      <div className="tile-sub">{album.artist ?? (album.year ? String(album.year) : '')}</div>
    </button>
  )
}

export function ArtistTile({ artist }: { artist: RemoteArtist }) {
  const push = useNav((s) => s.push)
  const press = usePress(() => push({ kind: 'artist', id: artist.id }), () => openArtistSheet(artist))
  return (
    <button type="button" className="tile round" {...press} aria-label={artist.name}>
      <Artwork src={artist.artwork} kind="artist" alt="" />
      <div className="tile-title">{artist.name}</div>
      <div className="tile-sub">{artistCounts(artist)}</div>
    </button>
  )
}

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

export function ArtistRow({ artist, id }: { artist: RemoteArtist; id?: string }) {
  const push = useNav((s) => s.push)
  const press = usePress(() => push({ kind: 'artist', id: artist.id }), () => openArtistSheet(artist))
  return (
    <button type="button" id={id} className="row" {...press}>
      <Artwork src={artist.artwork} kind="artist" className="row-art round" />
      <span className="row-text">
        <span className="row-title" style={{ display: 'block' }}>{artist.name}</span>
        <span className="row-sub" style={{ display: 'block' }}>{artistCounts(artist)}</span>
      </span>
    </button>
  )
}

/** True when this library track is the one playing on the Mac. */
function useIsCurrent(track: RemoteLibraryTrack): boolean {
  return useRemote((s) => {
    const current = s.state?.track
    if (!current || current.isRadio) return false
    if (track.albumId && current.catalogAlbumId && track.albumId !== current.catalogAlbumId) return false
    return current.title === track.title
  })
}

export function TrackRow({
  track,
  onPlay,
  number,
  showArtwork = true,
  showArtist = true,
  trailing,
}: {
  track: RemoteLibraryTrack
  onPlay: () => void
  number?: number | null
  showArtwork?: boolean
  /** Off on album pages when the track is by the album's own artist. */
  showArtist?: boolean
  trailing?: ReactNode
}) {
  const current = useIsCurrent(track)
  const press = usePress(
    () => { if (track.playable) onPlay() },
    () => openTrackSheet(track, { play: onPlay }),
  )
  return (
    <button
      type="button"
      className={`row ${current ? 'current' : ''} ${track.playable ? '' : 'dim'}`}
      {...press}
      aria-label={`${track.title}${track.artist ? `, ${track.artist}` : ''}${current ? ', playing now' : ''}`}
    >
      {number !== undefined && <span className="row-num tabular">{current ? <span className="eq" aria-hidden /> : (number ?? '')}</span>}
      {showArtwork && <Artwork src={track.artwork} kind="track" className="row-art" />}
      <span className="row-text">
        <span className="row-title" style={{ display: 'block' }}>{track.title}</span>
        {(() => {
          const sub = [showArtist ? track.artist : null, showArtwork ? track.album : null].filter(Boolean).join(' – ')
          return sub ? <span className="row-sub" style={{ display: 'block' }}>{sub}</span> : null
        })()}
      </span>
      {trailing ?? <span className="row-trail tabular">{track.durationSec > 0 ? formatTime(track.durationSec) : ''}</span>}
    </button>
  )
}

// ---------------------------------------------------------------------------
// Alphabetical grouping with an index rail (long artist lists)
// ---------------------------------------------------------------------------

export function letterOf(name: string): string {
  const first = name.replace(/^(the|a|an)\s+/i, '').trim().charAt(0).toUpperCase()
  if (!first) return '#'
  const plain = first.normalize('NFD').replace(/[̀-ͯ]/g, '')
  return /[A-Z]/.test(plain) ? plain : '#'
}

export function IndexRail({ letters, prefix }: { letters: string[]; prefix: string }) {
  if (letters.length < 6) return null
  const jump = (clientY: number, rail: HTMLElement) => {
    const rect = rail.getBoundingClientRect()
    const fraction = Math.max(0, Math.min(0.999, (clientY - rect.top) / rect.height))
    const letter = letters[Math.floor(fraction * letters.length)]
    document.getElementById(`${prefix}-${letter}`)?.scrollIntoView({ block: 'start' })
  }
  return (
    <div
      className="index-rail"
      aria-hidden
      onPointerDown={(event) => {
        event.currentTarget.setPointerCapture(event.pointerId)
        jump(event.clientY, event.currentTarget)
      }}
      onPointerMove={(event) => {
        if (event.buttons) jump(event.clientY, event.currentTarget)
      }}
    >
      {letters.map((letter) => <span key={letter}>{letter}</span>)}
    </div>
  )
}

/** A route's stable cache key for useLoad. */
export function routeKey(route: Route): string {
  switch (route.kind) {
    case 'album': return `album:${route.id}`
    case 'artist': return `artist:${route.id}`
    case 'podcast-show': return `podcast-show:${route.id}`
    default: return 'root'
  }
}

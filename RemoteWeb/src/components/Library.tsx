import { useMemo, useState } from 'react'
import { Play, Search as SearchIcon, Shuffle } from 'lucide-react'
import type { RemoteArtist } from '../protocol'
import { formatTotal, query, send } from '../api'
import { useNav, type LibrarySection, type Route } from '../nav'
import { Artwork, Status, useLoad } from '../ui'
import { PodcastShowPage } from './Podcasts'
import {
  AlbumTile,
  ArtistRow,
  BackButton,
  IndexRail,
  TrackRow,
  artistCounts,
  letterOf,
} from './common'

const SECTIONS: Array<{ id: LibrarySection; label: string }> = [
  { id: 'albums', label: 'Albums' },
  { id: 'artists', label: 'Artists' },
]

function normalise(value: string | null | undefined): string {
  return (value ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

function FilterField({ value, onChange, placeholder }: { value: string; onChange: (value: string) => void; placeholder: string }) {
  return (
    <label className="search" style={{ marginBottom: 14 }}>
      <SearchIcon size={17} aria-hidden />
      <input
        type="search"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder={placeholder}
        autoComplete="off"
        autoCorrect="off"
        spellCheck={false}
        enterKeyHint="search"
      />
    </label>
  )
}

// ---------------------------------------------------------------------------
// Library root
// ---------------------------------------------------------------------------

function AlbumsSection() {
  const { data, error, loading, reload } = useLoad('albums', () => query({ type: 'albums' }))
  const [filter, setFilter] = useState('')
  const albums = useMemo(() => {
    const term = normalise(filter.trim())
    const list = data ?? []
    return term ? list.filter((album) => normalise(album.title).includes(term) || normalise(album.artist).includes(term)) : list
  }, [data, filter])
  return (
    <>
      {(data?.length ?? 0) > 12 && <FilterField value={filter} onChange={setFilter} placeholder="Filter albums" />}
      <Status
        loading={loading && !data}
        error={data ? null : error}
        empty={!!data && albums.length === 0}
        emptyTitle={filter ? 'No matching albums' : 'No albums yet'}
        emptyHint={filter ? undefined : 'Add your music folder in the Mac app’s Settings.'}
        onRetry={reload}
      />
      <div className="grid">
        {albums.map((album) => <AlbumTile key={album.id} album={album} />)}
      </div>
    </>
  )
}

function ArtistsSection() {
  const { data, error, loading, reload } = useLoad('artists', () => query({ type: 'artists' }))
  const [filter, setFilter] = useState('')
  const groups = useMemo(() => {
    const term = normalise(filter.trim())
    const list = (data ?? []).filter((artist) => !term || normalise(artist.name).includes(term))
    const byLetter = new Map<string, RemoteArtist[]>()
    for (const artist of list) {
      const letter = letterOf(artist.name)
      const bucket = byLetter.get(letter) ?? []
      bucket.push(artist)
      byLetter.set(letter, bucket)
    }
    return [...byLetter.entries()].sort(([a], [b]) => (a === '#' ? 1 : b === '#' ? -1 : a.localeCompare(b)))
  }, [data, filter])
  return (
    <>
      {(data?.length ?? 0) > 12 && <FilterField value={filter} onChange={setFilter} placeholder="Filter artists" />}
      <Status
        loading={loading && !data}
        error={data ? null : error}
        empty={!!data && groups.length === 0}
        emptyTitle={filter ? 'No matching artists' : 'No artists yet'}
        onRetry={reload}
      />
      {!filter && <IndexRail letters={groups.map(([letter]) => letter)} prefix="artists" />}
      {groups.map(([letter, artists]) => (
        <section key={letter}>
          <div className="letter" id={`artists-${letter}`}>{letter}</div>
          {artists.map((artist) => <ArtistRow key={artist.id} artist={artist} />)}
        </section>
      ))}
    </>
  )
}

export function LibraryRoot() {
  const section = useNav((s) => s.librarySection)
  const setSection = useNav((s) => s.setLibrarySection)
  return (
    <>
      <h1 className="page-title">Library</h1>
      <div className="segmented" role="group" aria-label="Library section">
        {SECTIONS.map((entry) => (
          <button key={entry.id} type="button" aria-pressed={section === entry.id} onClick={() => setSection(entry.id)}>
            {entry.label}
          </button>
        ))}
      </div>
      {section === 'albums' && <AlbumsSection />}
      {section === 'artists' && <ArtistsSection />}
    </>
  )
}

// ---------------------------------------------------------------------------
// Detail pages
// ---------------------------------------------------------------------------

function AlbumPage({ id }: { id: string }) {
  const { data: album, error, loading, reload } = useLoad(`album:${id}`, () => query({ type: 'album', id }))
  const push = useNav((s) => s.push)
  if (!album) {
    return (
      <>
        <BackButton />
        <Status loading={loading} error={error} empty={!loading && !error} emptyTitle="Album not found" onRetry={reload} />
      </>
    )
  }
  const discs = new Set(album.tracks.map((track) => track.discNumber ?? 1))
  const multiDisc = discs.size > 1
  let lastDisc: number | null = null
  return (
    <>
      <BackButton />
      <div className="hero">
        <Artwork src={album.artwork} alt={album.title} />
        <div className="row-text">
          <div className="hero-title">{album.title}</div>
          <div className="hero-sub">
            {album.artistId
              ? <button type="button" onClick={() => push({ kind: 'artist', id: album.artistId! })}>{album.artist}</button>
              : album.artist}
          </div>
          <div className="hero-meta">
            {[album.year, `${album.tracks.length} ${album.tracks.length === 1 ? 'track' : 'tracks'}`, album.totalDurationSec > 0 ? formatTotal(album.totalDurationSec) : null]
              .filter(Boolean).join(' · ')}
          </div>
        </div>
      </div>
      <div className="button-row">
        <button type="button" className="button primary" onClick={() => send({ type: 'play-album', albumId: album.id })}>
          <Play size={18} fill="currentColor" aria-hidden /> Play
        </button>
        <button type="button" className="button" onClick={() => send({ type: 'play-album', albumId: album.id, shuffle: true })}>
          <Shuffle size={18} aria-hidden /> Shuffle
        </button>
      </div>
      <div className="list">
        {album.tracks.map((track) => {
          const disc = track.discNumber ?? 1
          const header = multiDisc && disc !== lastDisc ? <div className="disc" key={`disc-${disc}`}>Disc {disc}</div> : null
          lastDisc = disc
          return (
            <div key={track.id}>
              {header}
              <TrackRow
                track={track}
                number={track.trackNumber}
                showArtwork={false}
                showArtist={track.artist !== album.artist}
                onPlay={() => send({ type: 'play-album', albumId: album.id, startTrackId: track.id })}
              />
            </div>
          )
        })}
      </div>
    </>
  )
}

/** A few lines of the biography; tap to read it all. */
function ArtistBio({ text }: { text: string }) {
  const [open, setOpen] = useState(false)
  return (
    <button type="button" className={`artist-bio ${open ? 'open' : ''}`} onClick={() => setOpen((value) => !value)} aria-expanded={open}>
      <span className="artist-bio-text">{text}</span>
      <span className="artist-bio-more">{open ? 'Less' : 'More'} · Wikipedia</span>
    </button>
  )
}

function ArtistPage({ id }: { id: string }) {
  const { data: artist, error, loading, reload } = useLoad(`artist:${id}`, () => query({ type: 'artist', id }))
  if (!artist) {
    return (
      <>
        <BackButton />
        <Status loading={loading} error={error} empty={!loading && !error} emptyTitle="Artist not found" onRetry={reload} />
      </>
    )
  }
  const topTracks = artist.topTracks.slice(0, 5)
  return (
    <>
      <BackButton />
      <div className="hero round">
        <Artwork src={artist.artwork} kind="artist" alt={artist.name} />
        <div className="row-text">
          <div className="hero-title">{artist.name}</div>
          <div className="hero-meta">{[artistCounts(artist), artist.genres.slice(0, 3).join(', ')].filter(Boolean).join(' · ')}</div>
        </div>
      </div>
      <div className="button-row">
        <button type="button" className="button primary" onClick={() => send({ type: 'play-artist', artistId: artist.id })}>
          <Play size={18} fill="currentColor" aria-hidden /> Play
        </button>
        <button type="button" className="button" onClick={() => send({ type: 'play-artist', artistId: artist.id, shuffle: true })}>
          <Shuffle size={18} aria-hidden /> Shuffle
        </button>
      </div>
      {artist.bio && <ArtistBio text={artist.bio} />}
      {topTracks.length > 0 && (
        <>
          <h2 className="section-title">Songs</h2>
          {topTracks.map((track, index) => (
            <TrackRow
              key={track.id}
              track={track}
              onPlay={() => send({ type: 'play-tracks', trackIds: topTracks.map((entry) => entry.id), startIndex: index })}
            />
          ))}
        </>
      )}
      {artist.albums.length > 0 && (
        <>
          <h2 className="section-title">Albums</h2>
          <div className="grid">{artist.albums.map((album) => <AlbumTile key={album.id} album={album} />)}</div>
        </>
      )}
      {artist.appearsOn.length > 0 && (
        <>
          <h2 className="section-title">Appears on</h2>
          <div className="grid">{artist.appearsOn.map((album) => <AlbumTile key={album.id} album={album} />)}</div>
        </>
      )}
    </>
  )
}

/** Renders any library page; tabs keep their own stacks of these. */
export function RoutePage({ route, root }: { route: Route; root: () => JSX.Element }) {
  switch (route.kind) {
    case 'album': return <AlbumPage key={route.id} id={route.id} />
    case 'artist': return <ArtistPage key={route.id} id={route.id} />
    case 'podcast-show': return <PodcastShowPage key={route.id} id={route.id} />
    default: return root()
  }
}


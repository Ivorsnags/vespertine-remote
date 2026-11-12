import { useEffect, useRef, useState } from 'react'
import { Search as SearchIcon, X } from 'lucide-react'
import type { RemoteSearchResults } from '../protocol'
import { query, send } from '../api'
import { AlbumTile, ArtistRow, TrackRow } from './common'

let rememberedQuery = ''
let rememberedResults: RemoteSearchResults | null = null

export function SearchRoot() {
  const [text, setText] = useState(rememberedQuery)
  const [results, setResults] = useState<RemoteSearchResults | null>(rememberedResults)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const request = useRef(0)
  const input = useRef<HTMLInputElement>(null)

  useEffect(() => {
    rememberedQuery = text
    const term = text.trim()
    if (term.length < 2) {
      setResults(null)
      rememberedResults = null
      setBusy(false)
      setError(null)
      return
    }
    const id = ++request.current
    setBusy(true)
    const timer = window.setTimeout(() => {
      query({ type: 'search', query: term }).then((value) => {
        if (id !== request.current) return
        setResults(value)
        rememberedResults = value
        setError(null)
        setBusy(false)
      }).catch((reason: unknown) => {
        if (id !== request.current) return
        setError(reason instanceof Error ? reason.message : 'Search failed')
        setBusy(false)
      })
    }, 250)
    return () => window.clearTimeout(timer)
  }, [text])

  const empty = !!results && results.artists.length === 0 && results.albums.length === 0 && results.tracks.length === 0

  return (
    <>
      <h1 className="page-title">Search</h1>
      <label className="search">
        <SearchIcon size={18} aria-hidden />
        <input
          ref={input}
          type="search"
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="Artists, albums, songs"
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

      {text.trim().length < 2 && (
        <div className="empty"><strong>Search your library</strong>Type at least two letters.</div>
      )}
      {busy && !results && <div className="empty">Searching…</div>}
      {error && !busy && <div className="empty"><strong>Search failed</strong>{error}</div>}
      {empty && !busy && <div className="empty"><strong>No results</strong>Nothing in your library matches “{text.trim()}”.</div>}

      {results && results.tracks.length > 0 && (
        <>
          <h2 className="section-title">Songs</h2>
          {results.tracks.slice(0, 12).map((track) => (
            <TrackRow key={track.id} track={track} onPlay={() => send({ type: 'play-tracks', trackIds: [track.id] })} />
          ))}
        </>
      )}
      {results && results.albums.length > 0 && (
        <>
          <h2 className="section-title">Albums</h2>
          <div className="grid">{results.albums.slice(0, 12).map((album) => <AlbumTile key={album.id} album={album} />)}</div>
        </>
      )}
      {results && results.artists.length > 0 && (
        <>
          <h2 className="section-title">Artists</h2>
          {results.artists.slice(0, 12).map((artist) => <ArtistRow key={artist.id} artist={artist} />)}
        </>
      )}
    </>
  )
}

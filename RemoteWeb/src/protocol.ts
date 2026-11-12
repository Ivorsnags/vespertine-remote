/**
 * The iPhone/iPad remote's protocol, shared by three places:
 *   - the Mac app's renderer (src/services/remote/remoteBridge.ts), which owns
 *     playback and answers requests,
 *   - the Electron main process (electron/main/remote), a thin LAN-only HTTP +
 *     Server-Sent Events gateway,
 *   - the remote web app (remote/), served by that gateway.
 *
 * Everything here is plain JSON-safe data. Artwork is always a URL the phone
 * can load directly: `/art?src=…` for the Mac's own artwork, or an http(s)
 * URL (radio station logos).
 */

export const REMOTE_DEFAULT_PORT = 8765
/** Every state-changing request must carry this header (see electron/main/remote/security.ts). */
export const REMOTE_CLIENT_HEADER = 'x-vespertine-remote'
export const REMOTE_SETTING_ENABLED = 'remote.enabled'
export const REMOTE_SETTING_PORT = 'remote.port'

export type RemoteRepeat = 'off' | 'all' | 'one'
export type RemoteOutputMode = 'exclusive' | 'shared' | 'closed'

/** How faithfully the current track reaches the output, as the Mac's player bar judges it. */
/**
 * bit-perfect: exclusive mode, untouched. native-rate: lossy source at its own rate.
 * processed: EQ, plug-ins or software volume change the sound. resampled: rate converted.
 * system-mixer: shared mode, macOS mixes it.
 */
export type RemoteQuality = 'bit-perfect' | 'native-rate' | 'processed' | 'resampled' | 'system-mixer' | null

export interface RemoteTrack {
  /** Identity of this queue entry (stable while it stays in the queue). */
  key: string
  title: string
  artist: string
  album: string
  durationSec: number
  artwork: string | null
  catalogAlbumId: string | null
  catalogArtistId: string | null
  isRadio: boolean
  /** A podcast episode: Now Playing shows back-15/forward-30 and links the show. */
  isPodcast?: boolean
  podcastShowId?: string | null
  podcastEpisodeId?: string | null
}

export interface RemoteFormat {
  /** e.g. "FLAC", "DSD128", "MP3". */
  codec: string | null
  /** e.g. "24bit" (same labels as the Mac app). */
  bitDepth: string | null
  /** e.g. "96kHz", "5.6MHz". */
  sampleRate: string | null
  /** e.g. "320kbps", shown for lossy formats. */
  bitrate: string | null
  lossless: boolean
  hiRes: boolean
  quality: RemoteQuality
}

export interface RemoteState {
  /** Increases with every published snapshot. */
  revision: number
  /** Mac clock (ms) when `positionSec` was read; the phone extrapolates from it while playing. */
  sentAt: number
  track: RemoteTrack | null
  isPlaying: boolean
  positionSec: number
  durationSec: number
  volume: number
  /** The output's volume is fixed (bit-perfect to a DAC with its own volume), so the slider is disabled. */
  volumeLocked: boolean
  shuffle: boolean
  repeat: RemoteRepeat
  /** What started playback, e.g. an album or playlist name. */
  contextLabel: string | null
  format: RemoteFormat | null
  outputMode: RemoteOutputMode
  outputName: string | null
  notification: string | null
  error: string | null
  /** The Mac is silent because a phone is playing ("Play on this iPhone"). */
  heldForPhone: boolean
  /** The Mac app's accent colour (hex), so the remote matches it. */
  accent: string
  queueRevision: number
}

export interface RemoteQueue {
  revision: number
  /** Queue position of items[0]; very long queues are sent as a window around the current track. */
  offset: number
  /** Queue position of the current entry, or -1. */
  currentIndex: number
  total: number
  shuffle: boolean
  /** Reordering is only possible with shuffle off (as in the Mac app). */
  canReorder: boolean
  items: RemoteTrack[]
}

export interface RemoteArtist {
  id: string
  name: string
  artwork: string | null
  albumCount: number
  trackCount: number
}

export interface RemoteAlbum {
  id: string
  title: string
  artist: string | null
  artistId: string | null
  year: number | null
  artwork: string | null
  trackCount: number | null
}

export interface RemoteLibraryTrack {
  id: string
  title: string
  artist: string | null
  artistId: string | null
  album: string | null
  albumId: string | null
  trackNumber: number | null
  discNumber: number | null
  durationSec: number
  artwork: string | null
  playable: boolean
  format: string | null
}

export interface RemoteAlbumDetail extends RemoteAlbum {
  tracks: RemoteLibraryTrack[]
  totalDurationSec: number
}

export interface RemoteArtistDetail extends RemoteArtist {
  /** Short biography (from Wikipedia for library artists), if one was found. */
  bio?: string | null
  genres: string[]
  topTracks: RemoteLibraryTrack[]
  albums: RemoteAlbum[]
  appearsOn: RemoteAlbum[]
}

export interface RemotePlaylist {
  id: number
  name: string
  trackCount: number
  artwork: string | null
  folderId: number | null
}

export interface RemotePlaylistFolder {
  id: number
  name: string
  parentId: number | null
}

export interface RemotePlaylistTrack {
  /** The playlist item's id, used to start playback from it. */
  itemId: number | null
  title: string
  artist: string | null
  album: string | null
  durationSec: number
  artwork: string | null
}

export interface RemotePlaylistDetail extends RemotePlaylist {
  tracks: RemotePlaylistTrack[]
}

export interface RemoteGenre {
  name: string
  artistCount: number
  artwork: string | null
}

export interface RemoteStation {
  id: string
  name: string
  detail: string | null
  artwork: string | null
  /** In the Mac's saved stations (My Live Radio), shown as a favourite on the phone. */
  saved: boolean
}

export type RemotePodcastDownload = 'none' | 'queued' | 'downloading' | 'downloaded' | 'failed'

export interface RemotePodcastShow {
  id: string
  title: string
  author: string | null
  artwork: string | null
  newCount: number
  subscribed: boolean
}

export interface RemotePodcastEpisode {
  id: string
  showId: string
  showTitle: string
  title: string
  /** Plain-text notes (shortened for lists). */
  summary: string | null
  /** ms since 1970. */
  publishedAt: number | null
  durationSec: number | null
  positionSec: number
  played: boolean
  isNew: boolean
  download: RemotePodcastDownload
  /** 0–1 while downloading. */
  downloadProgress: number | null
  artwork: string | null
}

export interface RemotePodcastShowDetail extends RemotePodcastShow {
  description: string | null
  episodes: RemotePodcastEpisode[]
  /** All episodes the show has (the list may be shortened). */
  episodeTotal: number
}

export interface RemotePodcastHome {
  inProgress: RemotePodcastEpisode[]
  newEpisodes: RemotePodcastEpisode[]
}

/** A show in Apple's public directory, found by search or the charts. */
export interface RemotePodcastDirectoryShow {
  appleId: number
  title: string
  author: string | null
  artwork: string | null
  showId: string | null
  subscribed: boolean
}

export interface RemoteOutput {
  uid: string
  name: string
  isDefault: boolean
  /** Exclusive mode is impossible on this output (Bluetooth, AirPlay, system default). */
  sharedOnly: boolean
}

export interface RemoteOutputs {
  current: string | null
  mode: RemoteOutputMode
  canToggleExclusive: boolean
  outputs: RemoteOutput[]
}

export interface RemoteSearchResults {
  artists: RemoteArtist[]
  albums: RemoteAlbum[]
  tracks: RemoteLibraryTrack[]
}

/** Queue-index commands name the entry they mean, so a queue that changed meanwhile is refused, not misapplied. */
export interface RemoteQueueTarget {
  index: number
  key: string
  revision: number
}

export type RemoteCommand =
  | { type: 'toggle' }
  | { type: 'play' }
  | { type: 'pause' }
  | { type: 'next' }
  | { type: 'previous' }
  | { type: 'seek'; positionSec: number }
  | { type: 'volume'; volume: number }
  | { type: 'shuffle'; enabled: boolean }
  | { type: 'repeat'; mode: RemoteRepeat }
  | { type: 'queue-jump'; target: RemoteQueueTarget }
  | { type: 'queue-remove'; target: RemoteQueueTarget }
  | { type: 'queue-move'; target: RemoteQueueTarget; toIndex: number }
  | { type: 'queue-clear' }
  | { type: 'play-album'; albumId: string; startTrackId?: string; shuffle?: boolean }
  | { type: 'play-artist'; artistId: string; shuffle?: boolean }
  | { type: 'play-playlist'; playlistId: number; startItemId?: number; shuffle?: boolean }
  | { type: 'play-tracks'; trackIds: string[]; startIndex?: number }
  | { type: 'enqueue-album'; albumId: string; next: boolean }
  | { type: 'enqueue-track'; trackId: string; next: boolean }
  | { type: 'enqueue-playlist'; playlistId: number; next: boolean }
  | { type: 'play-station'; stationId: string }
  /** Saves a station (from the saved list or a recent radio search) to My Live Radio. */
  | { type: 'save-station'; stationId: string }
  | { type: 'remove-station'; stationId: string }
  | { type: 'select-output'; uid: string }
  /** Moves the play position by this many seconds (podcast back 15 / forward 30). */
  | { type: 'skip'; seconds: number }
  | { type: 'podcast-play'; episodeId: string }
  | { type: 'podcast-subscribe'; showId: string }
  | { type: 'podcast-unsubscribe'; showId: string }
  | { type: 'podcast-download'; episodeId: string }
  | { type: 'podcast-cancel-download'; episodeId: string }
  | { type: 'podcast-delete-download'; episodeId: string }
  | { type: 'podcast-played'; episodeId: string; played: boolean }
  | { type: 'output-mode'; mode: 'exclusive' | 'shared' }
  /** "Play on this iPhone": the phone takes over; the Mac goes silent but keeps the queue. */
  | { type: 'listen-hold' }
  /** Sent every few seconds while the phone plays; answers with RemoteListenReport. */
  | { type: 'listen-report'; key: string; positionSec: number; playing: boolean }
  /** The Mac takes playback back from the phone's position. */
  | { type: 'listen-release'; key: string; positionSec: number; play: boolean }
  /** Moves the Mac's queue on for the phone; answers with RemoteListenStep. */
  | { type: 'listen-step'; direction: 'next' | 'previous' | 'ended' }

export type RemoteQuery =
  | { type: 'artists' }
  | { type: 'albums' }
  | { type: 'artist'; id: string }
  | { type: 'album'; id: string }
  | { type: 'playlists' }
  | { type: 'playlist'; id: number }
  | { type: 'genres' }
  | { type: 'genre'; name: string }
  | { type: 'search'; query: string }
  | { type: 'stations' }
  /** Searches the online station directory (Radio Browser) from the Mac. */
  | { type: 'radio-search'; query: string }
  | { type: 'outputs' }
  | { type: 'queue' }
  | { type: 'podcast-home' }
  | { type: 'podcast-shows' }
  | { type: 'podcast-show'; id: string }
  | { type: 'podcast-downloads' }
  | { type: 'podcast-search'; query: string }
  | { type: 'podcast-top'; genreId: number | null }
  /** Opens a directory show on the Mac (reading its feed) by Apple's id. */
  | { type: 'podcast-open'; appleId: number }
  /** Where the phone should start a queue entry (a podcast's saved place, otherwise 0). */
  | { type: 'listen-start'; key: string }

export interface RemoteQueryResultMap {
  artists: RemoteArtist[]
  albums: RemoteAlbum[]
  artist: RemoteArtistDetail | null
  album: RemoteAlbumDetail | null
  playlists: { playlists: RemotePlaylist[]; folders: RemotePlaylistFolder[] }
  playlist: RemotePlaylistDetail | null
  genres: RemoteGenre[]
  genre: RemoteArtist[]
  search: RemoteSearchResults
  stations: RemoteStation[]
  'radio-search': RemoteStation[]
  outputs: RemoteOutputs
  queue: RemoteQueue
  'podcast-home': RemotePodcastHome
  'podcast-shows': RemotePodcastShow[]
  'podcast-show': RemotePodcastShowDetail | null
  'podcast-downloads': RemotePodcastEpisode[]
  'podcast-search': RemotePodcastDirectoryShow[]
  'podcast-top': RemotePodcastDirectoryShow[]
  'podcast-open': RemotePodcastShowDetail
  'listen-start': { startSec: number }
}

export interface RemoteListenReport {
  /** Someone pressed Play on the Mac: the phone should stop. */
  macPlaying: boolean
}

/** The queue entry the phone should play now, or null at the end of the queue. */
export type RemoteListenStep = { key: string; startSec: number } | null

/**
 * Where the Mac finds a queue entry's sound for "Play on this iPhone". This
 * stays between the Mac's renderer and main process: the phone only ever
 * asks for `/listen?key=…` and gets the audio itself.
 */
export type ListenSource =
  | { kind: 'file'; path: string; startSec: number; endSec: number | null; sampleRate: number | null; isDsd: boolean }
  | { kind: 'url'; url: string }
  | { kind: 'podcast'; episodeId: string }

export type RemoteRpcPayload =
  | { kind: 'query'; query: RemoteQuery }
  | { kind: 'command'; command: RemoteCommand }
  /** Main process → renderer: the sound behind a queue entry (see ListenSource). */
  | { kind: 'listen-source'; key: string }

/** A request from main to the renderer, answered with a RemoteRpcResponse of the same id. */
export type RemoteRpcRequest = RemoteRpcPayload & { id: number }

export type RemoteRpcResponse =
  | { id: number; ok: true; value: unknown }
  | { id: number; ok: false; error: string; status?: number }

/** Server-Sent Event names sent on /api/events. */
export type RemoteEventName = 'state' | 'queue' | 'library'

export interface RemoteServerStatus {
  enabled: boolean
  running: boolean
  port: number
  /** Addresses to type into Safari, best first (the .local name survives IP changes). */
  urls: string[]
  clients: number
  error: string | null
}

/**
 * Maps the Mac app's artwork URLs (artwork://cache/…, artwork://file?path=…)
 * to ones the phone can load from the gateway; web URLs pass through.
 */
export function toRemoteArtwork(url: string | null | undefined): string | null {
  if (!url) return null
  if (/^https?:/i.test(url)) return url
  if (/^artwork:/i.test(url)) return `/art?src=${encodeURIComponent(url)}`
  return null
}

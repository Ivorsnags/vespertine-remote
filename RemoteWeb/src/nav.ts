import { create } from 'zustand'

export type Tab = 'now' | 'library' | 'search' | 'podcasts'
export type PodcastSection = 'listen' | 'shows' | 'browse' | 'downloads'
export type LibrarySection = 'albums' | 'artists'

export type Route =
  | { kind: 'root' }
  | { kind: 'album'; id: string }
  | { kind: 'artist'; id: string }
  | { kind: 'podcast-show'; id: string }

interface NavStore {
  tab: Tab
  stacks: Record<Exclude<Tab, 'now'>, Route[]>
  librarySection: LibrarySection
  podcastSection: PodcastSection
  /** The queue opens over everything from a button on Now Playing. */
  queueOpen: boolean
  setQueueOpen: (open: boolean) => void
  setPodcastSection: (section: PodcastSection) => void
  setTab: (tab: Tab) => void
  push: (route: Route) => void
  pop: () => void
  setLibrarySection: (section: LibrarySection) => void
}

const root = (): Route[] => [{ kind: 'root' }]

function rememberedSection(): LibrarySection {
  try {
    const value = localStorage.getItem('remote:library-section')
    if (value === 'albums' || value === 'artists') return value
  } catch {
    // Private mode: use the default.
  }
  return 'albums'
}

function rememberedPodcastSection(): PodcastSection {
  try {
    const value = localStorage.getItem('remote:podcast-section')
    if (value === 'listen' || value === 'shows' || value === 'browse' || value === 'downloads') return value
  } catch {
    // Private mode: use the default.
  }
  return 'listen'
}

export const useNav = create<NavStore>((set, get) => ({
  tab: 'now',
  stacks: { library: root(), search: root(), podcasts: root() },
  librarySection: rememberedSection(),
  podcastSection: rememberedPodcastSection(),
  queueOpen: false,
  setQueueOpen: (queueOpen) => set({ queueOpen }),
  setPodcastSection: (section) => {
    try { localStorage.setItem('remote:podcast-section', section) } catch { /* private mode */ }
    set({ podcastSection: section })
  },
  setTab: (tab) => {
    const current = get().tab
    // Tapping the current tab again returns to its first page, as on iOS.
    if (tab === current && tab !== 'now') {
      set((state) => ({ stacks: { ...state.stacks, [tab]: root() } }))
      return
    }
    set({ tab })
  },
  push: (route) => {
    const tab = get().tab === 'now' ? 'library' : get().tab
    set((state) => ({
      tab,
      stacks: { ...state.stacks, [tab]: [...state.stacks[tab as Exclude<Tab, 'now'>], route] },
    }))
  },
  pop: () => {
    const tab = get().tab
    if (tab === 'now') return
    set((state) => {
      const stack = state.stacks[tab]
      return stack.length > 1 ? { stacks: { ...state.stacks, [tab]: stack.slice(0, -1) } } : {}
    })
  },
  setLibrarySection: (section) => {
    try { localStorage.setItem('remote:library-section', section) } catch { /* private mode */ }
    set({ librarySection: section })
  },
}))

/** Opens a library page from anywhere (e.g. tapping the artist on Now Playing). */
export function openInLibrary(route: Route) {
  const nav = useNav.getState()
  useNav.setState({
    tab: 'library',
    queueOpen: false,
    stacks: { ...nav.stacks, library: [{ kind: 'root' }, route] },
  })
}

/** Opens a podcast show from anywhere (e.g. tapping the show on Now Playing). */
export function openPodcastShow(showId: string) {
  const nav = useNav.getState()
  useNav.setState({
    tab: 'podcasts',
    queueOpen: false,
    stacks: { ...nav.stacks, podcasts: [{ kind: 'root' }, { kind: 'podcast-show', id: showId }] },
  })
}

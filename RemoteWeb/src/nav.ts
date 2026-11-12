import { create } from 'zustand'

export type Tab = 'now' | 'library' | 'search'
export type LibrarySection = 'albums' | 'artists'

export type Route =
  | { kind: 'root' }
  | { kind: 'album'; id: string }
  | { kind: 'artist'; id: string }

interface NavStore {
  tab: Tab
  stacks: Record<Exclude<Tab, 'now'>, Route[]>
  librarySection: LibrarySection
  /** The queue opens over everything from a button on Now Playing. */
  queueOpen: boolean
  setQueueOpen: (open: boolean) => void
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

export const useNav = create<NavStore>((set, get) => ({
  tab: 'now',
  stacks: { library: root(), search: root() },
  librarySection: rememberedSection(),
  queueOpen: false,
  setQueueOpen: (queueOpen) => set({ queueOpen }),
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

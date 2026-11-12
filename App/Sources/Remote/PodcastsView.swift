//
// Vespertine Remote: the Podcasts page in the Mac app (the sidebar's "Podcasts"). The same shows, downloads and
// playback as the phone's Podcasts tab; both use `RemotePodcasts`.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

private struct EpisodeItem: Identifiable {
    let show: PodcastShowRecord
    let episode: PodcastEpisodeRecord
    var id: String { episode.id }
}

private func items(_ pairs: [(PodcastShowRecord, PodcastEpisodeRecord)]) -> [EpisodeItem] {
    pairs.map { EpisodeItem(show: $0.0, episode: $0.1) }
}

private func dateText(_ ms: Double?) -> String? {
    guard let ms else { return nil }
    return Date(timeIntervalSince1970: ms / 1000).formatted(date: .abbreviated, time: .omitted)
}

private func lengthText(_ seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 60 else { return nil }
    let minutes = Int(seconds / 60)
    return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
}

struct PodcastsView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case listen = "Listen Now", shows = "Shows", downloads = "Downloads", find = "Find"
        var id: String { rawValue }
    }

    @State private var page: Page = .listen
    @State private var openShowID: String?

    var body: some View {
        if let service = RemoteController.shared.podcasts {
            VStack(spacing: 0) {
                if let id = openShowID {
                    ShowPage(service: service, showID: id, close: { openShowID = nil })
                } else {
                    Picker("Section", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding([.horizontal, .top], 16)
                    .padding(.bottom, 8)
                    switch page {
                    case .listen: ListenNow(service: service)
                    case .shows: Shows(service: service, open: { openShowID = $0 })
                    case .downloads: Downloads(service: service)
                    case .find: Find(service: service, open: { openShowID = $0 })
                    }
                }
                if let message = service.message {
                    Text(message)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(.bar)
                }
            }
            .task { service.refreshAll() }
        } else {
            ContentUnavailableView("Podcasts aren’t ready yet", systemImage: "mic")
        }
    }
}

// MARK: - Pieces

private struct Cover: View {
    let url: String?
    var size: CGFloat = 56

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "mic").foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EpisodeRow: View {
    let service: RemotePodcasts
    let item: EpisodeItem
    var showName = false

    var body: some View {
        let ep = item.episode
        let progress = service.episodeProgress(ep.id)
        HStack(alignment: .top, spacing: 12) {
            Cover(url: ep.artworkURL ?? item.show.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(ep.title).font(.headline).lineLimit(2)
                Text([showName ? item.show.title : nil, dateText(ep.publishedAt), lengthText(ep.durationSec),
                      progress.played ? String(localized: "Played") : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let notes = ep.summary {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let fraction = service.downloadFraction(ep.id) {
                HStack(spacing: 6) {
                    ProgressView(value: fraction).frame(width: 60)
                    Button { service.stopDownload(ep.id) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Stop download")
                }
            } else if service.isDownloaded(ep.id) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).help("Downloaded")
            } else {
                Button { service.download(ep.id) } label: {
                    Image(systemName: service.hasFailed(ep.id) ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help(service.hasFailed(ep.id) ? "The last download failed. Try again." : "Download")
            }
            Button { service.playEpisode(ep.id) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .help(progress.positionSec > 5 && !progress.played ? "Resume" : "Play")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Play") { service.playEpisode(ep.id) }
            if progress.played {
                Button("Mark as Unplayed") { service.setPlayed(ep.id, false) }
            } else {
                Button("Mark as Played") { service.setPlayed(ep.id, true) }
            }
            if service.isDownloaded(ep.id) {
                Button("Remove Download", role: .destructive) { service.removeDownload(ep.id) }
            }
        }
    }
}

private struct Empty: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pages

private struct ListenNow: View {
    let service: RemotePodcasts

    var body: some View {
        let lists = service.listenNow()
        if lists.inProgress.isEmpty && lists.fresh.isEmpty {
            Empty(text: "Nothing to listen to yet. Subscribe to a show in Find.")
        } else {
            List {
                if !lists.inProgress.isEmpty {
                    Section("Continue") {
                        ForEach(items(lists.inProgress)) { EpisodeRow(service: service, item: $0, showName: true) }
                    }
                }
                if !lists.fresh.isEmpty {
                    Section("New episodes") {
                        ForEach(items(lists.fresh)) { EpisodeRow(service: service, item: $0, showName: true) }
                    }
                }
            }
        }
    }
}

private struct Shows: View {
    let service: RemotePodcasts
    let open: (String) -> Void

    var body: some View {
        let shows = service.subscribedShows
        if shows.isEmpty {
            Empty(text: "You aren’t subscribed to any shows yet. Use Find.")
        } else {
            List(shows, id: \.id) { show in
                HStack(spacing: 12) {
                    Cover(url: show.artworkURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.title).font(.headline).lineLimit(1)
                        if let author = show.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    let fresh = service.newCount(show)
                    if fresh > 0 { Text("\(fresh) new").font(.caption).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { open(show.id) }
            }
        }
    }
}

private struct Downloads: View {
    let service: RemotePodcasts

    var body: some View {
        let list = items(service.downloadedEpisodes())
        if list.isEmpty {
            Empty(text: "No downloaded episodes.")
        } else {
            List(list) { EpisodeRow(service: service, item: $0, showName: true) }
        }
    }
}

private struct Find: View {
    let service: RemotePodcasts
    let open: (String) -> Void
    @State private var term = ""
    @State private var results: [DirectoryEntry] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var searched = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search podcasts", text: $term)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load() } }
                .padding([.horizontal, .bottom], 16)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let problem {
                Empty(text: problem)
            } else if results.isEmpty {
                Empty(text: searched.isEmpty ? "Press Return to search Apple’s podcast directory." : "No shows found.")
            } else {
                List(results, id: \.appleId) { entry in
                    HStack(spacing: 12) {
                        Cover(url: entry.artwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.headline).lineLimit(1)
                            if let author = entry.author { Text(author).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if service.knownShow(for: entry)?.subscribed == true {
                            Text("Subscribed").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Open") { Task { await openEntry(entry) } }
                    }
                }
            }
        }
        .task { if results.isEmpty && searched.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        problem = nil
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            results = text.isEmpty ? try await PodcastDirectory.top(genre: nil) : try await PodcastDirectory.search(text)
            searched = text.isEmpty ? "top" : text
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }

    private func openEntry(_ entry: DirectoryEntry) async {
        loading = true
        if let id = await service.openDirectoryShow(entry) {
            open(id)
        } else {
            problem = String(localized: "Couldn’t read that show’s feed.")
        }
        loading = false
    }
}

private struct ShowPage: View {
    let service: RemotePodcasts
    let showID: String
    let close: () -> Void

    var body: some View {
        if let show = service.show(showID) {
            List {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        Cover(url: show.artworkURL, size: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(show.title).font(.title2.bold())
                            if let author = show.author { Text(author).foregroundStyle(.secondary) }
                            if let about = show.description { Text(about).font(.callout).foregroundStyle(.secondary).lineLimit(5) }
                            HStack {
                                Button(show.subscribed ? "Unsubscribe" : "Subscribe") { service.setSubscribed(show.id, !show.subscribed) }
                                Button("Back") { close() }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Episodes") {
                    ForEach(items(show.episodes.prefix(150).map { (show, $0) })) { EpisodeRow(service: service, item: $0) }
                }
            }
            .task { await service.refreshShow(showID) }
        } else {
            Empty(text: "That show isn’t available any more.")
        }
    }
}

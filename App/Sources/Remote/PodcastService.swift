//
// Vespertine Remote: podcasts. Subscriptions, episode lists, downloads and playback for the phone's Podcasts tab.
// Everything lives in its own folder (Application Support/<app id>/Podcasts), apart from the music library. An episode
// is downloaded to that folder and then played through the normal player, so the music library is never touched.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Observation
import VespertineAudio
import VespertineLibrary

nonisolated struct PodcastEpisodeRecord: Codable, Sendable {
    var id: String
    var title: String
    var summary: String?
    var publishedAt: Double?
    var durationSec: Double?
    var audioURL: String
    var artworkURL: String?
}

nonisolated struct PodcastShowRecord: Codable, Sendable {
    var id: String
    var feedURL: String
    var appleId: Int?
    var title: String
    var author: String?
    var description: String?
    var artworkURL: String?
    var subscribed: Bool
    /// ms since 1970 of the last successful feed read; nil = never.
    var refreshedAt: Double?
    var episodes: [PodcastEpisodeRecord]
}

nonisolated struct PodcastProgress: Codable, Sendable {
    var positionSec: Double = 0
    var played = false
    var isNew = false
    /// File name of the downloaded copy, inside Downloads/<show id>/.
    var file: String?
    var touchedAt: Double = 0
}

/// Downloads episode files with progress. Files are moved to their place before the result is reported.
nonisolated final class PodcastDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    var onProgress: (@Sendable (String, Double) -> Void)?
    var onDone: (@Sendable (String, Result<URL, Error>) -> Void)?

    private struct Job { var id: String; var destination: URL; var finished = false }
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func start(id: String, url: URL, destination: URL) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("GRPlayer/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        lock.lock(); jobs[task.taskIdentifier] = Job(id: id, destination: destination); lock.unlock()
        task.resume()
    }

    func cancel(id: String) {
        lock.lock(); let ids = jobs.filter { $0.value.id == id }.map(\.key); lock.unlock()
        session.getAllTasks { tasks in tasks.filter { ids.contains($0.taskIdentifier) }.forEach { $0.cancel() } }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let job = jobs[downloadTask.taskIdentifier]; lock.unlock()
        guard let job else { return }
        if totalBytesWritten > Self.maxBytes { downloadTask.cancel(); return }
        if totalBytesExpectedToWrite > 0 { onProgress?(job.id, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); let job = jobs[downloadTask.taskIdentifier]; lock.unlock()
        guard let job else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(downloadTask.taskIdentifier, .failure(PodcastNetError.offline("HTTP \(http.statusCode)")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: job.destination)
            try FileManager.default.moveItem(at: location, to: job.destination)
            finish(downloadTask.taskIdentifier, .success(job.destination))
        } catch {
            finish(downloadTask.taskIdentifier, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let job = jobs[task.taskIdentifier]; lock.unlock()
        guard let job else { return }
        if let error, !job.finished { finish(task.taskIdentifier, .failure(error)) }
        lock.lock(); jobs[task.taskIdentifier] = nil; lock.unlock()
    }

    private func finish(_ taskID: Int, _ result: Result<URL, Error>) {
        lock.lock()
        guard var job = jobs[taskID], !job.finished else { lock.unlock(); return }
        job.finished = true
        jobs[taskID] = job
        lock.unlock()
        onDone?(job.id, result)
    }
}

@MainActor
@Observable
final class RemotePodcasts {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "mp4", "ogg", "opus", "wav", "flac"]
    static let staleShowMinutes = 10.0
    static let staleListMinutes = 30.0
    static let keptUnsubscribedShows = 40

    @ObservationIgnored private weak var model: AppModel?
    /// Told about things the phone should show as a toast ("Downloaded: …"); set by the remote when it is running.
    @ObservationIgnored var notify: (String) -> Void = { _ in }
    /// The latest short message, for the Mac screen; clears itself.
    private(set) var message: String?
    @ObservationIgnored private let root: URL
    private(set) var shows: [String: PodcastShowRecord] = [:]
    private(set) var progress: [String: PodcastProgress] = [:]
    @ObservationIgnored private var showOfEpisode: [String: String] = [:]
    private(set) var downloading: [String: Double] = [:]
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var otherAddresses: [String: [URL]] = [:]
    @ObservationIgnored private var playWhenReady: String?
    @ObservationIgnored private var playing: [String: String] = [:]
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private let downloader = PodcastDownloader()
    @ObservationIgnored private var progressDirty = false
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "GRPlayer", isDirectory: true)
            .appendingPathComponent("Podcasts", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads", isDirectory: true),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("shows.json")),
           let list = try? JSONDecoder().decode([PodcastShowRecord].self, from: data) {
            shows = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("progress.json")),
           let saved = try? JSONDecoder().decode([String: PodcastProgress].self, from: data) {
            progress = saved
        }
        reindex()
        downloader.onProgress = { [weak self] id, fraction in
            Task { @MainActor in self?.downloading[id] = max(fraction, 0.001) }
        }
        downloader.onDone = { [weak self] id, result in
            Task { @MainActor in self?.downloadFinished(id, result) }
        }
        // Remembers the place in an episode while it plays.
        ticker = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// Shows a short message on the Mac screen and on the phone.
    private func say(_ text: String) {
        message = text
        notify(text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.message == text { self?.message = nil }
        }
    }

    // MARK: Storage

    private func reindex() {
        showOfEpisode = [:]
        for show in shows.values { for ep in show.episodes { showOfEpisode[ep.id] = show.id } }
    }

    private func saveShows() {
        if let data = try? JSONEncoder().encode(Array(shows.values)) {
            try? data.write(to: root.appendingPathComponent("shows.json"), options: .atomic)
        }
    }

    private func saveProgress() {
        progressDirty = false
        lastProgressSave = Date()
        if let data = try? JSONEncoder().encode(progress) {
            try? data.write(to: root.appendingPathComponent("progress.json"), options: .atomic)
        }
    }

    private func downloadsFolder(_ showID: String) -> URL {
        root.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(showID, isDirectory: true)
    }

    private func filePath(_ episodeID: String) -> String? {
        guard let name = progress[episodeID]?.file, let showID = showOfEpisode[episodeID],
              name == (name as NSString).lastPathComponent else { return nil }
        let path = downloadsFolder(showID).appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func find(_ episodeID: String) -> (PodcastShowRecord, PodcastEpisodeRecord)? {
        guard let showID = showOfEpisode[episodeID], let show = shows[showID],
              let ep = show.episodes.first(where: { $0.id == episodeID }) else { return nil }
        return (show, ep)
    }

    // MARK: Feeds

    private static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    private func showID(forFeed address: String) -> String { "s" + PodcastText.hash(address, length: 12) }

    private func apply(_ feed: ParsedFeed, to id: String) {
        guard var show = shows[id] else { return }
        let first = show.refreshedAt == nil
        let known = Set(show.episodes.map(\.id))
        show.title = feed.title
        show.author = feed.author
        show.description = feed.description
        show.artworkURL = feed.artworkURL ?? show.artworkURL
        var fresh: [PodcastEpisodeRecord] = []
        var seen = Set<String>()
        for ep in feed.episodes {
            let epID = PodcastText.hash(id + "|" + (ep.guid ?? ep.audioURL))
            guard seen.insert(epID).inserted else { continue }
            fresh.append(PodcastEpisodeRecord(id: epID, title: ep.title, summary: ep.summary, publishedAt: ep.publishedAt,
                                              durationSec: ep.durationSec, audioURL: ep.audioURL, artworkURL: ep.artworkURL))
            if !first, !known.contains(epID) { progress[epID, default: PodcastProgress()].isNew = true }
        }
        // Episodes that left the feed stay while a download or a place in them is kept.
        let kept = show.episodes.filter { old in !seen.contains(old.id) && progress[old.id]?.file != nil }
        show.episodes = (fresh + kept).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        show.refreshedAt = Self.nowMs()
        shows[id] = show
        reindex()
        saveShows()
        saveProgress()
    }

    /// Reads the feed again. Returns an error text, nil on success.
    @discardableResult
    private func refresh(_ id: String) async -> String? {
        guard let show = shows[id], !refreshing.contains(id) else { return nil }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        do {
            let feed = try await PodcastNet.feed(show.feedURL)
            apply(feed, to: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshIfStale(_ id: String, minutes: Double) async {
        guard let at = shows[id]?.refreshedAt, Self.nowMs() - at < minutes * 60_000 else {
            await refresh(id)
            return
        }
    }

    private func refreshSubscribedInBackground() {
        let stale = shows.values.filter { $0.subscribed && Self.nowMs() - ($0.refreshedAt ?? 0) > Self.staleListMinutes * 60_000 }.map(\.id)
        guard !stale.isEmpty else { return }
        Task { @MainActor [weak self] in
            for id in stale { await self?.refresh(id) }
        }
    }

    /// The show for a directory entry: made and read if new.
    private func open(_ entry: DirectoryEntry) async -> String? {
        guard let feed = entry.feedURL, PodcastNet.candidates(feed).first != nil else { return nil }
        let id = showID(forFeed: feed)
        if shows[id] == nil {
            shows[id] = PodcastShowRecord(id: id, feedURL: feed, appleId: entry.appleId, title: entry.title, author: entry.author,
                                          description: nil, artworkURL: entry.artwork, subscribed: false, refreshedAt: nil, episodes: [])
            pruneUnsubscribed()
        }
        shows[id]?.appleId = entry.appleId
        await refreshIfStale(id, minutes: Self.staleShowMinutes)
        return shows[id]?.refreshedAt == nil ? nil : id
    }

    private func pruneUnsubscribed() {
        let loose = shows.values.filter { !$0.subscribed && !$0.episodes.contains { progress[$0.id]?.file != nil } }
        guard loose.count > Self.keptUnsubscribedShows else { return }
        for show in loose.sorted(by: { ($0.refreshedAt ?? 0) < ($1.refreshedAt ?? 0) }).prefix(loose.count - Self.keptUnsubscribedShows) {
            shows[show.id] = nil
        }
        reindex()
    }

    // MARK: Phone-facing objects

    private func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private func downloadState(_ id: String) -> (String, Any) {
        if filePath(id) != nil { return ("downloaded", NSNull()) }
        if let fraction = downloading[id] { return (fraction > 0.001 ? "downloading" : "queued", fraction) }
        if failed.contains(id) { return ("failed", NSNull()) }
        return ("none", NSNull())
    }

    private func episodeObject(_ show: PodcastShowRecord, _ ep: PodcastEpisodeRecord, shortNotes: Bool = true) -> [String: Any] {
        let p = progress[ep.id]
        let (state, fraction) = downloadState(ep.id)
        let notes = shortNotes ? ep.summary.map { String($0.prefix(300)) } : ep.summary
        return [
            "id": ep.id, "showId": show.id, "showTitle": show.title, "title": ep.title,
            "summary": orNull(notes), "publishedAt": orNull(ep.publishedAt), "durationSec": orNull(ep.durationSec),
            "positionSec": p?.positionSec ?? 0, "played": p?.played ?? false, "isNew": (p?.isNew ?? false) && !(p?.played ?? false),
            "download": state, "downloadProgress": fraction, "artwork": orNull(ep.artworkURL ?? show.artworkURL),
        ]
    }

    private func showObject(_ show: PodcastShowRecord) -> [String: Any] {
        let fresh = show.episodes.filter { (progress[$0.id]?.isNew ?? false) && !(progress[$0.id]?.played ?? false) }.count
        return ["id": show.id, "title": show.title, "author": orNull(show.author), "artwork": orNull(show.artworkURL),
                "newCount": fresh, "subscribed": show.subscribed]
    }

    private func showDetail(_ show: PodcastShowRecord) -> [String: Any] {
        var out = showObject(show)
        out["description"] = orNull(show.description)
        out["episodes"] = show.episodes.prefix(200).map { episodeObject(show, $0) }
        out["episodeTotal"] = show.episodes.count
        return out
    }

    private func directoryObject(_ e: DirectoryEntry) -> [String: Any] {
        let known = e.feedURL.flatMap { shows[showID(forFeed: $0)] }
        return ["appleId": e.appleId, "title": e.title, "author": orNull(e.author), "artwork": orNull(e.artwork),
                "showId": orNull(known?.id), "subscribed": known?.subscribed ?? false]
    }

    private func value(_ any: Any) -> RemoteResponse { .json(["value": any]) }
    private func failure(_ text: String, _ status: Int = 502) -> RemoteResponse { .json(["error": text], status: status) }

    // MARK: Queries

    /// nil when `type` isn't a podcast request.
    func query(_ type: String, _ body: [String: Any]) async -> RemoteResponse? {
        switch type {
        case "podcast-home":
            refreshSubscribedInBackground()
            let all = shows.values.flatMap { show in show.episodes.map { (show, $0) } }
            let inProgress = all.filter { (progress[$0.1.id]?.positionSec ?? 0) > 5 && !(progress[$0.1.id]?.played ?? false) }
                .sorted { (progress[$0.1.id]?.touchedAt ?? 0) > (progress[$1.1.id]?.touchedAt ?? 0) }.prefix(20)
            let fresh = all.filter { $0.0.subscribed && (progress[$0.1.id]?.isNew ?? false) && !(progress[$0.1.id]?.played ?? false) }
                .sorted { ($0.1.publishedAt ?? 0) > ($1.1.publishedAt ?? 0) }.prefix(30)
            return value(["inProgress": inProgress.map { episodeObject($0.0, $0.1) },
                          "newEpisodes": fresh.map { episodeObject($0.0, $0.1) }])
        case "podcast-shows":
            refreshSubscribedInBackground()
            let list = shows.values.filter(\.subscribed).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return value(list.map(showObject))
        case "podcast-show":
            guard let id = body["id"] as? String, shows[id] != nil else { return failure("Show not found", 404) }
            await refreshIfStale(id, minutes: Self.staleShowMinutes)
            guard let show = shows[id] else { return failure("Show not found", 404) }
            return value(showDetail(show))
        case "podcast-downloads":
            let all = shows.values.flatMap { show in show.episodes.map { (show, $0) } }
                .filter { filePath($0.1.id) != nil || downloading[$0.1.id] != nil }
                .sorted { ($0.1.publishedAt ?? 0) > ($1.1.publishedAt ?? 0) }
            return value(all.map { episodeObject($0.0, $0.1) })
        case "podcast-search":
            let term = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 120 else { return value([Any]()) }
            do { return value(try await PodcastDirectory.search(term).map(directoryObject)) }
            catch { return failure(error.localizedDescription) }
        case "podcast-top":
            do { return value(try await PodcastDirectory.top(genre: body["genreId"] as? Int).map(directoryObject)) }
            catch { return failure(error.localizedDescription) }
        case "podcast-open":
            guard let appleId = body["appleId"] as? Int else { return failure("Bad request", 400) }
            do {
                guard let entry = try await PodcastDirectory.lookup([appleId]).first,
                      let id = await open(entry), let show = shows[id] else {
                    return failure("Couldn’t read that show’s feed.")
                }
                return value(showDetail(show))
            } catch {
                return failure(error.localizedDescription)
            }
        default:
            return nil
        }
    }

    // MARK: Commands

    /// nil when `type` isn't a podcast command.
    func command(_ type: String, _ body: [String: Any]) -> RemoteResponse? {
        guard type.hasPrefix("podcast-") else { return nil }
        let ok = RemoteResponse.json(["value": NSNull()])
        switch type {
        case "podcast-subscribe", "podcast-unsubscribe":
            guard let id = body["showId"] as? String, shows[id] != nil else { return failure("Show not found", 404) }
            setSubscribed(id, type == "podcast-subscribe")
        case "podcast-download", "podcast-play", "podcast-cancel-download", "podcast-delete-download", "podcast-played":
            guard let id = body["episodeId"] as? String, find(id) != nil else { return failure("Episode not found", 404) }
            switch type {
            case "podcast-download": download(id)
            case "podcast-play": return play(id)
            case "podcast-cancel-download": stopDownload(id)
            case "podcast-delete-download": removeDownload(id)
            default:
                guard let played = body["played"] as? Bool else { return failure("Bad request", 400) }
                setPlayed(id, played)
            }
        default:
            return failure("Not available in GR Player", 400)
        }
        return ok
    }

    // MARK: Actions (the phone and the Mac screen both use these)

    func setSubscribed(_ showID: String, _ on: Bool) {
        guard shows[showID] != nil else { return }
        shows[showID]?.subscribed = on
        saveShows()
    }

    func download(_ episodeID: String) {
        guard let (show, ep) = find(episodeID) else { return }
        startDownload(show, ep)
    }

    func stopDownload(_ episodeID: String) {
        downloading[episodeID] = nil
        otherAddresses[episodeID] = nil
        if playWhenReady == episodeID { playWhenReady = nil }
        downloader.cancel(id: episodeID)
    }

    func removeDownload(_ episodeID: String) {
        if let path = filePath(episodeID) { try? FileManager.default.removeItem(atPath: path) }
        progress[episodeID]?.file = nil
        failed.remove(episodeID)
        saveProgress()
    }

    func setPlayed(_ episodeID: String, _ played: Bool) {
        progress[episodeID, default: PodcastProgress()].played = played
        progress[episodeID]?.isNew = false
        if played { progress[episodeID]?.positionSec = 0 }
        saveProgress()
    }

    func playEpisode(_ episodeID: String) { _ = play(episodeID) }

    // MARK: For the Mac screen

    var subscribedShows: [PodcastShowRecord] {
        shows.values.filter(\.subscribed).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func show(_ id: String) -> PodcastShowRecord? { shows[id] }
    func episodeProgress(_ id: String) -> PodcastProgress { progress[id] ?? PodcastProgress() }
    func isDownloaded(_ id: String) -> Bool { filePath(id) != nil }
    func downloadFraction(_ id: String) -> Double? { downloading[id] }
    func hasFailed(_ id: String) -> Bool { failed.contains(id) }
    func newCount(_ show: PodcastShowRecord) -> Int {
        show.episodes.filter { (progress[$0.id]?.isNew ?? false) && !(progress[$0.id]?.played ?? false) }.count
    }

    /// Episodes with a place saved, then the new ones from subscribed shows.
    func listenNow() -> (inProgress: [(PodcastShowRecord, PodcastEpisodeRecord)], fresh: [(PodcastShowRecord, PodcastEpisodeRecord)]) {
        let all = shows.values.flatMap { show in show.episodes.map { (show, $0) } }
        let inProgress = all.filter { (progress[$0.1.id]?.positionSec ?? 0) > 5 && !(progress[$0.1.id]?.played ?? false) }
            .sorted { (progress[$0.1.id]?.touchedAt ?? 0) > (progress[$1.1.id]?.touchedAt ?? 0) }
        let fresh = all.filter { $0.0.subscribed && (progress[$0.1.id]?.isNew ?? false) && !(progress[$0.1.id]?.played ?? false) }
            .sorted { ($0.1.publishedAt ?? 0) > ($1.1.publishedAt ?? 0) }
        return (Array(inProgress.prefix(20)), Array(fresh.prefix(30)))
    }

    func downloadedEpisodes() -> [(PodcastShowRecord, PodcastEpisodeRecord)] {
        shows.values.flatMap { show in show.episodes.map { (show, $0) } }
            .filter { filePath($0.1.id) != nil || downloading[$0.1.id] != nil }
            .sorted { ($0.1.publishedAt ?? 0) > ($1.1.publishedAt ?? 0) }
    }

    func refreshShow(_ id: String) async { await refreshIfStale(id, minutes: Self.staleShowMinutes) }
    func refreshAll() { refreshSubscribedInBackground() }
    func openDirectoryShow(_ entry: DirectoryEntry) async -> String? { await open(entry) }
    func knownShow(for entry: DirectoryEntry) -> PodcastShowRecord? { entry.feedURL.flatMap { shows[showID(forFeed: $0)] } }

    // MARK: Downloads

    private func startDownload(_ show: PodcastShowRecord, _ ep: PodcastEpisodeRecord) {
        guard downloading[ep.id] == nil, filePath(ep.id) == nil else { return }
        let urls = PodcastNet.candidates(ep.audioURL)
        guard let first = urls.first else { failed.insert(ep.id); say("That episode has no usable address."); return }
        failed.remove(ep.id)
        downloading[ep.id] = 0
        otherAddresses[ep.id] = Array(urls.dropFirst())
        attempt(show.id, ep.id, first)
    }

    private func attempt(_ showID: String, _ id: String, _ url: URL) {
        let folder = downloadsFolder(showID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = url.pathExtension.lowercased()
        let name = id + "." + (Self.audioExtensions.contains(ext) ? ext : "mp3")
        downloader.start(id: id, url: url, destination: folder.appendingPathComponent(name))
    }

    private func downloadFinished(_ id: String, _ result: Result<URL, Error>) {
        guard downloading[id] != nil else { return } // stopped by the user
        switch result {
        case .success(let url):
            downloading[id] = nil
            otherAddresses[id] = nil
            progress[id, default: PodcastProgress()].file = url.lastPathComponent
            saveProgress()
            if playWhenReady == id {
                playWhenReady = nil
                _ = play(id)
            } else if let (_, ep) = find(id) {
                say("Downloaded: \(ep.title)")
            }
        case .failure(let error):
            if var rest = otherAddresses[id], !rest.isEmpty, let showID = showOfEpisode[id] {
                let next = rest.removeFirst()
                otherAddresses[id] = rest
                downloading[id] = 0
                attempt(showID, id, next)
                return
            }
            downloading[id] = nil
            otherAddresses[id] = nil
            failed.insert(id)
            if playWhenReady == id { playWhenReady = nil }
            say("Couldn’t download the episode: \(error.localizedDescription)")
        }
    }

    // MARK: Playback

    private func play(_ id: String) -> RemoteResponse {
        guard let model, let (show, ep) = find(id) else { return failure("Episode not found", 404) }
        guard let path = filePath(id) else {
            playWhenReady = id
            if downloading[id] == nil { startDownload(show, ep) }
            say("Downloading the episode first…")
            return .json(["value": NSNull()])
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let track = Track.podcastEpisode(path: path, title: ep.title, show: show.title, author: nil,
                                         duration: ep.durationSec ?? 0, fileSize: size,
                                         published: ep.publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) })
        playing[path] = id
        progress[id, default: PodcastProgress()].isNew = false
        progress[id]?.touchedAt = Self.nowMs()
        saveProgress()
        let player = model.player
        player.play([track], shuffled: false)
        let resume = progress[id]?.positionSec ?? 0
        if resume > 5, ep.durationSec.map({ resume < $0 - 15 }) ?? true {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard player.current?.track.filePath == path else { return }
                player.seek(to: resume)
            }
        }
        return .json(["value": NSNull()])
    }

    /// What the phone shows for a queue entry that is a podcast episode, or nil for ordinary music.
    func info(forPath path: String) -> (showID: String, episodeID: String, showTitle: String, artwork: String?)? {
        guard let id = playing[path], let (show, ep) = find(id) else { return nil }
        return (show.id, id, show.title, ep.artworkURL ?? show.artworkURL)
    }

    /// Remembers the place in the episode that is playing, and marks it played near the end. Called often; cheap.
    func tick() {
        guard let player = model?.player, let track = player.current?.track, let id = playing[track.filePath],
              player.position.isFinite else { return }
        var p = progress[id] ?? PodcastProgress()
        let duration = player.duration > 0 ? player.duration : (find(id)?.1.durationSec ?? 0)
        if duration > 60, player.position >= duration - 20 {
            p.played = true
            p.positionSec = 0
            p.isNew = false
        } else {
            p.positionSec = player.position
        }
        p.touchedAt = Self.nowMs()
        progress[id] = p
        progressDirty = true
        if Date().timeIntervalSince(lastProgressSave) > 8 { saveProgress() }
    }
}

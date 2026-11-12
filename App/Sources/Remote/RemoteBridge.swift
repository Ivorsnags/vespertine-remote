//
// Vespertine Remote: connects the phone page to the player and the library.
// It speaks the same JSON protocol as the GR Player remote (see RemoteWeb/src/protocol.ts) and only presses buttons
// that the Mac app already has (`PlayerController`, `LibraryStore`); it never touches the audio engine.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import Observation
import VespertineAudio
import VespertineLibrary

@MainActor
final class RemoteBridge {
    private weak var model: AppModel?
    private let broadcast: (String, Data) -> Void
    private let clientCount: () -> Int

    private var stateRevision = 0
    private var queueRevision = 0
    private var libraryRevision = 0
    private var lastQueueIDs: [UUID] = []
    private var lastState: [String: Any] = [:]
    private var lastStateKey = ""
    private var lastLibraryRevision = -1
    private var publishScheduled = false
    private var notification: String?

    /// Songs sent in the queue list (a window around the current song).
    static let queueWindow = 400
    static let searchLimit = 30
    /// Not orange: a calm blue the page uses until the Mac app tells it otherwise.
    static let accent = "#6c8cff"

    init(model: AppModel, broadcast: @escaping (String, Data) -> Void, clientCount: @escaping () -> Int) {
        self.model = model
        self.broadcast = broadcast
        self.clientCount = clientCount
        watch()
    }

    // MARK: Watching the player

    /// Re-runs whenever something the phone shows changes, then publishes. `position` is read outside the tracking so
    /// that the ticking clock doesn't cause a publish every fraction of a second; the phone extrapolates from `sentAt`.
    private func watch() {
        guard let model else { return }
        withObservationTracking {
            let player = model.player
            _ = player.queue.map(\.id)
            _ = player.currentIndex
            _ = player.state
            _ = player.shuffle
            _ = player.repeatMode
            _ = player.duration
            _ = player.loading
            _ = player.lastError
            _ = player.signalPath?.isBitPerfect
            _ = model.library.revision
            _ = model.settings.exclusiveMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePublish()
                self?.watch()
            }
        }
    }

    /// Several changes in a row (a track change touches many properties) become one event.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.publishScheduled = false
            self?.publish()
        }
    }

    /// Sends what changed to every phone with a live stream.
    func publish() {
        guard let model else { return }
        let ids = model.player.queue.map(\.id)
        if ids != lastQueueIDs {
            lastQueueIDs = ids
            queueRevision += 1
        }
        if model.library.revision != lastLibraryRevision {
            if lastLibraryRevision != -1 { libraryRevision += 1; send("library", ["revision": libraryRevision]) }
            lastLibraryRevision = model.library.revision
        }
        let key = stateKey(model)
        if key != lastStateKey {
            lastStateKey = key
            stateRevision += 1
        }
        let state = stateObject(model)
        lastState = state
        send("state", state)
        if let queue = queueObject(model) { send("queue", queue) }
    }

    /// A summary of everything in the state except the clock, so a seek or pause is noticed but ticking is not.
    private func stateKey(_ model: AppModel) -> String {
        let p = model.player
        return [p.current?.id.uuidString ?? "-", p.state.rawValue, String(p.shuffle), p.repeatMode.rawValue,
                String(p.duration), String(p.loading), p.lastError ?? "", String(queueRevision),
                String(model.settings.exclusiveMode), notification ?? ""].joined(separator: "|")
    }

    private func send(_ event: String, _ object: Any) {
        guard clientCount() > 0, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        broadcast(event, data)
    }

    /// A short message the phone shows as a toast ("Added to queue"); cleared by the next change.
    func notify(_ text: String) {
        notification = text
        publish()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.notification == text { self?.notification = nil }
        }
    }

    // MARK: Requests

    func handle(_ request: RemoteRequest) async -> RemoteResponse {
        guard RemoteSecurity.isAllowedHost(request.headers["host"]) else {
            return .text("Unknown host", status: 421)
        }
        guard let model else { return .text("The Mac app is closing", status: 503) }
        switch request.path {
        case "/api/events":
            guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
            return .eventStream(initial: initialEvents(model))
        case "/api/snapshot":
            guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
            let known = request.query["queue"].flatMap(Int.init)
            return snapshot(model, knownQueue: known)
        case "/api/query", "/api/command":
            if let reason = RemoteSecurity.mutationRejection(
                method: request.method, host: request.headers["host"], origin: request.headers["origin"],
                contentType: request.headers["content-type"], clientHeader: request.headers[RemoteSecurity.clientHeader]) {
                return .json(["error": reason], status: 403)
            }
            guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let type = body["type"] as? String else {
                return .json(["error": "Bad request"], status: 400)
            }
            return request.path == "/api/query" ? query(type, body, model) : await command(type, body, model)
        case "/art":
            guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
            return await art(request.query["k"], size: request.query["s"].flatMap(Int.init) ?? 600)
        default:
            guard request.method == "GET" else { return .text("Method not allowed", status: 405) }
            return RemoteSite.file(for: request.path)
        }
    }

    private func initialEvents(_ model: AppModel) -> Data {
        var out = Data("retry: 2000\n\n".utf8)
        func add(_ event: String, _ object: Any) {
            guard JSONSerialization.isValidJSONObject(object),
                  let json = try? JSONSerialization.data(withJSONObject: object) else { return }
            out.append(Data("event: \(event)\ndata: ".utf8))
            out.append(json)
            out.append(Data("\n\n".utf8))
        }
        add("state", stateObject(model))
        if let queue = queueObject(model) { add("queue", queue) }
        return out
    }

    private func snapshot(_ model: AppModel, knownQueue: Int?) -> RemoteResponse {
        var out: [String: Any] = [
            "now": Int(Date().timeIntervalSince1970 * 1000),
            "state": stateObject(model),
            "library": libraryRevision,
        ]
        if knownQueue != queueRevision, let queue = queueObject(model) { out["queue"] = queue }
        return .json(out)
    }

    // MARK: State and queue

    private func stateObject(_ model: AppModel) -> [String: Any] {
        let p = model.player
        let track = p.current?.track
        let bitPerfect = p.signalPath?.isBitPerfect == true
        var quality: Any = NSNull()
        if track != nil {
            quality = bitPerfect ? "bit-perfect" : (model.settings.exclusiveMode ? "processed" : "system-mixer")
        }
        var format: Any = NSNull()
        if let track {
            format = [
                "codec": track.codec.isEmpty ? NSNull() : track.codec as Any,
                "bitDepth": track.bitDepth.map { "\($0)bit" as Any } ?? NSNull(),
                "sampleRate": Self.sampleRateLabel(track.sampleRate) as Any,
                "bitrate": track.isLossless ? NSNull() : (track.bitrate.map { "\(Int($0))kbps" as Any } ?? NSNull()),
                "lossless": track.isLossless,
                "hiRes": track.isHiRes,
                "quality": quality,
            ] as [String: Any]
        }
        let duration = Self.finite(p.duration > 0 ? p.duration : (track?.duration ?? 0))
        return [
            "revision": stateRevision,
            "sentAt": Int(Date().timeIntervalSince1970 * 1000),
            "track": p.current.map { trackObject($0, model) } ?? NSNull(),
            "isPlaying": p.state == .playing,
            "positionSec": Self.finite(p.position),
            "durationSec": duration,
            "volume": 1.0,
            "volumeLocked": true,
            "shuffle": p.shuffle,
            "repeat": p.repeatMode.rawValue,
            "contextLabel": NSNull(),
            "format": format,
            "outputMode": model.settings.exclusiveMode ? "exclusive" : "shared",
            "outputName": NSNull(),
            "notification": notification as Any? ?? NSNull(),
            "error": p.lastError as Any? ?? NSNull(),
            "heldForPhone": false,
            "accent": Self.accent,
            "queueRevision": queueRevision,
        ]
    }

    private func trackObject(_ entry: QueueEntry, _ model: AppModel) -> [String: Any] {
        let t = entry.track
        return [
            "key": entry.id.uuidString,
            "title": t.title,
            "artist": t.displayArtist.libraryDisplayName,
            "album": t.displayAlbum.libraryDisplayName,
            "durationSec": Self.finite(t.duration),
            "artwork": artURL(artworkKey(model, t)) as Any? ?? NSNull(),
            "catalogAlbumId": t.albumKey,
            "catalogArtistId": t.displayAlbumArtist.libraryDisplayName,
            "isRadio": false,
        ]
    }

    private func queueObject(_ model: AppModel) -> [String: Any]? {
        let p = model.player
        let all = p.queue
        let current = p.currentIndex ?? -1
        let start = max(0, min(current - 20, all.count - Self.queueWindow))
        let end = min(all.count, start + Self.queueWindow)
        let items = all[start..<end].map { trackObject($0, model) }
        return [
            "revision": queueRevision,
            "offset": start,
            "currentIndex": current,
            "total": all.count,
            "shuffle": p.shuffle,
            "canReorder": !p.shuffle,
            "items": items,
        ]
    }

    // MARK: Library queries

    private func query(_ type: String, _ body: [String: Any], _ model: AppModel) -> RemoteResponse {
        let library = model.library
        switch type {
        case "queue":
            return value(queueObject(model) ?? NSNull())
        case "albums":
            return value(library.albums.map(albumObject))
        case "artists":
            return value(library.artists.map(artistObject))
        case "album":
            guard let id = body["id"] as? String, let album = library.album(key: id) else {
                return .json(["error": "Album not found"], status: 404)
            }
            let tracks = library.tracks(albumKey: id)
            var detail = albumObject(album)
            detail["tracks"] = tracks.map { libraryTrackObject($0, model) }
            detail["totalDurationSec"] = Self.finite(tracks.reduce(0) { $0 + $1.duration })
            return value(detail)
        case "artist":
            guard let id = body["id"] as? String, let artist = library.artists.first(where: { $0.name == id }) else {
                return .json(["error": "Artist not found"], status: 404)
            }
            let albums = library.albums(artist: id)
            var detail = artistObject(artist)
            detail["bio"] = NSNull()
            detail["genres"] = [String]()
            detail["albums"] = albums.map(albumObject)
            detail["appearsOn"] = [[String: Any]]()
            detail["topTracks"] = albums.prefix(3).flatMap { library.tracks(albumKey: $0.key) }.prefix(10)
                .map { libraryTrackObject($0, model) }
            return value(detail)
        case "search":
            let text = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 200 else {
                return value(["artists": [Any](), "albums": [Any](), "tracks": [Any]()])
            }
            let lower = text.lowercased()
            let artists = library.artists.filter { $0.name.lowercased().contains(lower) }.prefix(Self.searchLimit)
            let albums = library.albums.filter {
                $0.title.lowercased().contains(lower) || $0.artist.lowercased().contains(lower)
            }.prefix(Self.searchLimit)
            let tracks = library.search(text).prefix(Self.searchLimit)
            return value(["artists": artists.map(artistObject), "albums": albums.map(albumObject),
                          "tracks": tracks.map { libraryTrackObject($0, model) }])
        default:
            return .json(["error": "Not available in Vespertine Remote"], status: 400)
        }
    }

    private func value(_ any: Any) -> RemoteResponse { .json(["value": any]) }

    private func albumObject(_ album: Album) -> [String: Any] {
        [
            "id": album.key,
            "title": album.title,
            "artist": album.artist.libraryDisplayName,
            "artistId": album.artist.libraryDisplayName,
            "year": album.year.map { $0 as Any } ?? NSNull(),
            "artwork": artURL(album.artworkKey) as Any? ?? NSNull(),
            "trackCount": album.trackCount,
        ]
    }

    private func artistObject(_ artist: LibraryDatabase.ArtistSummary) -> [String: Any] {
        [
            "id": artist.name,
            "name": artist.name.libraryDisplayName,
            "artwork": artURL(artist.artworkKey) as Any? ?? NSNull(),
            "albumCount": artist.albumCount,
            "trackCount": artist.trackCount,
        ]
    }

    private func libraryTrackObject(_ t: Track, _ model: AppModel) -> [String: Any] {
        [
            "id": t.id.map { String($0) } ?? "",
            "title": t.title,
            "artist": t.displayArtist.libraryDisplayName,
            "artistId": t.displayAlbumArtist.libraryDisplayName,
            "album": t.displayAlbum.libraryDisplayName,
            "albumId": t.albumKey,
            "trackNumber": t.trackNumber.map { $0 as Any } ?? NSNull(),
            "discNumber": t.discNumber.map { $0 as Any } ?? NSNull(),
            "durationSec": Self.finite(t.duration),
            "artwork": artURL(artworkKey(model, t)) as Any? ?? NSNull(),
            "playable": true,
            "format": t.codec.isEmpty ? NSNull() : t.codec as Any,
        ]
    }

    // MARK: Commands

    private func command(_ type: String, _ body: [String: Any], _ model: AppModel) async -> RemoteResponse {
        let player = model.player
        let library = model.library
        switch type {
        case "toggle": player.togglePlayPause()
        case "play": if player.state != .playing { player.togglePlayPause() }
        case "pause": player.pause()
        case "next": player.next()
        case "previous": player.previous()
        case "seek":
            guard let seconds = (body["positionSec"] as? Double), seconds.isFinite else { return bad() }
            let limit = player.duration > 0 ? player.duration : (player.current?.track.duration ?? 0)
            player.seek(to: min(max(0, seconds), max(0, limit)))
        case "skip":
            guard let seconds = (body["seconds"] as? Double), seconds.isFinite else { return bad() }
            let limit = player.duration > 0 ? player.duration : (player.current?.track.duration ?? 0)
            player.seek(to: min(max(0, player.position + seconds), max(0, limit)))
        case "volume":
            break // The remote has no volume: Vespertine is bit-perfect and leaves volume to the DAC or the Mac.
        case "shuffle":
            guard let enabled = body["enabled"] as? Bool else { return bad() }
            player.shuffle = enabled
        case "repeat":
            guard let mode = (body["mode"] as? String).flatMap(RepeatMode.init(rawValue:)) else { return bad() }
            player.repeatMode = mode
        case "queue-jump", "queue-remove", "queue-move":
            guard let entry = resolve(body["target"], player) else {
                return .json(["error": "The queue changed. Pick again."], status: 409)
            }
            if type == "queue-jump" {
                player.jump(to: entry.id)
            } else if type == "queue-remove" {
                player.removeFromQueue(entry.id)
            } else {
                guard !player.shuffle, let to = body["toIndex"] as? Int,
                      let from = player.queue.firstIndex(where: { $0.id == entry.id }),
                      player.queue.indices.contains(to) else { return bad() }
                let before = to > from ? (to + 1 < player.queue.count ? player.queue[to + 1].id : nil) : player.queue[to].id
                player.moveUpcoming([entry.id], before: before)
            }
        case "queue-clear":
            player.clearUpcoming()
        case "play-album":
            guard let id = body["albumId"] as? String else { return bad() }
            let tracks = model.playableTracks(albumKey: id)
            guard !tracks.isEmpty else { return .json(["error": "Album not found"], status: 404) }
            let start = (body["startTrackId"] as? String).flatMap { Int64($0) }
                .flatMap { sid in tracks.firstIndex { $0.id == sid } } ?? 0
            player.play(tracks, startAt: start, shuffled: body["shuffle"] as? Bool)
        case "play-artist":
            guard let id = body["artistId"] as? String else { return bad() }
            let tracks = library.albums(artist: id).flatMap { model.playableTracks(albumKey: $0.key) }
            guard !tracks.isEmpty else { return .json(["error": "Artist not found"], status: 404) }
            player.play(tracks, shuffled: body["shuffle"] as? Bool)
        case "play-tracks":
            guard let ids = body["trackIds"] as? [String], ids.count <= 2000 else { return bad() }
            let tracks = orderedTracks(ids, library)
            guard !tracks.isEmpty else { return .json(["error": "Songs not found"], status: 404) }
            let start = min(max(0, body["startIndex"] as? Int ?? 0), tracks.count - 1)
            player.play(tracks, startAt: start)
        case "enqueue-album":
            guard let id = body["albumId"] as? String else { return bad() }
            let tracks = model.playableTracks(albumKey: id)
            guard !tracks.isEmpty else { return .json(["error": "Album not found"], status: 404) }
            if body["next"] as? Bool == true { player.playNext(tracks) } else { player.addToQueue(tracks) }
        case "enqueue-track":
            guard let id = body["trackId"] as? String else { return bad() }
            let tracks = orderedTracks([id], library)
            guard !tracks.isEmpty else { return .json(["error": "Song not found"], status: 404) }
            if body["next"] as? Bool == true { player.playNext(tracks) } else { player.addToQueue(tracks) }
        default:
            return .json(["error": "Not available in Vespertine Remote"], status: 400)
        }
        publish()
        return .json(["value": NSNull()])
    }

    private func bad() -> RemoteResponse { .json(["error": "Bad request"], status: 400) }

    /// The queue entry a queue command names, only if the queue is still the one the phone saw.
    private func resolve(_ target: Any?, _ player: PlayerController) -> QueueEntry? {
        guard let target = target as? [String: Any], let index = target["index"] as? Int,
              let key = target["key"] as? String, target["revision"] as? Int == queueRevision,
              player.queue.indices.contains(index), player.queue[index].id.uuidString == key else { return nil }
        return player.queue[index]
    }

    private func orderedTracks(_ ids: [String], _ library: LibraryStore) -> [Track] {
        let numbers = ids.compactMap { Int64($0) }
        let byID = Dictionary(library.tracks(ids: numbers).compactMap { t in t.id.map { ($0, t) } },
                              uniquingKeysWith: { a, _ in a })
        return numbers.compactMap { byID[$0] }
    }

    // MARK: Cover art

    private func artworkKey(_ model: AppModel, _ track: Track) -> String? {
        track.artworkKey ?? model.library.album(key: track.albumKey)?.artworkKey
    }

    private func artURL(_ key: String?) -> String? {
        guard let key, let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return "/art?k=\(encoded)"
    }

    private func art(_ key: String?, size: Int) async -> RemoteResponse {
        guard let key, !key.isEmpty,
              let image = await ArtworkCache.shared.image(key, size: min(max(64, size), 1200)),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return .text("No cover", status: 404)
        }
        return .file(data, contentType: "image/jpeg", cache: "private, max-age=86400")
    }

    // MARK: Helpers

    nonisolated static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    /// "96kHz", "44.1kHz", "5.6MHz" (the same labels as the Mac app).
    nonisolated static func sampleRateLabel(_ hz: Double) -> String? {
        guard hz.isFinite, hz > 0 else { return nil }
        if hz >= 1_000_000 { return String(format: "%.1fMHz", hz / 1_000_000) }
        let khz = hz / 1000
        return khz == khz.rounded() ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz)
    }
}

//
// Vespertine Remote: what the phone may ask for, and the player controls it reaches.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit
import Foundation
import VespertineAudio
import VespertineLibrary

/// Answers the remote's requests. Every call under /api/ needs the PIN (header `X-Pin`), and commands are POST only.
/// It only presses the same buttons as the media keys do (`PlayerController`); it never touches the audio engine.
@MainActor
final class RemoteAPI {
    private weak var model: AppModel?
    private let pin: () -> String
    private var failures: [Date] = []
    private var lockedUntil: Date?

    /// This many wrong PINs within `window` lock the remote for `lockSeconds`.
    static let maxFailures = 5
    static let window: TimeInterval = 60
    static let lockSeconds: TimeInterval = 60
    /// Songs listed under Up Next.
    static let queueLimit = 60

    init(model: AppModel, pin: @escaping () -> String) {
        self.model = model
        self.pin = pin
    }

    func handle(_ request: RemoteRequest) async -> RemoteResponse {
        if request.path == "/" || request.path == "/index.html" {
            return request.method == "GET" ? .html(RemotePage.html) : .text("Method not allowed", status: 405)
        }
        guard request.path.hasPrefix("/api/"), let model else { return .text("Not found", status: 404) }
        if let refused = checkPIN(request) { return refused }
        let player = model.player

        switch (request.method, request.path) {
        case ("GET", "/api/state"):
            return .json(state(model))
        case ("GET", "/api/art"):
            return await art(model)
        case ("POST", "/api/toggle"):
            player.togglePlayPause()
        case ("POST", "/api/next"):
            player.next()
        case ("POST", "/api/previous"):
            player.previous()
        case ("POST", "/api/shuffle"):
            player.shuffle.toggle()
        case ("POST", "/api/repeat"):
            switch player.repeatMode {
            case .off: player.repeatMode = .all
            case .all: player.repeatMode = .one
            case .one: player.repeatMode = .off
            }
        case ("POST", "/api/seek"):
            guard let seconds = request.query["to"].flatMap(Double.init), seconds.isFinite else {
                return .text("Bad request", status: 400)
            }
            let limit = player.duration > 0 ? player.duration : (player.current?.track.duration ?? 0)
            player.seek(to: min(max(0, seconds), max(0, limit)))
        case ("POST", "/api/jump"):
            guard let id = request.query["id"].flatMap(UUID.init(uuidString:)) else { return .text("Bad request", status: 400) }
            player.jump(to: id)
        case (_, "/api/state"), (_, "/api/art"), (_, "/api/toggle"), (_, "/api/next"), (_, "/api/previous"),
             (_, "/api/shuffle"), (_, "/api/repeat"), (_, "/api/seek"), (_, "/api/jump"):
            return .text("Method not allowed", status: 405)
        default:
            return .text("Not found", status: 404)
        }
        // A command: answer with the new state so the phone updates at once.
        return .json(state(model))
    }

    // MARK: PIN

    /// nil when the request may go on, otherwise the refusal.
    private func checkPIN(_ request: RemoteRequest) -> RemoteResponse? {
        let now = Date()
        if let until = lockedUntil {
            if until > now { return .text("Too many wrong PINs. Try again in a minute.", status: 429) }
            lockedUntil = nil
            failures = []
        }
        if Self.matches(request.headers["x-pin"] ?? "", pin()) { return nil }
        failures = failures.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if failures.count >= Self.maxFailures { lockedUntil = now.addingTimeInterval(Self.lockSeconds) }
        return .text("PIN needed", status: 401)
    }

    /// Compares without stopping at the first difference.
    nonisolated static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        var difference = a.count ^ b.count
        for i in 0..<min(a.count, b.count) { difference |= Int(a[i] ^ b[i]) }
        return difference == 0 && !b.isEmpty
    }

    // MARK: State

    private func state(_ model: AppModel) -> [String: Any] {
        let player = model.player
        let track = player.current?.track
        var out: [String: Any] = [
            "state": player.state.rawValue,
            "position": Self.finite(player.position),
            "duration": Self.finite(player.duration > 0 ? player.duration : (track?.duration ?? 0)),
            "shuffle": player.shuffle,
            "repeat": player.repeatMode.rawValue,
            "loading": player.loading,
            "bitPerfect": player.signalPath?.isBitPerfect == true,
        ]
        if let track {
            out["title"] = track.title
            out["artist"] = track.displayArtist.libraryDisplayName
            out["album"] = track.displayAlbum.libraryDisplayName
            out["codec"] = track.codec
            out["sampleRate"] = Self.finite(track.sampleRate)
            if let depth = track.bitDepth { out["bitDepth"] = depth }
            out["art"] = artKey(model, track) ?? ""
        }
        out["queue"] = player.upcoming.prefix(Self.queueLimit).map { entry -> [String: Any] in
            ["id": entry.id.uuidString,
             "title": entry.track.title,
             "artist": entry.track.displayArtist.libraryDisplayName,
             "queued": entry.queuedByUser]
        }
        return out
    }

    nonisolated static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

    // MARK: Cover art

    private func artKey(_ model: AppModel, _ track: Track) -> String? {
        track.artworkKey ?? model.library.album(key: track.albumKey)?.artworkKey
    }

    private func art(_ model: AppModel) async -> RemoteResponse {
        guard let track = model.player.current?.track, let key = artKey(model, track),
              let image = await ArtworkCache.shared.image(key, size: 600),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return .text("No cover", status: 404)
        }
        return .jpeg(data)
    }
}

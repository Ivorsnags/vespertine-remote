//
// Vespertine Remote: reading a podcast feed, and asking Apple's public podcast directory.
// Only plain data here (no UI, no player). Feeds and the directory are the only things this app fetches from the
// internet, and only when you open, search or download a podcast.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation

nonisolated struct ParsedEpisode: Sendable {
    var guid: String?
    var title: String
    var summary: String?
    /// ms since 1970.
    var publishedAt: Double?
    var durationSec: Double?
    var audioURL: String
    var artworkURL: String?
}

nonisolated struct ParsedFeed: Sendable {
    var title: String
    var author: String?
    var description: String?
    var artworkURL: String?
    var newFeedURL: String?
    var episodes: [ParsedEpisode]
}

nonisolated enum PodcastText {
    /// Notes as plain text: tags removed, common entities decoded, spaces collapsed, shortened.
    static func plain(_ html: String?, limit: Int = 700) -> String? {
        guard var text = html else { return nil }
        text = text.replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// "1:02:03", "45:10" or "2710" as seconds.
    static func duration(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        let values = parts.compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    static func date(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let formats = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z",
                       "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date.timeIntervalSince1970 * 1000 }
        return nil
    }

    /// A short stable id from any text (a feed address, an episode's guid).
    static func hash(_ text: String, length: Int = 16) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(length / 2).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads RSS 2.0 with Apple's itunes: tags. Sloppy feeds are tolerated: unknown tags are ignored and an item without
/// an audio file is skipped.
nonisolated final class FeedParser: NSObject, XMLParserDelegate {
    static let maxEpisodes = 500

    static func parse(_ data: Data) -> ParsedFeed? {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        guard delegate.sawChannel, let title = delegate.channel["title"]?.nonEmpty else { return nil }
        let image = delegate.channel["itunes:image"] ?? delegate.channel["image"]
        return ParsedFeed(
            title: title,
            author: delegate.channel["itunes:author"]?.nonEmpty,
            description: PodcastText.plain(delegate.channel["description"] ?? delegate.channel["itunes:summary"], limit: 1500),
            artworkURL: image?.nonEmpty,
            newFeedURL: delegate.channel["itunes:new-feed-url"]?.nonEmpty,
            episodes: delegate.episodes)
    }

    private var stack: [String] = []
    private var text = ""
    private var sawChannel = false
    private var item: [String: String]?
    private var channel: [String: String] = [:]
    private var episodes: [ParsedEpisode] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        stack.append(name)
        text = ""
        if name == "channel" { sawChannel = true }
        if name == "item" { item = [:] }
        if name == "enclosure", item != nil, let url = attributes["url"] {
            item?["enclosure"] = url
        }
        if name == "itunes:image", let href = attributes["href"] {
            if item != nil { item?["itunes:image"] = href } else { channel["itunes:image"] = href }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { _ = stack.popLast(); text = "" }
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "item" {
            finishItem()
        } else if item != nil, parent == "item" {
            if !value.isEmpty, item?[name] == nil { item?[name] = value }
        } else if item == nil, parent == "channel" {
            if !value.isEmpty, channel[name] == nil { channel[name] = value }
        } else if item == nil, name == "url", parent == "image", channel["image"] == nil, !value.isEmpty {
            channel["image"] = value
        }
    }

    private func finishItem() {
        defer { item = nil }
        guard let item, let audio = item["enclosure"], episodes.count < Self.maxEpisodes else { return }
        let notes = item["content:encoded"] ?? item["itunes:summary"] ?? item["description"]
        episodes.append(ParsedEpisode(
            guid: item["guid"],
            title: item["title"]?.nonEmpty ?? "Episode",
            summary: PodcastText.plain(notes),
            publishedAt: PodcastText.date(item["pubDate"]),
            durationSec: PodcastText.duration(item["itunes:duration"]),
            audioURL: audio,
            artworkURL: item["itunes:image"]))
    }
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Fetching

nonisolated enum PodcastNetError: LocalizedError {
    case badURL, offline(String), tooBig, notAFeed

    var errorDescription: String? {
        switch self {
        case .badURL: "That address isn’t a web address."
        case .offline(let why): "Couldn’t reach the podcast server: \(why)"
        case .tooBig: "That feed is too large."
        case .notAFeed: "That didn’t look like a podcast feed."
        }
    }
}

nonisolated enum PodcastNet {
    static let maxFeedBytes = 20 * 1024 * 1024

    /// https first for an http address (macOS refuses plain http by default); the original after that.
    static func candidates(_ text: String) -> [URL] {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        guard scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [url] }
        parts.scheme = "https"
        return [parts.url, url].compactMap { $0 }
    }

    static func fetch(_ address: String, accept: String = "*/*") async throws -> Data {
        let urls = candidates(address)
        guard !urls.isEmpty else { throw PodcastNetError.badURL }
        var lastError: Error = PodcastNetError.badURL
        for url in urls {
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("GRPlayer/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue(accept, forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = PodcastNetError.offline("HTTP \(http.statusCode)")
                    continue
                }
                guard data.count <= maxFeedBytes else { throw PodcastNetError.tooBig }
                return data
            } catch let error as PodcastNetError {
                throw error
            } catch {
                lastError = PodcastNetError.offline(error.localizedDescription)
            }
        }
        throw lastError
    }

    static func feed(_ address: String) async throws -> ParsedFeed {
        let data = try await fetch(address, accept: "application/rss+xml, application/xml, text/xml, */*")
        guard let parsed = FeedParser.parse(data) else { throw PodcastNetError.notAFeed }
        return parsed
    }
}

// MARK: - Apple's directory

nonisolated struct DirectoryEntry: Sendable {
    var appleId: Int
    var title: String
    var author: String?
    var artwork: String?
    var feedURL: String?
}

/// Apple's public podcast directory (iTunes Search and the chart feeds): no account, and nothing about you is sent
/// except the search words or the chosen category. UK storefront, like GR Player.
nonisolated enum PodcastDirectory {
    static let country = "gb"
    static let chartSize = 50

    private static func json(_ address: String) async throws -> [String: Any] {
        let data = try await PodcastNet.fetch(address, accept: "application/json")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PodcastNetError.notAFeed }
        return object
    }

    private static func entry(_ r: [String: Any]) -> DirectoryEntry? {
        guard let id = (r["collectionId"] as? Int) ?? (r["trackId"] as? Int),
              let title = (r["collectionName"] as? String) ?? (r["trackName"] as? String) else { return nil }
        if let kind = r["kind"] as? String, kind != "podcast" { return nil }
        return DirectoryEntry(appleId: id, title: title, author: r["artistName"] as? String,
                              artwork: (r["artworkUrl600"] as? String) ?? (r["artworkUrl100"] as? String),
                              feedURL: r["feedUrl"] as? String)
    }

    static func search(_ term: String) async throws -> [DirectoryEntry] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let object = try await json("https://itunes.apple.com/search?media=podcast&entity=podcast&country=\(country)&limit=50&term=\(encoded)")
        return (object["results"] as? [[String: Any]] ?? []).compactMap(entry)
    }

    static func lookup(_ ids: [Int]) async throws -> [DirectoryEntry] {
        var seen = Set<Int>()
        let unique = ids.filter { $0 > 0 && seen.insert($0).inserted }
        var found: [Int: DirectoryEntry] = [:]
        var start = 0
        while start < unique.count {
            let batch = unique[start..<min(start + 150, unique.count)]
            let object = try await json("https://itunes.apple.com/lookup?country=\(country)&entity=podcast&id=\(batch.map(String.init).joined(separator: ","))")
            for r in object["results"] as? [[String: Any]] ?? [] { if let e = entry(r) { found[e.appleId] = e } }
            start += 150
        }
        return unique.compactMap { found[$0] }
    }

    /// Top shows overall, or in one of Apple's categories, in chart order.
    static func top(genre: Int?) async throws -> [DirectoryEntry] {
        var ids: [Int] = []
        do {
            let g = genre.map { "/genre=\($0)" } ?? ""
            let object = try await json("https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(chartSize)\(g)/json")
            let feed = object["feed"] as? [String: Any]
            let raw = feed?["entry"]
            let list = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
            ids = list.compactMap { (($0["id"] as? [String: Any])?["attributes"] as? [String: Any])?["im:id"] as? String }.compactMap(Int.init)
        } catch {
            if genre != nil { throw error }
        }
        if ids.isEmpty, genre == nil {
            let object = try await json("https://rss.applemarketingtools.com/api/v2/\(country)/podcasts/top/\(chartSize)/podcasts.json")
            let results = (object["feed"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            ids = results.compactMap { ($0["id"] as? String).flatMap(Int.init) }
        }
        return try await lookup(ids)
    }
}

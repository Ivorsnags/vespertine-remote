// Vespertine Remote: tests for reading podcast feeds and the small text helpers.
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Vespertine

@Suite("Podcasts")
struct PodcastFeedTests {
    static let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Test Show</title>
        <itunes:author>A. Host</itunes:author>
        <description>About the show</description>
        <itunes:image href="https://example.com/show.jpg"/>
        <image><url>https://example.com/old.jpg</url><title>Not the show title</title></image>
        <item>
          <title>Episode Two</title>
          <guid>two</guid>
          <pubDate>Tue, 10 Nov 2026 08:00:00 +0000</pubDate>
          <itunes:duration>1:02:03</itunes:duration>
          <description><![CDATA[<p>Notes &amp; links</p>]]></description>
          <enclosure url="https://example.com/two.mp3" type="audio/mpeg" length="1234"/>
        </item>
        <item>
          <title>No audio here</title>
          <guid>skip</guid>
        </item>
        <item>
          <title>Episode One</title>
          <guid>one</guid>
          <itunes:duration>2710</itunes:duration>
          <enclosure url="https://example.com/one.m4a" type="audio/mp4"/>
          <itunes:image href="https://example.com/one.jpg"/>
        </item>
      </channel>
    </rss>
    """

    @Test("A feed gives its show details and only the items that have audio")
    func parsesFeed() throws {
        let parsed = try #require(FeedParser.parse(Data(Self.feed.utf8)))
        #expect(parsed.title == "Test Show")
        #expect(parsed.author == "A. Host")
        #expect(parsed.artworkURL == "https://example.com/show.jpg")
        #expect(parsed.episodes.count == 2)
        #expect(parsed.episodes[0].title == "Episode Two")
        #expect(parsed.episodes[0].audioURL == "https://example.com/two.mp3")
        #expect(parsed.episodes[0].durationSec == 3723)
        #expect(parsed.episodes[0].summary == "Notes & links")
        #expect(parsed.episodes[0].publishedAt != nil)
        #expect(parsed.episodes[1].durationSec == 2710)
        #expect(parsed.episodes[1].artworkURL == "https://example.com/one.jpg")
    }

    @Test("Something that isn't a feed is refused")
    func notAFeed() {
        #expect(FeedParser.parse(Data("<html><body>hello</body></html>".utf8)) == nil)
        #expect(FeedParser.parse(Data("not xml at all".utf8)) == nil)
    }

    @Test("Durations in the three common forms, and nonsense")
    func durations() {
        #expect(PodcastText.duration("1:02:03") == 3723)
        #expect(PodcastText.duration("45:10") == 2710)
        #expect(PodcastText.duration("90") == 90)
        #expect(PodcastText.duration("soon") == nil)
        #expect(PodcastText.duration("") == nil)
    }

    @Test("Notes become short plain text")
    func plainText() {
        #expect(PodcastText.plain("<p>One</p><p>Two &amp; three</p>") == "One\nTwo & three")
        #expect(PodcastText.plain("   ") == nil)
        #expect((PodcastText.plain(String(repeating: "a", count: 2000)) ?? "").count == 701)
    }

    @Test("Ids are stable and different for different input")
    func ids() {
        #expect(PodcastText.hash("a") == PodcastText.hash("a"))
        #expect(PodcastText.hash("a") != PodcastText.hash("b"))
        #expect(PodcastText.hash("a", length: 12).count == 12)
    }

    @Test("An http address is tried as https first; other kinds of address are refused")
    func addresses() {
        #expect(PodcastNet.candidates("http://example.com/a.mp3").map(\.absoluteString) == ["https://example.com/a.mp3", "http://example.com/a.mp3"])
        #expect(PodcastNet.candidates("https://example.com/a.mp3").count == 1)
        #expect(PodcastNet.candidates("file:///etc/passwd").isEmpty)
        #expect(PodcastNet.candidates("javascript:alert(1)").isEmpty)
    }
}

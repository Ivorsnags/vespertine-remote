//
// Vespertine Remote: a song record for a downloaded podcast episode, so the player can queue and play it without
// the episode being in the library database. New file; nothing upstream is edited.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public extension Track {
    /// A track for a downloaded podcast episode: not stored in the library (no id), played from `path`.
    static func podcastEpisode(path: String, title: String, show: String, author: String?, duration: Double,
                               fileSize: Int64, published: Date?) -> Track {
        Track(
            id: nil, sourceId: nil,
            location: path, filePath: path,
            fileSize: fileSize, modifiedAt: published ?? .now, addedAt: .now,
            codec: (path as NSString).pathExtension.uppercased(), isLossless: false, isDSD: false, sampleRate: 0, bitDepth: nil,
            channels: 2, duration: duration, bitrate: nil,
            cueStartFrame: nil, cueFrameLength: nil,
            title: title,
            artist: author ?? show, album: show, albumArtist: author ?? show,
            composer: nil, genre: "Podcast",
            releaseDate: nil, year: nil,
            trackNumber: nil, trackTotal: nil,
            discNumber: nil, discTotal: nil,
            compilation: false, grouping: nil, comment: nil, lyrics: nil, bpm: nil, rating: nil,
            isrc: nil, label: nil,
            musicBrainzReleaseID: nil, musicBrainzRecordingID: nil,
            titleSort: nil, artistSort: nil, albumSort: nil, albumArtistSort: nil,
            extraTags: [:],
            rgTrackGain: nil, rgTrackPeak: nil, rgAlbumGain: nil, rgAlbumPeak: nil,
            artworkKey: nil, playCount: 0, lastPlayedAt: nil, isMissing: false,
            effectiveBitDepth: nil, bandwidthHz: nil, analysisVerdict: nil)
    }
}

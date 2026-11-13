//
//  PlaybackState.swift
//  DynamicNotch
//
//  A snapshot of what is playing, as reported by a music source.
//

import Foundation

enum RepeatMode: Int, Codable {
    case off = 1
    case one = 2
    case all = 3
}

struct PlaybackState {
    var bundleIdentifier: String
    var isPlaying: Bool = false
    var title: String = "I'm Handsome"
    var artist: String = "Me"
    var album: String = "Self Love"
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackRate: Double = 1
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var lastUpdated: Date = Date.distantPast
    var artwork: Data?
    var volume: Double = 0.5
    var isFavorite: Bool = false
}

extension PlaybackState: Equatable {
    static func == (lhs: PlaybackState, rhs: PlaybackState) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.isPlaying == rhs.isPlaying
            && lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.currentTime == rhs.currentTime
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.artwork == rhs.artwork
            && lhs.isFavorite == rhs.isFavorite
    }
}

import os

/// Where each song's cover comes from and where it goes: `log show --predicate
/// 'subsystem == "io.bauerhaus.boringnotch" && category == "artwork"'`.
enum ArtworkLog {
    static let log = os.Logger.app("artwork")

    /// A short fingerprint of a cover, to tell covers apart in the log.
    static func id(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "none" }
        var hash: UInt64 = 1469598103934665603
        for byte in data.prefix(4096) { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash ^ UInt64(data.count), radix: 16).suffix(8) + "/\(data.count)"
    }
}

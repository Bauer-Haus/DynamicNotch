//
//  AlbumLibrary.swift
//  DynamicNotch
//
//  The albums in the user's Music library for Album Flow: read with the iTunesLibrary
//  framework, grouped and sorted like iTunes' album browser, with their covers loaded on
//  demand. Playing an album goes through Music's scripting interface.
//

import AppKit
import ImageIO
import iTunesLibrary
import os

struct LibraryTrack: Equatable, Sendable {
    let persistentID: UInt64
    let title: String
    let artist: String
    let disc: Int
    let number: Int
    /// Seconds.
    let duration: TimeInterval
}

struct LibraryAlbum: Identifiable, Equatable, Sendable {
    let id: UInt64
    let title: String
    let artist: String
    let year: Int
    /// In disc and track order.
    let tracks: [LibraryTrack]
}

/// One song as the grouping sees it, so grouping and sorting can be tested without a library.
struct LibrarySong: Sendable {
    var persistentID: UInt64
    var title: String
    var artist: String
    var albumArtist: String?
    var albumTitle: String
    var albumID: UInt64
    var isCompilation = false
    var disc = 1
    var number = 0
    var duration: TimeInterval = 0
    var year = 0
}

enum AlbumGrouping {
    /// Songs grouped into albums, sorted by album artist ("The" and "A" ignored, as Music
    /// does), then year, then title; tracks in disc and track order.
    static func albums(from songs: [LibrarySong]) -> [LibraryAlbum] {
        var groups: [String: [LibrarySong]] = [:]
        var order: [String] = []
        for song in songs {
            let key = song.albumID != 0
                ? "id:\(song.albumID)"
                : "name:\(song.albumTitle.lowercased())|\((song.albumArtist ?? song.artist).lowercased())"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(song)
        }
        let albums: [LibraryAlbum] = order.compactMap { key in
            guard let songs = groups[key], let first = songs.first else { return nil }
            let tracks = songs
                .sorted { ($0.disc, $0.number, $0.title) < ($1.disc, $1.number, $1.title) }
                .map { LibraryTrack(persistentID: $0.persistentID, title: $0.title, artist: $0.artist,
                                    disc: $0.disc, number: $0.number, duration: $0.duration) }
            return LibraryAlbum(
                id: first.albumID != 0 ? first.albumID : stableID(key),
                title: first.albumTitle.isEmpty ? "Unknown Album" : first.albumTitle,
                artist: albumArtist(of: songs),
                year: songs.map(\.year).max() ?? 0,
                tracks: tracks)
        }
        return albums.sorted { a, b in
            let artist = sortName(a.artist).localizedStandardCompare(sortName(b.artist))
            if artist != .orderedSame { return artist == .orderedAscending }
            if a.year != b.year { return a.year < b.year }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The album artist if set; "Various Artists" for a compilation; otherwise the artist
    /// most of its songs are by.
    static func albumArtist(of songs: [LibrarySong]) -> String {
        if let set = songs.lazy.compactMap(\.albumArtist).first(where: { !$0.isEmpty }) { return set }
        if songs.contains(where: \.isCompilation) { return "Various Artists" }
        var counts: [String: Int] = [:]
        for song in songs where !song.artist.isEmpty { counts[song.artist, default: 0] += 1 }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? "Unknown Artist"
    }

    /// How a name sorts: without a leading "The ", "A " or "An ".
    static func sortName(_ name: String) -> String {
        for article in ["the ", "a ", "an "] where name.lowercased().hasPrefix(article) && name.count > article.count {
            return String(name.dropFirst(article.count))
        }
        return name
    }

    /// FNV-1a, so an album without a library ID keeps the same ID between launches.
    private static func stableID(_ key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash | 1
    }
}

/// Reads the Music library and the covers. Everything touching iTunesLibrary runs on one
/// queue: its objects aren't thread-safe.
final class AlbumLibrary: @unchecked Sendable {
    static let shared = AlbumLibrary()
    private static let log = os.Logger.app("albumFlow")
    /// The playlist albums are played from, so Music plays them in order.
    static let playlistName = "Album Flow"

    enum LoadError: Error {
        /// macOS hasn't given access to the library (Privacy & Security > Media & Apple Music).
        case noAccess
    }

    private let queue = DispatchQueue(label: "DynamicNotch.albumLibrary", qos: .userInitiated)
    // Queue only.
    private var library: ITLibrary?
    /// Each album's songs that have a cover, for loading it.
    private var artworkSongs: [UInt64: [ITLibMediaItem]] = [:]

    private init() {}

    /// Every album in the library (re-read each time, so it's current).
    func load() async throws -> [LibraryAlbum] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.readLibrary())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readLibrary() throws -> [LibraryAlbum] {
        let library: ITLibrary
        if let existing = self.library, existing.reloadData() {
            library = existing
        } else {
            do {
                library = try ITLibrary(apiVersion: "1.1")
            } catch {
                Self.log.error("Music library unavailable: \(error.localizedDescription, privacy: .public)")
                throw LoadError.noAccess
            }
            self.library = library
        }
        var songs: [LibrarySong] = []
        var artwork: [UInt64: [ITLibMediaItem]] = [:]
        for item in library.allMediaItems where item.mediaKind == .kindSong && !item.isVideo {
            let album = item.album
            let albumID = album.persistentID.uint64Value
            songs.append(LibrarySong(
                persistentID: item.persistentID.uint64Value,
                title: item.title,
                artist: item.artist?.name ?? "",
                albumArtist: album.albumArtist,
                albumTitle: album.title ?? "",
                albumID: albumID,
                isCompilation: album.isCompilation,
                disc: max(1, album.discNumber),
                number: item.trackNumber,
                duration: TimeInterval(item.totalTime) / 1000,
                year: item.year))
            if item.hasArtworkAvailable, albumID != 0 { artwork[albumID, default: []].append(item) }
        }
        artworkSongs = artwork
        // macOS hands an app without access an empty library rather than an error.
        if songs.isEmpty, library.allMediaItems.isEmpty, library.allPlaylists.isEmpty { throw LoadError.noAccess }
        let albums = AlbumGrouping.albums(from: songs)
        Self.log.notice("Album Flow: \(albums.count, privacy: .public) albums from \(songs.count, privacy: .public) songs")
        return albums
    }

    /// The album's cover, at most `maxPixels` on its longer side, in sRGB. From the library's
    /// own artwork, or (for songs whose cover only Music has, such as Apple Music downloads)
    /// from Music if it's running.
    func cover(for album: LibraryAlbum, maxPixels: Int) async -> CGImage? {
        let fromLibrary: CGImage? = await withCheckedContinuation { continuation in
            queue.async {
                var image: CGImage?
                for item in self.artworkSongs[album.id] ?? [] {
                    if let artwork = item.artwork, let cg = Self.thumbnail(of: artwork, maxPixels: maxPixels) {
                        image = cg
                        break
                    }
                }
                continuation.resume(returning: image)
            }
        }
        if let fromLibrary { return fromLibrary }
        guard let track = album.tracks.first, PlayerScript.isRunning(PlayerScript.musicBundleID) else { return nil }
        let script = """
        tell application "Music"
            try
                return data of artwork 1 of (first track of library playlist 1 whose persistent ID is "\(Self.hex(track.persistentID))")
            on error
                return ""
            end try
        end tell
        """
        guard let descriptor = try? await AppleScriptHelper.execute(script, timeout: 5),
              descriptor.descriptorType != typeUnicodeText
        else { return nil }
        let data = descriptor.data
        return data.isEmpty ? nil : Self.thumbnail(of: data, maxPixels: maxPixels)
    }

    private static func thumbnail(of artwork: ITLibArtwork, maxPixels: Int) -> CGImage? {
        if let data = artwork.imageData, let image = thumbnail(of: data, maxPixels: maxPixels) { return image }
        guard let image = artwork.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return sRGB(image, maxPixels: maxPixels)
    }

    static func thumbnail(of data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return sRGB(image, maxPixels: maxPixels)
    }

    /// Redrawn square (filling, like Music's grid) and in sRGB, so print-made CMYK covers
    /// show their real colours.
    static func sRGB(_ image: CGImage, maxPixels: Int) -> CGImage? {
        let side = max(1, min(maxPixels, max(image.width, image.height)))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        let scale = CGFloat(side) / CGFloat(min(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// Music's form of a persistent ID: 16 hex digits.
    static func hex(_ id: UInt64) -> String { String(format: "%016llX", id) }

    /// Plays the album in Music from `trackIndex`, in order. Music has no "play this album"
    /// command, so the album is put in a playlist of its own and that is played.
    func play(_ album: LibraryAlbum, from trackIndex: Int = 0) {
        guard !album.tracks.isEmpty else { return }
        let ids = album.tracks.map { "\"\(Self.hex($0.persistentID))\"" }.joined(separator: ", ")
        let start = min(max(0, trackIndex), album.tracks.count - 1) + 1
        let script = """
        tell application "Music"
            if not (exists user playlist "\(Self.playlistName)") then
                make new user playlist with properties {name:"\(Self.playlistName)"}
            end if
            set pl to user playlist "\(Self.playlistName)"
            delete tracks of pl
            repeat with pid in {\(ids)}
                try
                    duplicate (first track of library playlist 1 whose persistent ID is (pid as text)) to pl
                end try
            end repeat
            if (count of tracks of pl) ≥ \(start) then
                play track \(start) of pl
            else if (count of tracks of pl) > 0 then
                play track 1 of pl
            end if
        end tell
        """
        Task {
            do {
                try await AppleScriptHelper.execute(script, timeout: 30)
            } catch {
                Self.log.error("Album Flow could not play \(album.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

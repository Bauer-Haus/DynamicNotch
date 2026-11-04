//
//  CatalogArtwork.swift
//  DynamicNotch
//
//  A song's cover from Apple's public iTunes Search, for Music songs that come with none.
//

import Foundation

/// Music sometimes plays a song (seen with Apple-made playlists) without giving its cover to
/// Now Playing or to its scripting interface. Apple's catalog still has it: this looks the
/// song up by title and artist and only takes an exact match.
enum CatalogArtwork {
    /// Big enough for the open player's cover on a Retina screen.
    static let pixelSize = 600

    static func searchURL(title: String, artist: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            .init(name: "term", value: "\(artist) \(title)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "10"),
        ]
        return components?.url
    }

    /// The cover's URL from a search result: the same title and artist (ignoring case),
    /// preferring the same album, at `pixelSize`.
    static func artworkURL(fromSearchJSON data: Data, title: String, artist: String, album: String) -> URL? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else { return nil }
        func same(_ a: Any?, _ b: String) -> Bool {
            (a as? String)?.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let matches = results.filter { same($0["trackName"], title) && same($0["artistName"], artist) }
        guard let best = matches.first(where: { same($0["collectionName"], album) }) ?? matches.first,
              let small = best["artworkUrl100"] as? String
        else { return nil }
        let size = "\(pixelSize)x\(pixelSize)bb"
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: size))
    }

    static func fetch(title: String, artist: String, album: String) async -> Data? {
        guard !title.isEmpty, !artist.isEmpty,
              let url = searchURL(title: title, artist: artist),
              let json = try? await ImageService.shared.fetchImageData(from: url),
              let artURL = artworkURL(fromSearchJSON: json, title: title, artist: artist, album: album),
              let art = try? await ImageService.shared.fetchImageData(from: artURL),
              !art.isEmpty
        else { return nil }
        return art
    }
}

//
//  StationArtworkTests.swift
//  DynamicNotch
//
//  Apple Music stations have no artwork in Music's scripting interface, so the Apple Music
//  source takes it from the Now Playing helper's `get` output.
//

import AppKit
import Foundation
import Testing
@testable import DynamicNotch

@Suite("Station artwork")
struct StationArtworkTests {
    private let cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])   // stand-in JPEG bytes

    private func reply(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields)
    }

    @Test func acceptsMusicArtworkForTheCurrentSong() throws {
        let data = try reply([
            "bundleIdentifier": "com.apple.Music", "title": "Wonderful Tonight",
            "artworkData": cover.base64EncodedString(),
        ])
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: data, title: "Wonderful Tonight") == cover)
    }

    @Test func rejectsArtworkForAnotherSong() throws {
        // The cover lands a moment after the title; never show the previous song's.
        let data = try reply([
            "bundleIdentifier": "com.apple.Music", "title": "Take It Easy",
            "artworkData": cover.base64EncodedString(),
        ])
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: data, title: "The Scientist") == nil)
    }

    @Test func rejectsOtherApps() throws {
        let data = try reply([
            "bundleIdentifier": "com.spotify.client", "title": "Wonderful Tonight",
            "artworkData": cover.base64EncodedString(),
        ])
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: data, title: "Wonderful Tonight") == nil)
    }

    @Test func noArtworkYetGivesNil() throws {
        let data = try reply(["bundleIdentifier": "com.apple.Music", "title": "The Scientist"])
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: data, title: "The Scientist") == nil)
    }

    @Test(arguments: ["", "null", "not json", "{\"artworkData\":\"%%%\"}"])
    func badRepliesGiveNil(body: String) {
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: Data(body.utf8), title: "x") == nil)
    }

    @Test func emptyArtworkGivesNil() throws {
        let data = try reply(["bundleIdentifier": "com.apple.Music", "title": "x", "artworkData": ""])
        #expect(AppleMusicController.artwork(fromNowPlayingJSON: data, title: "x") == nil)
    }

    @Test func keepsLookingForAboutEightSeconds() {
        let delays = AppleMusicController.artworkRetryDelays
        #expect(delays.first! <= 0.5, "the cover usually lands within half a second")
        #expect(delays.reduce(0, +) >= 5 && delays.reduce(0, +) <= 10)
        #expect(delays == delays.sorted(), "waits grow, never shrink")
    }

    @Test func keepsLookingLongerOnAStation() {
        // A station song's cover reached Now Playing more than 12 s after its title.
        let delays = AppleMusicController.stationArtworkRetryDelays
        #expect(delays.reduce(0, +) >= 25 && delays.reduce(0, +) <= 40)
        #expect(delays == delays.sorted(), "waits grow, never shrink")
        #expect(AppleMusicController.catalogAfterTries < delays.count)
    }

    @Test func nowPlayingWaitsBrieflyBeforeShowingTheAppIcon() {
        #expect(MusicManager.artworkWait >= 0.5 && MusicManager.artworkWait <= 3)
    }
}

@Suite("Music artwork when Now Playing has none")
struct NowPlayingArtworkFallbackTests {
    private func result(name: String, art: Data?) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(string: name), at: 1)
        if let art {
            list.insert(NSAppleEventDescriptor(descriptorType: typeData, data: art)!, at: 2)
        } else {
            list.insert(NSAppleEventDescriptor(string: ""), at: 2)
        }
        return list
    }

    private let cover = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    @Test func takesMusicsArtForTheSameSong() {
        #expect(AppleMusicController.artwork(fromScriptResult: result(name: "Been By Now", art: cover), title: "Been By Now") == cover)
    }

    @Test func refusesArtForADifferentSong() {
        #expect(AppleMusicController.artwork(fromScriptResult: result(name: "Last Night", art: cover), title: "Been By Now") == nil)
    }

    @Test func refusesASongWithNoArt() {
        #expect(AppleMusicController.artwork(fromScriptResult: result(name: "Been By Now", art: nil), title: "Been By Now") == nil)
    }

    @Test func onlyAsksMusicAndOnlyWhenArtIsMissing() {
        var state = PlaybackState(bundleIdentifier: "com.apple.Music")
        state.title = "Been By Now"
        #expect(NowPlayingController.needsArtworkFallback(state, artworkArrived: false))
        #expect(!NowPlayingController.needsArtworkFallback(state, artworkArrived: true))

        state.bundleIdentifier = "com.spotify.client"
        #expect(!NowPlayingController.needsArtworkFallback(state, artworkArrived: false))

        state.bundleIdentifier = "com.apple.Music"
        state.title = ""
        #expect(!NowPlayingController.needsArtworkFallback(state, artworkArrived: false))
    }

    @Test func aNewSongIsANewTrack() {
        var a = PlaybackState(bundleIdentifier: "com.apple.Music")
        a.title = "Been By Now"; a.artist = "Morgan Wallen"; a.album = "Been By Now - Single"
        var b = a
        #expect(NowPlayingController.trackKey(a) == NowPlayingController.trackKey(b))
        b.title = "Last Night"
        #expect(NowPlayingController.trackKey(a) != NowPlayingController.trackKey(b))
    }
}

@Suite("Cover from Apple's catalog")
struct CatalogArtworkTests {
    private func json(_ results: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": results])
    }

    private let small = "https://is1-ssl.mzstatic.com/image/thumb/x/cover.jpg/100x100bb.jpg"

    @Test func takesTheExactSongAtFullSize() {
        let data = json([["trackName": "Been By Now", "artistName": "Morgan Wallen",
                          "collectionName": "Been By Now - Single", "artworkUrl100": small]])
        let url = CatalogArtwork.artworkURL(fromSearchJSON: data, title: "Been By Now",
                                            artist: "Morgan Wallen", album: "Been By Now - Single")
        #expect(url?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/cover.jpg/600x600bb.jpg")
    }

    /// The same title by someone else is a different song.
    @Test func refusesAnotherArtistsSong() {
        let data = json([["trackName": "BEEN BY NOW", "artistName": "Country Night & Jaxon Wayne",
                          "collectionName": "BEEN BY NOW - Single", "artworkUrl100": small]])
        #expect(CatalogArtwork.artworkURL(fromSearchJSON: data, title: "Been By Now",
                                          artist: "Morgan Wallen", album: "") == nil)
    }

    @Test func prefersTheSameAlbum() {
        let single = "https://x/single/100x100bb.jpg", album = "https://x/album/100x100bb.jpg"
        let data = json([
            ["trackName": "Song", "artistName": "A", "collectionName": "Song - Single", "artworkUrl100": single],
            ["trackName": "Song", "artistName": "A", "collectionName": "The Album", "artworkUrl100": album],
        ])
        let url = CatalogArtwork.artworkURL(fromSearchJSON: data, title: "Song", artist: "A", album: "The Album")
        #expect(url?.absoluteString == "https://x/album/600x600bb.jpg")
    }

    @Test func ignoresCaseAndAccents() {
        let data = json([["trackName": "beyoncé song", "artistName": "BEYONCE", "artworkUrl100": small]])
        #expect(CatalogArtwork.artworkURL(fromSearchJSON: data, title: "Beyonce Song", artist: "Beyoncé", album: "") != nil)
    }

    @Test func handlesNoResultsAndJunk() {
        #expect(CatalogArtwork.artworkURL(fromSearchJSON: json([]), title: "x", artist: "y", album: "") == nil)
        #expect(CatalogArtwork.artworkURL(fromSearchJSON: Data("nope".utf8), title: "x", artist: "y", album: "") == nil)
    }

    @Test func searchesForArtistAndTitle() {
        let url = CatalogArtwork.searchURL(title: "Been By Now", artist: "Morgan Wallen")
        #expect(url?.host == "itunes.apple.com")
        #expect(url?.query?.contains("term=Morgan%20Wallen%20Been%20By%20Now") == true)
    }
}

@Suite("Apple Music source: the right cover for each song")
struct AppleMusicCoverTests {
    private let old = Data([1, 2, 3]), new = Data([4, 5, 6])

    @Test func takesADifferentCover() {
        #expect(AppleMusicController.accepts(new, previous: old, sameAlbum: false))
    }

    /// The bug: Music still had the last song's cover, and it stayed on a new album's song.
    @Test func refusesTheLastSongsCoverOnAnotherAlbum() {
        #expect(!AppleMusicController.accepts(old, previous: old, sameAlbum: false))
    }

    @Test func keepsTheCoverForTheAlbumsNextSong() {
        #expect(AppleMusicController.accepts(old, previous: old, sameAlbum: true))
    }

    @Test func sameAlbumNeedsARealAlbumName() {
        #expect(AppleMusicController.isSameAlbum("Cloud 9", "Cloud 9"))
        #expect(!AppleMusicController.isSameAlbum("Cloud 9", "The Way I Am"))
        #expect(!AppleMusicController.isSameAlbum("", ""))
        #expect(!AppleMusicController.isSameAlbum("Unknown", "Unknown"))
    }

    @Test func asksTheCatalogBeforeGivingUp() {
        #expect(AppleMusicController.catalogAfterTries >= 1)
        #expect(AppleMusicController.catalogAfterTries < AppleMusicController.artworkRetryDelays.count)
    }
}

//
//  StationArtworkTests.swift
//  DynamicNotch
//
//  Apple Music stations have no artwork in Music's scripting interface, so the Apple Music
//  source takes it from the Now Playing helper's `get` output.
//

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

    @Test func nowPlayingWaitsBrieflyBeforeShowingTheAppIcon() {
        #expect(MusicManager.artworkWait >= 0.5 && MusicManager.artworkWait <= 3)
    }
}

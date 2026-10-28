//
//  PlayerScriptTests.swift
//  DynamicNotch
//
//  Every script the app sends to Music and Spotify must compile; a copy of the favourite
//  script once contained Swift code instead of true/false and silently never worked.
//

import Foundation
import Testing
@testable import DynamicNotch

@Suite("Player scripts")
struct PlayerScriptTests {
    private func compiles(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: AppleScriptHelper.withTimeout(source, seconds: 10)) else { return false }
        return script.compileAndReturnError(&error) && error == nil
    }

    @Test(arguments: ["Music", "Spotify"])
    func volumeScriptsCompile(app: String) {
        #expect(compiles(PlayerScript.setVolume(0.5, app: app)))
        #expect(compiles(PlayerScript.getVolume(app: app)))
    }

    @Test(arguments: [true, false])
    func favouriteScriptsCompile(favorite: Bool) {
        let script = PlayerScript.setMusicFavorite(favorite)
        #expect(compiles(script))
        #expect(script.contains("to \(favorite)"), "sends a real true/false")
        #expect(compiles(PlayerScript.getMusicFavorite))
    }

    @Test func volumeIsWholePercentWithoutRounding() {
        #expect(PlayerScript.volumePercent(0.457) == 45)
        #expect(PlayerScript.volumePercent(0) == 0)
        #expect(PlayerScript.volumePercent(1) == 100)
        #expect(PlayerScript.volumePercent(-3) == 0)
        #expect(PlayerScript.volumePercent(7) == 100)
        #expect(PlayerScript.setVolume(0.457, app: "Music") == "tell application \"Music\" to set sound volume to 45")
    }

    @Test func onlyMusicAndSpotifyHaveScriptableVolume() {
        #expect(PlayerScript.appName(forVolumeOf: PlayerScript.musicBundleID) == "Music")
        #expect(PlayerScript.appName(forVolumeOf: PlayerScript.spotifyBundleID) == "Spotify")
        #expect(PlayerScript.appName(forVolumeOf: "com.google.Chrome") == nil)
        #expect(PlayerScript.appName(forVolumeOf: "") == nil)
    }
}

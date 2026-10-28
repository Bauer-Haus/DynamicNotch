//
//  AppBehaviourTests.swift
//  boringNotchTests
//
//  Full-screen hiding, the safeguards (AppleScript timeouts, helper restarts) and the
//  values stored in the user's settings.
//

import Foundation
import Testing
@testable import Boring_Notch

@Suite("Full-screen hiding")
struct FullscreenHidingTests {
    @Test func alwaysHides() {
        #expect(FullscreenMediaDetector.shouldHide(option: .always, fullscreenApps: ["com.apple.Safari"], musicSource: nil))
    }

    @Test func neverHides() {
        #expect(!FullscreenMediaDetector.shouldHide(option: .never, fullscreenApps: ["com.apple.Music"], musicSource: "com.apple.Music"))
    }

    @Test func mediaAppOnlyHidesForThePlayingApp() {
        #expect(FullscreenMediaDetector.shouldHide(
            option: .nowPlayingOnly, fullscreenApps: ["com.google.Chrome"], musicSource: "com.google.Chrome"))
        #expect(!FullscreenMediaDetector.shouldHide(
            option: .nowPlayingOnly, fullscreenApps: ["com.apple.Safari"], musicSource: "com.google.Chrome"))
    }

    @Test func mediaAppOnlyDoesNotHideWhenNothingPlays() {
        #expect(!FullscreenMediaDetector.shouldHide(option: .nowPlayingOnly, fullscreenApps: ["com.apple.Safari"], musicSource: nil))
    }
}

@Suite("AppleScript safeguards", .serialized)
struct AppleScriptTests {
    @Test func wrapsScriptsInATimeout() {
        let wrapped = AppleScriptHelper.withTimeout("tell application \"Music\" to play", seconds: 7)
        #expect(wrapped == "with timeout of 7 seconds\ntell application \"Music\" to play\nend timeout")
    }

    @Test func runsAScript() async throws {
        let result = try await AppleScriptHelper.execute("return 2 + 3")
        #expect(result?.int32Value == 5)
    }

    @Test func reportsScriptErrors() async {
        await #expect(throws: (any Error).self) {
            try await AppleScriptHelper.execute("error \"boom\"")
        }
    }

    @Test func reportsCompileErrors() async {
        await #expect(throws: (any Error).self) {
            try await AppleScriptHelper.execute("this is not applescript (")
        }
    }

    @Test func resumeOnceLetsOnlyTheFirstCallerThrough() {
        let once = ResumeOnce()
        #expect(once.claim())
        #expect(!once.claim())
        #expect(!once.claim())
    }

    /// Last in this serialized suite: the stuck script keeps the shared queue busy.
    @Test(.timeLimit(.minutes(1)))
    func callerIsReleasedWhenAScriptHangs() async {
        let start = Date()
        await #expect(throws: (any Error).self) {
            try await AppleScriptHelper.execute("delay 6\nreturn 1", timeout: 1)
        }
        // Released by the backstop (timeout + 2 s), not after the full 6 s delay.
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite("Now Playing helper restarts")
struct HelperRestartTests {
    @Test func backsOffWhileTheHelperKeepsFailing() {
        var delay = 0.5
        var delays: [Double] = []
        for _ in 0 ..< 8 {
            delay = NowPlayingController.nextRestartDelay(after: delay, ranFor: 0.2)
            delays.append(delay)
        }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
    }

    @Test func restartsQuicklyAfterAHealthyRun() {
        #expect(NowPlayingController.nextRestartDelay(after: 30, ranFor: 3600) == 1)
    }
}

@Suite("Stored settings")
struct StoredSettingsTests {
    /// These raw values are saved in the user's preferences; renaming one would reset it.
    @Test func hideNotchOptionValuesAreStable() {
        #expect(HideNotchOption.always.rawValue == "always")
        #expect(HideNotchOption.nowPlayingOnly.rawValue == "nowPlayingOnly")
        #expect(HideNotchOption.never.rawValue == "never")
    }

    @Test func mediaSourceValuesAreStable() {
        #expect(MediaControllerType.allCases.map(\.rawValue) == ["Now Playing", "Apple Music", "Spotify"])
    }

    @Test func removedYouTubeMusicSettingIsIgnored() {
        // Someone who had picked YouTube Music falls back to the default source.
        #expect(MediaControllerType(rawValue: "YouTube Music") == nil)
    }

    @Test func everyMediaSourceHasADescription() {
        for source in MediaControllerType.allCases {
            #expect(!source.description.isEmpty)
        }
    }
}

@Suite("Open island halo")
@MainActor
struct IslandHaloTests {
    @Test func blurFadesOutwardsAndEndsAtTheWindowEdge() {
        let samples = stride(from: 0, through: islandHaloMargin, by: 2).map { IslandBackdrop.strength(atDistance: $0) }
        #expect(samples.first == 0.7)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
        #expect(IslandBackdrop.strength(atDistance: islandHaloMargin + 1) == 0)
    }

    @Test func distanceIsMeasuredFromTheOpenIsland() {
        let centreX = windowSize.width / 2
        #expect(IslandBackdrop.distanceToIsland(CGPoint(x: centreX, y: 50)) == 0)
        #expect(abs(IslandBackdrop.distanceToIsland(CGPoint(x: centreX, y: openNotchSize.height + 30)) - 30) < 0.001)
        #expect(abs(IslandBackdrop.distanceToIsland(CGPoint(x: centreX + openNotchSize.width / 2 + 20, y: 10)) - 20) < 0.001)
    }

    @Test func windowLeavesRoomForTheHalo() {
        #expect(windowSize.width == openNotchSize.width + 2 * islandHaloMargin)
        #expect(windowSize.height == openNotchSize.height + islandHaloMargin)
    }
}

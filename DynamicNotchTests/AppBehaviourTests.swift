//
//  AppBehaviourTests.swift
//  boringNotchTests
//
//  Full-screen hiding, the safeguards (AppleScript timeouts, helper restarts) and the
//  values stored in the user's settings.
//

import Foundation
import Testing
@testable import DynamicNotch

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

@Suite("Open island shadow")
struct IslandShadowTests {
    @Test func windowLeavesRoomForTheShadow() {
        #expect(windowSize.width == openNotchSize.width + 2 * islandShadowMargin)
        #expect(windowSize.height == openNotchSize.height + islandShadowMargin)
    }
}

@Suite("Closing notch bottom edge")
struct ClosingBottomTests {
    private let travel = NotchShape.BottomTravel(from: 218, to: 32, start: 3)

    @Test func followsTheFrameWithoutATrip() {
        #expect(NotchShape.bottomLimit(nil, progress: 3.5) == nil)
    }

    @Test func movesFromOpenToClosedOverOneTrip() {
        #expect(NotchShape.bottomLimit(travel, progress: 3) == 218)
        #expect(NotchShape.bottomLimit(travel, progress: 3.5) == 125)
        #expect(NotchShape.bottomLimit(travel, progress: 4) == 32)
    }

    /// Held at the closed height until cleared, so it never drops back to a frame still landing.
    @Test func staysAtTheClosedHeightAfterTheTrip() {
        #expect(NotchShape.bottomLimit(travel, progress: 4) == 32)
        #expect(NotchShape.bottomLimit(travel, progress: 2) == 218)
    }
}

@Suite("Bottom screen corners")
@MainActor
struct ScreenCornerTests {
    /// How far in from the side edge the black reaches, `height` pt above the bottom edge.
    private func blackWidth(atHeight height: CGFloat, corner: ScreenCornerMasks.Corner) -> CGFloat {
        let bounds = CGRect(x: 0, y: 0, width: 29, height: 29)
        let path = ScreenCornerMasks.maskPath(in: bounds, corner: corner, radius: 18)
        var x: CGFloat = 0
        while x < 29 {
            let point = CGPoint(x: corner == .bottomLeft ? x : 29 - x, y: height)
            if !path.contains(point, using: .evenOdd) { break }
            x += 0.01
        }
        return x
    }

    /// The photo of the top corner: 12.55, 6.61, 2.04 and 0.61 pt in, at 1, 4, 10 and 14 pt.
    @Test(arguments: [ScreenCornerMasks.Corner.bottomLeft, .bottomRight])
    func matchesTheMeasuredTopCorner(corner: ScreenCornerMasks.Corner) {
        for (height, measured) in [(1.0, 12.55), (4.0, 6.61), (10.0, 2.04), (14.0, 0.61)] {
            #expect(abs(blackWidth(atHeight: height, corner: corner) - measured) < 0.35)
        }
    }

    @Test func leavesTheRestOfTheScreenAlone() {
        let path = ScreenCornerMasks.maskPath(in: CGRect(x: 0, y: 0, width: 29, height: 29), corner: .bottomLeft, radius: 18)
        #expect(!path.contains(CGPoint(x: 20, y: 20), using: .evenOdd))
        #expect(!path.contains(CGPoint(x: 28, y: 0.5), using: .evenOdd))
    }

    @Test func eighteenPointsAtTheFourteenInchDefault() {
        // 3.6 mm on a 302.4 mm wide panel shown as 1512 pt.
        #expect(abs(ScreenCornerMasks.cornerRadiusMillimetres * 1512 / 302.4 - 18) < 0.01)
    }
}

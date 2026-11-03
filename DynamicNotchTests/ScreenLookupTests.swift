//
//  ScreenLookupTests.swift
//  DynamicNotch
//
//  Screens are found by UUID from what's connected now, and a display that has gone (an
//  NSScreen kept from before waking from sleep) is treated as gone rather than queried.
//

import AppKit
import CoreGraphics
import Testing
@testable import DynamicNotch

@Suite("Screen lookup")
@MainActor
struct ScreenLookupTests {
    @Test func everyConnectedScreenIsFoundByItsUUID() throws {
        let screens = NSScreen.screens
        try #require(!screens.isEmpty, "needs a display")
        for screen in screens {
            let uuid = try #require(screen.displayUUID)
            #expect(NSScreen.screen(withUUID: uuid) === screen)
            #expect(NSScreen.screensByUUID[uuid] === screen)
        }
    }

    @Test func connectedScreensAreOnline() {
        let online = Set(NSScreen.onlineDisplayIDs())
        for screen in NSScreen.screens {
            #expect(screen.onlineDisplayID.map(online.contains) == true)
        }
    }

    @Test func unknownUUIDFindsNoScreen() {
        #expect(NSScreen.screen(withUUID: "00000000-0000-0000-0000-000000000000") == nil)
        #expect(notchScreen("not-a-screen") == nil)
    }

    @Test func screenKeptFromBeforeSleepIsTreatedAsGone() {
        // Waking gave the built-in display a new ID (seen in the logs: 5, 6, ... 9). A screen
        // object still holding the old ID must not be looked up.
        #expect(NSScreen.onlineDisplayID(screenNumber: 5, online: [1, 6]) == nil)
        #expect(NSScreen.onlineDisplayID(screenNumber: 6, online: [1, 6]) == 6)
        #expect(NSScreen.onlineDisplayID(screenNumber: nil, online: [1]) == nil)
        #expect(NSScreen.onlineDisplayID(screenNumber: 1, online: []) == nil)
        #expect(NSScreen.displayUUID(for: nil) == nil)
    }
}

@Suite("Screen layout changes")
struct ScreenLayoutTests {
    typealias S = ScreenLayout.Screen
    static let builtIn = S(uuid: "A", x: 0, y: 0, width: 1512, height: 982)

    @Test func sameLayoutIsUnchanged() {
        #expect(ScreenLayout([Self.builtIn]) == ScreenLayout([Self.builtIn]))
    }

    @Test func resolutionChangeIsAChange() {
        let scaled = S(uuid: "A", x: 0, y: 0, width: 1800, height: 1169)
        #expect(ScreenLayout([Self.builtIn]) != ScreenLayout([scaled]))
    }

    @Test func displayConnectedOrDisconnectedIsAChange() {
        let external = S(uuid: "B", x: 1512, y: 0, width: 2560, height: 1440)
        #expect(ScreenLayout([Self.builtIn]) != ScreenLayout([Self.builtIn, external]))
        #expect(ScreenLayout([Self.builtIn, external]) != ScreenLayout([Self.builtIn]))
    }

    @Test func screenOrderDoesNotMatter() {
        let external = S(uuid: "B", x: 1512, y: 0, width: 2560, height: 1440)
        #expect(ScreenLayout([Self.builtIn, external]) == ScreenLayout([external, Self.builtIn]))
    }

    @Test func firstLayoutAfterLaunchCountsAsChange() {
        let previous: ScreenLayout? = nil
        #expect(ScreenLayout([Self.builtIn]) != previous)
    }

    @MainActor @Test func currentLayoutMatchesConnectedScreens() {
        #expect(ScreenLayout.current.count == NSScreen.screens.count)
        #expect(ScreenLayout.current == ScreenLayout.current)
    }
}

@Suite("Full-screen Space to screen")
struct SpaceDisplayTests {
    @Test func screenUUIDIsUsedAsIs() {
        #expect(FullscreenMediaDetector.screenUUID(forSpaceDisplay: "B", known: ["A", "B"], primary: "A") == "B")
    }

    @Test func sharedMainSpaceMapsToPrimaryScreen() {
        #expect(FullscreenMediaDetector.screenUUID(forSpaceDisplay: "Main", known: ["A", "B"], primary: "A") == "A")
    }

    @Test func noScreensGivesNothing() {
        #expect(FullscreenMediaDetector.screenUUID(forSpaceDisplay: "Main", known: [], primary: nil) == nil)
    }
}

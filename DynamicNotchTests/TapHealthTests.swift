//
//  TapHealthTests.swift
//  DynamicNotch
//
//  Every way the waveform's audio tap can fail, and that each is noticed (and only then).
//

import Foundation
import Testing
@testable import DynamicNotch

@Suite("Audio tap health")
struct TapHealthTests {
    /// A tap started at t=100, tapping process 7, delivering music until `now`.
    static func healthy(now: TimeInterval = 110) -> TapHealth.State {
        TapHealth.State(
            now: now, isRunning: true, startedAt: 100,
            lastCallback: now - 0.01, lastSignal: now - 0.01,
            captureConfirmed: true, silentRebuilds: 0,
            tappedProcesses: [7], currentProcesses: [7])
    }

    @Test func healthyTapIsLeftAlone() {
        #expect(TapHealth.check(Self.healthy()) == nil)
    }

    @Test func missingTapIsBuilt() {
        var s = Self.healthy()
        s.isRunning = false
        #expect(TapHealth.check(s) == .notRunning)
    }

    @Test func outputSwitchSilenceIsRiddenOut() {
        // Switching output silences the music app for ~0.5 s; the tap itself is fine.
        var s = Self.healthy()
        s.lastSignal = s.now - 0.7
        #expect(TapHealth.check(s) == nil)
    }

    @Test func tapBuiltMidSwitchThatNeverDeliversIsRebuiltQuickly() {
        var s = Self.healthy(now: 101)
        s.lastCallback = 0
        s.lastSignal = 0
        #expect(TapHealth.check(s) == nil, "give a new tap a moment")
        s.now = 100 + TapHealth.firstDeliveryTime + 0.1
        #expect(TapHealth.check(s) == .neverDelivered)
    }

    @Test func tapThatStopsDeliveringIsRebuilt() {
        var s = Self.healthy()
        s.lastCallback = s.now - TapHealth.stallTime - 0.1
        #expect(TapHealth.check(s) == .stalled)
        s.lastCallback = s.now - TapHealth.stallTime + 0.1
        #expect(TapHealth.check(s) == nil)
    }

    @Test func tapThatHeardMusicThenOnlyZerosIsRebuilt() {
        // Still delivering buffers, but they went silent: the music moved off the tap.
        var s = Self.healthy()
        s.lastSignal = s.now - 1
        #expect(TapHealth.check(s) == nil, "a short gap between tracks is fine")
        s.lastSignal = s.now - TapHealth.confirmedSilentWaits[0] - 0.1
        #expect(TapHealth.check(s) == .silent)
    }

    @Test func rebuiltTapThatStaysSilentBacksOff() {
        var s = Self.healthy()
        s.startedAt = 100
        s.lastSignal = 0
        s.silentRebuilds = 1
        s.now = 100 + TapHealth.confirmedSilentWaits[1] - 0.1
        #expect(TapHealth.check(s) == nil)
        s.now = 100 + TapHealth.confirmedSilentWaits[1] + 0.1
        s.lastCallback = s.now
        #expect(TapHealth.check(s) == .silent)
        s.silentRebuilds = 99
        s.now = 100 + TapHealth.confirmedSilentWaits.last! - 0.1
        s.lastCallback = s.now
        #expect(TapHealth.check(s) == nil, "back-off is capped, not exceeded")
    }

    // MARK: Before capture is known to work (permission dialog may be up).

    @Test func waitsForPermissionDialogBeforeCaptureIsConfirmed() {
        var s = Self.healthy(now: 110)
        s.captureConfirmed = false
        s.lastCallback = 0
        s.lastSignal = 0
        #expect(TapHealth.check(s) == nil, "don't queue another permission request")
        s.now = 100 + TapHealth.permissionWaitTime + 0.1
        #expect(TapHealth.check(s) == .neverDelivered)
    }

    @Test func deniedPermissionSilenceBacksOffSlowly() {
        var s = Self.healthy()
        s.captureConfirmed = false
        s.lastSignal = 0
        s.now = 100 + TapHealth.silentWaits[0] - 0.1
        s.lastCallback = s.now
        #expect(TapHealth.check(s) == nil)
        s.now = 100 + TapHealth.silentWaits[0] + 0.1
        s.lastCallback = s.now
        #expect(TapHealth.check(s) == .silent)
    }

    // MARK: The music app's processes.

    @Test func musicAppAudioMovingToNewProcessRebuilds() {
        var s = Self.healthy()
        s.currentProcesses = [7, 9]
        #expect(TapHealth.check(s) == .processesChanged)
    }

    @Test func musicAppQuittingKeepsLastTap() {
        var s = Self.healthy()
        s.currentProcesses = []
        #expect(TapHealth.check(s) == nil)
    }

    @Test func switchesFromAllOutputToMusicAppWhenItAppears() {
        var s = Self.healthy()
        s.tappedProcesses = []
        s.currentProcesses = [7]
        #expect(TapHealth.check(s) == .betterTarget)
    }

    @Test func tappingAllOutputWithNoTargetIsFine() {
        var s = Self.healthy()
        s.tappedProcesses = []
        s.currentProcesses = []
        #expect(TapHealth.check(s) == nil)
    }

    // MARK: Simulated timelines

    /// A tap broken by an output switch (silent or never delivering again) is rebuilt within
    /// a few seconds, and again if the rebuilt one is broken too.
    @Test(arguments: ["silent", "dead"])
    func brokenTapTimelineRecovers(failure: String) {
        let breakAt: TimeInterval = 200
        var s = Self.healthy(now: breakAt)
        var rebuilds: [TimeInterval] = []
        var t = breakAt
        var brokenTaps = 2   // the original tap and the first rebuild are broken
        while t < breakAt + 15 {
            t += 0.5
            s.now = t
            if let reason = TapHealth.check(s) {
                rebuilds.append(t)
                if reason == .silent { s.silentRebuilds += 1 }
                s.startedAt = t
                s.lastCallback = 0
                s.lastSignal = 0
                brokenTaps -= 1
                continue
            }
            if brokenTaps > 0 {
                if failure == "silent" { s.lastCallback = t }
            } else {
                s.lastCallback = t
                s.lastSignal = t
            }
        }
        #expect(rebuilds.count == 2, "rebuilt once per broken tap, then left alone")
        #expect((rebuilds.last ?? 99) - breakAt <= 6)
    }
}

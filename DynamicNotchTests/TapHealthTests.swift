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
    static let speakers = "BuiltInSpeakerDevice"
    static let airPods = "70-F9-4A-BA-07-C9:output"

    /// A tap started at t=100 on the speakers, tapping process 7, delivering music until `now`.
    static func healthy(now: TimeInterval = 110) -> TapHealth.State {
        TapHealth.State(
            now: now, isRunning: true, startedAt: 100,
            lastCallback: now - 0.01, lastSignal: now - 0.01,
            captureConfirmed: true, silentRebuilds: 0,
            tappedDeviceUID: speakers, currentDeviceUID: speakers, outputStableFor: 60,
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

    // MARK: The AirPods bug: output switches while music keeps playing.

    @Test func outputSwitchRebuildsOnceSettled() {
        var s = Self.healthy()
        s.currentDeviceUID = Self.airPods
        s.outputStableFor = 0.1
        #expect(TapHealth.check(s) == nil, "Bluetooth is still connecting: wait")
        s.outputStableFor = TapHealth.outputSettleTime
        #expect(TapHealth.check(s) == .outputChanged)
    }

    @Test func outputSwitchIsCaughtEvenWithoutNotification() {
        // The change notification never arrived, so outputStableFor is long; the watchdog
        // still sees the tap is clocked by the wrong device.
        var s = Self.healthy()
        s.currentDeviceUID = Self.airPods
        #expect(TapHealth.check(s) == .outputChanged)
    }

    @Test func noOutputDeviceDoesNotLoop() {
        var s = Self.healthy()
        s.currentDeviceUID = nil
        #expect(TapHealth.check(s) == nil)
    }

    @Test func tapBuiltMidSwitchThatNeverDeliversIsRebuiltQuickly() {
        var s = Self.healthy(now: 101)
        s.tappedDeviceUID = Self.airPods
        s.currentDeviceUID = Self.airPods
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

    // MARK: Simulated timeline of the reported bug.

    /// Speakers → AirPods while playing: the watchdog must rebuild within a couple of
    /// seconds whatever the rebuilt tap does (works, never delivers, or delivers silence).
    @Test(arguments: ["works", "never delivers", "silent"])
    func airPodsTimelineRecovers(rebuiltTap: String) {
        let switchAt: TimeInterval = 200
        var s = Self.healthy(now: switchAt)
        var rebuilds: [TimeInterval] = []
        var t = switchAt
        while t < switchAt + 10 {
            t += 0.5
            s.now = t
            s.currentDeviceUID = Self.airPods
            s.outputStableFor = t - switchAt
            // The old tap keeps running but, as in the bug, passes on nothing after the switch.
            if s.tappedDeviceUID == Self.speakers { s.lastCallback = t }
            if let reason = TapHealth.check(s) {
                rebuilds.append(t)
                if reason == .silent { s.silentRebuilds += 1 }
                s.startedAt = t
                s.tappedDeviceUID = Self.airPods
                s.lastCallback = 0
                s.lastSignal = 0
                continue
            }
            if s.tappedDeviceUID == Self.airPods {
                switch rebuiltTap {
                case "works": s.lastCallback = t; s.lastSignal = t
                case "silent": s.lastCallback = t
                default: break
                }
            }
        }
        #expect(rebuilds.first.map { $0 - switchAt } ?? 99 <= 1, "rebuilt for the AirPods within a second")
        if rebuiltTap == "works" {
            #expect(rebuilds.count == 1)
        } else {
            #expect(rebuilds.count >= 2, "a dead or silent rebuilt tap is rebuilt again")
            #expect(rebuilds[1] - rebuilds[0] <= 3)
        }
    }
}

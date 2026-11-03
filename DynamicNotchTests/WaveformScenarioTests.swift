//
//  WaveformScenarioTests.swift
//  DynamicNotch
//
//  The real AudioLevelMonitor driven through everyday events on a simulated Mac: AirPods
//  arriving mid-song, moving to the iPhone and back, notifications, flapping output, the
//  music app relaunching, and Core Audio misbehaving. In every case the bars must come back
//  on their own, quickly, without restarting the app.
//

import Foundation
import Testing
@testable import DynamicNotch

@Suite("Waveform survives real-life events", .serialized)
struct WaveformScenarioTests {
    typealias W = AudioWorld

    /// Music playing on the speakers with live bars.
    private func playingOnSpeakers() throws -> WaveformHarness {
        let h = WaveformHarness()
        let startup = try #require(h.secondsUntilLive(within: 1), "bars live at start")
        #expect(startup < 0.2)
        h.resetCounters()
        return h
    }

    // MARK: Steady state

    @Test func steadyPlaybackNeverRebuilds() throws {
        let h = try playingOnSpeakers()
        h.advance(30)
        #expect(h.world.tapsStarted == 1)
        #expect(h.deadTime == 0)
        #expect(!h.deadlocked)
    }

    @Test func gapBetweenTracksDoesNotBreakAnything() throws {
        let h = try playingOnSpeakers()
        h.world.setMusicPlaying(false)      // 4 s of silence while the player says "playing"
        h.advance(4)
        h.world.setMusicPlaying(true)
        let back = try #require(h.secondsUntilLive(within: 1))
        #expect(back < 0.2)
        h.advance(10)
        #expect(h.world.liveTaps == 1)
    }

    // MARK: AirPods connect to the Mac mid-song (the reported bug)

    @Test func airPodsConnectMidSong() throws {
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        h.advance(0.1)
        h.world.changeFormat()    // Bluetooth settles its format
        h.advance(0.2)
        h.world.changeFormat()
        let back = try #require(h.secondsUntilLive(within: 3))
        #expect(back < 1, "bars back as soon as the music is audible again")
        h.advance(20)
        #expect(h.deadTime < 1)
        #expect(h.world.tapsStarted == 1, "the tap isn't tied to the output: no rebuild needed")
        #expect(h.world.liveTaps == 1)
    }

    /// Core Audio breaking the running tap during the switch (silent or no more buffers),
    /// and the first rebuild breaking too.
    @Test(arguments: [AudioWorld.Quirk.silent, .dead])
    func switchBreaksTheTap(_ quirk: AudioWorld.Quirk) throws {
        let h = try playingOnSpeakers()
        let switchedAt = h.clock.now()
        h.world.switchBreaksTaps = quirk
        h.world.quirkForNewTap = { [clock = h.clock] in clock.now() - switchedAt < 2 ? quirk : .normal }
        h.world.connect(W.airPods)
        let back = try #require(h.secondsUntilLive(within: 10))
        #expect(back < 6)
        h.advance(20)
        #expect(h.isLive)
        #expect(h.world.liveTaps == 1)
    }

    @Test func tapsRefusedForAWhileAfterSwitch() throws {
        let h = try playingOnSpeakers()
        let switchedAt = h.clock.now()
        h.world.switchBreaksTaps = .dead
        h.world.failStart = { [clock = h.clock] in
            clock.now() - switchedAt < 3 ? AudioTapError(step: "creating the aggregate device", status: -1) : nil
        }
        h.world.connect(W.airPods)
        let back = try #require(h.secondsUntilLive(within: 8))
        #expect(back < 5)
    }

    // MARK: AirPods move to the iPhone and back

    @Test func airPodsLeaveForIPhoneAndMacKeepsPlayingOnSpeakers() throws {
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        _ = try #require(h.secondsUntilLive(within: 3))
        h.world.disconnect(W.airPods)       // iPhone takes them; old tap's clock is gone
        let back = try #require(h.secondsUntilLive(within: 4))
        #expect(back < 2.5)
        h.advance(10)
        #expect(h.isLive)
    }

    @Test func airPodsLeaveForIPhoneThenComeBack() throws {
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        _ = try #require(h.secondsUntilLive(within: 3))

        // To the iPhone: macOS pauses the music, the bars go away.
        h.world.disconnect(W.airPods)
        h.world.setMusicPlaying(false)
        h.viewReleases()
        h.advance(20)
        #expect(h.world.liveTaps == 0, "no tap left running while nothing is shown")

        // Back to the Mac and press play.
        h.world.connect(W.airPods)
        h.advance(0.3)
        h.world.setMusicPlaying(true)
        h.viewRetains()
        let back = try #require(h.secondsUntilLive(within: 3))
        #expect(back < 1.2)
    }

    @Test func airPodsComeBackFromIPhoneWhilePlayingOnSpeakers() throws {
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods, makeDefault: false)  // reconnects quietly first
        h.advance(1)
        h.world.setDefault(W.airPods)                   // then takes over the output
        let back = try #require(h.secondsUntilLive(within: 3))
        #expect(back < 1.2)
    }

    @Test func handoffPingPongManyTimes() throws {
        let h = try playingOnSpeakers()
        for round in 0 ..< 6 {
            if round.isMultiple(of: 2) { h.world.connect(W.airPods) } else { h.world.disconnect(W.airPods) }
            let back = h.secondsUntilLive(within: 5)
            #expect(back != nil && back! < 2.5, "round \(round)")
            h.advance(2)
        }
        #expect(h.world.liveTaps == 1)
        #expect(!h.deadlocked)
    }

    @Test func outputFlapsBackAndForth() throws {
        // macOS fighting over the output (seen in the logs: speakers, then AirPods 0.5 s later).
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        for i in 0 ..< 6 {
            h.advance(0.15)
            h.world.setDefault(i.isMultiple(of: 2) ? W.speakers : W.airPods)
        }
        let back = try #require(h.secondsUntilLive(within: 4))
        #expect(back < 1.5)
        #expect(h.world.tapsStarted == 1, "flapping output doesn't touch the tap")
    }

    @Test func allOutputsDisappearAndReturn() throws {
        let h = try playingOnSpeakers()
        h.world.disconnect(W.speakers)
        h.advance(3)
        #expect(!h.deadlocked)
        h.world.connect(W.speakers)
        let back = try #require(h.secondsUntilLive(within: 4))
        #expect(back < 3)
    }

    // MARK: Notifications

    @Test func notificationBannerBrieflyHidesTheBars() throws {
        // A banner covers the notch for a moment: the view releases and comes straight back.
        let h = try playingOnSpeakers()
        h.viewReleases()
        h.advance(0.2)
        h.viewRetains()
        h.advance(1)
        #expect(h.isLive)
        #expect(h.world.tapsStarted == 1, "kept the tap through the grace period")
    }

    @Test func longNotificationHidesTheBars() throws {
        let h = try playingOnSpeakers()
        h.viewReleases()
        h.advance(5)
        #expect(h.world.liveTaps == 0)
        h.viewRetains()
        let back = try #require(h.secondsUntilLive(within: 1))
        #expect(back < 0.2)
    }

    @Test func notificationSoundChangesOutputFormat() throws {
        // Some outputs (AirPods) switch format for a system sound and back.
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        _ = try #require(h.secondsUntilLive(within: 3))
        h.resetCounters()
        h.world.changeFormat()
        h.advance(0.3)
        h.world.changeFormat()
        h.advance(10)
        #expect(h.isLive)
        #expect(h.deadTime < 1.5)
    }

    @Test func notificationsDuringHandoff() throws {
        let h = try playingOnSpeakers()
        h.world.connect(W.airPods)
        h.viewReleases()                    // banner appears mid-switch
        h.advance(0.3)
        h.world.changeFormat()
        h.viewRetains()
        let back = try #require(h.secondsUntilLive(within: 3))
        #expect(back < 1.5)
    }

    // MARK: The music app

    @Test func musicAppRelaunches() throws {
        let h = try playingOnSpeakers()
        h.world.relaunchMusicApp(processes: [42])
        let back = try #require(h.secondsUntilLive(within: 3))
        #expect(back < 1.5)
    }

    @Test func switchesToMusicAppOnceItHasAudio() throws {
        let h = try playingOnSpeakers()
        h.world.relaunchMusicApp(processes: [])         // no audio process yet: tap everything
        h.advance(2)
        h.world.relaunchMusicApp(processes: [8])
        h.advance(2)
        #expect(h.isLive)
    }

    // MARK: Core Audio misbehaving

    @Test func stuckCoreAudioRestartsTheApp() throws {
        let h = try playingOnSpeakers()
        h.world.stopHangs = true
        h.world.relaunchMusicApp(processes: [42])       // the rebuild hangs in stopTap
        // Keep polling like the view does; the monitor's queue is stuck.
        let start = Date()
        while !h.stuckReported, Date().timeIntervalSince(start) < 3 {
            h.clock.setTime(h.clock.now() + 0.5)
            while let due = h.clock.nextDue() { _ = runOn(due.queue, timeout: 0.05, due.block) }
            h.monitor.ensureRunning()
        }
        #expect(h.stuckReported, "a stuck queue restarts the app instead of freezing the bars")
    }

    /// Audio arriving on Core Audio's thread while the tap is rebuilt over and over: stopping
    /// a tap must never wait on the queue that is stopping it (the freeze that needed a restart).
    @Test func rebuildingDuringPlaybackNeverDeadlocks() throws {
        let h = try playingOnSpeakers()
        let stop = DispatchSemaphore(value: 0)
        let ioDone = DispatchSemaphore(value: 0)
        var ioOK = true
        Thread.detachNewThread {
            while stop.wait(timeout: .now()) == .timedOut {
                if !h.world.ioCycle(samples: 256) { ioOK = false; break }
            }
            ioDone.signal()
        }
        for i in 0 ..< 300 {
            h.monitor.setTarget(bundleID: i.isMultiple(of: 2) ? "com.example.other" : W.music)
            if !runOn(DispatchQueue.global(), { h.monitor.sync() }) {
                Issue.record("monitor deadlocked after \(i) rebuilds")
                break
            }
        }
        stop.signal()
        #expect(ioDone.wait(timeout: .now() + 3) == .success, "audio thread deadlocked")
        #expect(ioOK)
    }
}

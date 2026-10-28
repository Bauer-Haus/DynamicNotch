//
//  ControlFeedbackTests.swift
//  boringNotchTests
//
//  The notch's media controls change at once; the player's report confirms them later.
//

import Foundation
import Testing
@testable import Boring_Notch

@Suite("Control feedback")
struct ControlFeedbackTests {
    private let now = Date()
    private func pressed<T: Equatable>(_ value: T, secondsAgo: Double = 0) -> PendingValue<T> {
        PendingValue(value: value, until: now.addingTimeInterval(MusicManager.optimisticHold - secondsAgo))
    }

    @Test func staleReportDoesNotUndoAPress() {
        // Pressed pause; a report from before the press still says playing.
        let result = MusicManager.reconcile(reported: true, pending: pressed(false), now: now)
        #expect(result.shown == false)
        #expect(result.pending != nil, "keep waiting for the player to confirm")
    }

    @Test func confirmingReportEndsTheWait() {
        let result = MusicManager.reconcile(reported: false, pending: pressed(false), now: now)
        #expect(result.shown == false)
        #expect(result.pending == nil)
    }

    @Test func playerWinsOnceTheHoldIsOver() {
        // The press never took effect (player not running): show what the player says.
        let expired = pressed(false, secondsAgo: MusicManager.optimisticHold + 0.1)
        let result = MusicManager.reconcile(reported: true, pending: expired, now: now)
        #expect(result.shown == true)
        #expect(result.pending == nil)
    }

    @Test func noPressMeansThePlayerIsShown() {
        let result = MusicManager.reconcile(reported: RepeatMode.one, pending: nil, now: now)
        #expect(result.shown == .one)
        #expect(result.pending == nil)
    }

    @Test func holdIsLongEnoughForTheSlowestReplyButShort() {
        // Measured on Apple Music: up to ~250 ms from press to report.
        #expect(MusicManager.optimisticHold >= 0.5 && MusicManager.optimisticHold <= 3)
    }

    @Test func repeatCyclesLikeMusicAndNowPlaying() {
        #expect(MusicManager.nextRepeatMode(after: .off, offAndAllOnly: false) == .all)
        #expect(MusicManager.nextRepeatMode(after: .all, offAndAllOnly: false) == .one)
        #expect(MusicManager.nextRepeatMode(after: .one, offAndAllOnly: false) == .off)
    }

    @Test func spotifyRepeatOnlyTogglesOffAndAll() {
        #expect(MusicManager.nextRepeatMode(after: .off, offAndAllOnly: true) == .all)
        #expect(MusicManager.nextRepeatMode(after: .all, offAndAllOnly: true) == .off)
        #expect(MusicManager.nextRepeatMode(after: .one, offAndAllOnly: true) == .off)
    }
}

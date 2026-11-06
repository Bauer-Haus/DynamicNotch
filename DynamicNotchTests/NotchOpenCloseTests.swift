//
//  NotchOpenCloseTests.swift
//  DynamicNotchTests
//
//  Opening, closing and reopening the notch, and keeping its size right when screens or
//  settings change part way through.
//

import Defaults
import Foundation
import Testing
@testable import DynamicNotch

@Suite("Opening and closing the notch", .serialized)
@MainActor
struct NotchOpenCloseTests {
    private func openSize(_ vm: NotchViewModel) -> CGSize {
        openNotchSize()
    }

    @Test func opensToTheOpenSize() {
        let vm = NotchViewModel()
        vm.open()
        #expect(vm.notchState == .open)
        #expect(vm.notchSize == openSize(vm))
        #expect(!vm.closedPlayerHeld && !vm.closedPlayerGrowing)
    }

    @Test func closesToTheClosedSize() {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        #expect(vm.notchState == .closed)
        #expect(vm.notchSize == vm.closedNotchSize)
    }

    /// Like the iPhone: the closed player waits for the bare notch, then grows out of it.
    @Test func closedPlayerWaitsThenGrowsOut() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        #expect(vm.closedPlayerHeld)
        #expect(!vm.closedPlayerGrowing)

        try await Task.sleep(for: .milliseconds(400))
        #expect(!vm.closedPlayerHeld)
        #expect(vm.closedPlayerGrowing)

        try await Task.sleep(for: .milliseconds(700))
        #expect(!vm.closedPlayerGrowing)
    }

    /// Opening again part way through a close: the rest of that close must not run.
    @Test func reopeningCancelsTheCloseInProgress() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(100))
        vm.open()
        #expect(!vm.closedPlayerHeld)

        try await Task.sleep(for: .milliseconds(1000))
        #expect(vm.notchState == .open)
        #expect(!vm.closedPlayerHeld && !vm.closedPlayerGrowing)
        #expect(vm.notchSize == openSize(vm))
    }

    /// Closing twice quickly: only the second close's timers apply.
    @Test func closingAgainRestartsTheGrowOut() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(200))
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(150))
        // 350 ms after the first close but only 150 ms after the second: still held.
        #expect(vm.closedPlayerHeld)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!vm.closedPlayerHeld)
    }

    @Test func firstOpenMorphsFromTheClosedPlayer() {
        let vm = NotchViewModel()
        vm.open()
        #expect(vm.openMorphsFromClosedPlayer)
    }

    /// Reopened before the closed player came back: nothing to morph from.
    @Test func reopenBeforeTheClosedPlayerReturnsDoesNotWait() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(100))
        vm.open()
        #expect(!vm.openMorphsFromClosedPlayer)
    }

    /// Reopened while the closed player grows out, unlinked: nothing to morph from either.
    @Test func reopenWhileTheClosedPlayerGrowsDoesNotWait() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(vm.closedPlayerGrowing)
        vm.open()
        #expect(!vm.openMorphsFromClosedPlayer)
    }

    /// Once the close has fully settled, opening morphs again.
    @Test func reopenAfterTheCloseSettlesMorphs() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(1000))
        vm.open()
        #expect(vm.openMorphsFromClosedPlayer)
    }

    /// Tapping an open notch calls open again; that mustn't change how it opened.
    @Test func openingWhenOpenKeepsHowItOpened() async throws {
        let vm = NotchViewModel()
        vm.open()
        vm.close()
        try await Task.sleep(for: .milliseconds(100))
        vm.open()
        vm.open()
        #expect(!vm.openMorphsFromClosedPlayer)
    }

    @Test func closingWhenClosedChangesNothing() {
        let vm = NotchViewModel()
        vm.close()
        #expect(vm.notchState == .closed)
        #expect(!vm.closedPlayerHeld)
        #expect(vm.notchSize == vm.closedNotchSize)
    }

    /// A screen or setting change while open used to shrink the notch to its closed size
    /// while it stayed open.
    @Test func screenChangeKeepsAnOpenNotchOpenSized() {
        let vm = NotchViewModel()
        vm.open()
        vm.refreshSizes()
        #expect(vm.notchState == .open)
        #expect(vm.notchSize == openSize(vm))
    }

    @Test func screenChangeKeepsAClosedNotchClosedSized() {
        let vm = NotchViewModel()
        vm.refreshSizes()
        #expect(vm.notchSize == vm.closedNotchSize)
    }

    @Test func changingTheOpenWidthResizesAnOpenNotch() async throws {
        let saved = Defaults[.openNotchWidth]
        defer { Defaults[.openNotchWidth] = saved }

        let vm = NotchViewModel()
        Defaults[.openNotchWidth] = .apple
        vm.open()
        #expect(vm.notchSize.width == OpenPlayer.islandWidth + 2 * notchTopCornerRadius)

        Defaults[.openNotchWidth] = .matchNotch
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.notchSize.width == OpenNotchWidth.largeIslandWidth + 2 * notchTopCornerRadius)
    }

    @Test func openNotchFitsInTheWindow() {
        for width in OpenNotchWidth.allCases {
            let island = width.islandWidth + 2 * notchTopCornerRadius
            #expect(island + 2 * islandShadowMargin <= windowSize.width)
        }
    }
}

@Suite("Open waveform")
struct OpenWaveformTests {
    /// The same square as the closed notch's waveform (the notch less 12 pt).
    @Test(arguments: [24.0, 32, 37, 38])
    func matchesTheClosedWaveform(closedHeight: CGFloat) {
        #expect(OpenPlayer.waveformSide(closedHeight: closedHeight) == closedHeight - 12)
    }

    @Test func neverVanishesWhenTheClosedNotchIsTiny() {
        #expect(OpenPlayer.waveformSide(closedHeight: 0) == OpenPlayer.minWaveformSide)
        #expect(OpenPlayer.waveformSide(closedHeight: 15) == OpenPlayer.minWaveformSide)
    }
}

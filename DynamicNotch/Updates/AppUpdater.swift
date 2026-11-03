//
//  AppUpdater.swift
//  DynamicNotch
//
//  Software updates through Sparkle: a daily background check plus "Check for Updates…" in
//  the menu bar menu and Settings. Releases are built by release.sh and published as GitHub
//  Releases of Bauer-Haus/DynamicNotch, each carrying the DMG and an appcast.xml; the app
//  reads the latest release's appcast. Every update is signed with the EdDSA key whose
//  public half is SUPublicEDKey in Info.plist, so only our builds are ever installed.
//

import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    /// False while a check is already running (or before the updater has started).
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }

    /// Starts the updater. Called once at launch (not while unit tests run, so they never
    /// touch the network).
    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        guard let controller else { return }
        // DynamicNotch has no Dock icon; bring it forward so Sparkle's window isn't
        // opened behind whatever app is in front.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu bar app has no Dock icon to badge, so a background check that finds an update
    /// shows Sparkle's window gently (without stealing focus) instead of being missed.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        Task { @MainActor in NSApp.activate() }
    }
}

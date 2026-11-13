//
//  VisualizerWindowController.swift
//  DynamicNotch
//
//  Opens the full-screen visualizer over a display and closes it again.
//

import AppKit
import os

@MainActor
final class VisualizerWindowController {
    static let shared = VisualizerWindowController()
    private static let log = os.Logger.app("visualizer")

    private var window: FullScreenOverlayWindow?
    private var model: VisualizerModel?
    private var previousApp: NSRunningApplication?
    private var observers: [Any] = []

    var isOpen: Bool { window != nil }

    private init() {}

    func toggle(on screen: NSScreen? = nil) {
        if isOpen { close() } else { show(on: screen) }
    }

    /// Opens over `screen` (by default the one with the pointer).
    func show(on screen: NSScreen? = nil) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let model = VisualizerModel() else {
            Self.log.error("Visualizer unavailable: Metal could not be set up")
            return
        }
        guard let screen = screen ?? FullScreenOverlayWindow.screenUnderPointer() else { return }

        let window = FullScreenOverlayWindow(screen: screen, content: VisualizerView(model: model) { [weak self] in self?.close() })
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.onEscape = { [weak self] in self?.close() }
        window.onClose = { [weak self] in self?.close() }

        previousApp = .frontmostOtherApp
        self.window = window
        self.model = model

        VisualizerAudio.shared.start(bundleID: MusicManager.shared.bundleIdentifier)
        window.present(fadeDuration: 0.5)
        observe(window)
        Self.log.notice("Visualizer opened")
    }

    func close() {
        guard let window else { return }
        self.window = nil
        let model = self.model
        self.model = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        VisualizerAudio.shared.stop()
        NSCursor.setHiddenUntilMouseMoves(false)
        window.dismiss(fadeDuration: 0.3) { model?.setPaused(true) }
        previousApp?.activate()
        previousApp = nil
        Self.log.notice("Visualizer closed")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        switch event.keyCode {
        case 53: close() // Esc
        case 49: MusicManager.shared.togglePlay(); model.showControls() // Space
        case 123: MusicManager.shared.previousTrack(); model.showControls() // ←
        case 124: MusicManager.shared.nextTrack(); model.showControls() // →
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": model.toggleArtwork()
            case "s": model.cycleSpeakerLayout()
            case "d": model.toggleAirPodsDelay()
            default: return false
            }
        }
        return true
    }

    private func updatePaused() {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible) && ScreenActivity.shared.isActive
        model?.setPaused(!visible)
    }

    /// Stops drawing while nobody can see it, and closes if the user switches to another app
    /// (the window sits above everything, so it mustn't be left behind).
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        })
        observers.append(center.addObserver(forName: ScreenActivity.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePaused() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Our own Settings window or a menu doesn't count; another app does.
                guard NSWorkspace.shared.frontmostApplication?.isThisApp != true else { return }
                self?.previousApp = nil
                self?.close()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.refitToScreen() }
        })
    }
}

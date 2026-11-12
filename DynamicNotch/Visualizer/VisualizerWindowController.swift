//
//  VisualizerWindowController.swift
//  DynamicNotch
//
//  Opens the full-screen visualizer over a display and closes it again.
//

import AppKit
import os
import SwiftUI

/// A borderless window that can take the keyboard: Esc closes, Space plays/pauses, the
/// arrow keys skip tracks, A shows or hides the cover and S changes the speaker pulses.
final class VisualizerWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        VisualizerWindowController.shared.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            VisualizerWindowController.shared.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class VisualizerWindowController {
    static let shared = VisualizerWindowController()
    private static let log = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "visualizer")

    private var window: VisualizerWindow?
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
        let mouse = NSEvent.mouseLocation
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }

        let window = VisualizerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the menu bar and the notch, like a screen saver.
        window.level = .mainMenu + 4
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: VisualizerView(model: model) { [weak self] in self?.close() })
        window.setFrame(screen.frame, display: false)
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.alphaValue = 0

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        self.window = window
        self.model = model

        VisualizerAudio.shared.start(bundleID: MusicManager.shared.bundleIdentifier)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            window.animator().alphaValue = 1
        }
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                model?.setPaused(true)
                window.orderOut(nil)
                window.contentView = nil
            }
        })
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
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.previousApp = nil
                self?.close()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let screen = window.screen ?? NSScreen.main
                if let frame = screen?.frame { window.setFrame(frame, display: true) }
            }
        })
    }
}

//
//  AlbumFlowWindowController.swift
//  DynamicNotch
//
//  Opens Album Flow full screen over a display and closes it again.
//

import AppKit
import os
import SwiftUI

/// A borderless window that takes the keyboard.
final class AlbumFlowWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        AlbumFlowWindowController.shared.escape()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            AlbumFlowWindowController.shared.close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AlbumFlowWindowController {
    static let shared = AlbumFlowWindowController()
    private static let log = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "albumFlow")

    private var window: AlbumFlowWindow?
    private var model: AlbumFlowModel?
    private var previousApp: NSRunningApplication?
    private var observers: [Any] = []

    var isOpen: Bool { window != nil }

    private init() {}

    func toggle(on screen: NSScreen? = nil) {
        if isOpen { close() } else { show(on: screen) }
    }

    /// Opens over `screen` (by default the one with the pointer), at the album playing now.
    func show(on screen: NSScreen? = nil) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let model = AlbumFlowModel()
        let music = MusicManager.shared
        model.load(startingAt: music.isPlayerIdle ? nil : (music.album, music.artistName))
        model.showControls()

        let window = AlbumFlowWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the menu bar and the notch, like the visualizer.
        window.level = .mainMenu + 4
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: AlbumFlowScreen(model: model) { [weak self] in self?.close() })
        window.setFrame(screen.frame, display: false)
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.alphaValue = 0

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        self.window = window
        self.model = model

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            window.animator().alphaValue = 1
        }
        observe(window)
        Self.log.notice("Album Flow opened")
    }

    /// Esc: turns a flipped cover back first, then closes.
    func escape() {
        if let model, model.isFlipped { model.unflip() } else { close() }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        model = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
        previousApp?.activate()
        previousApp = nil
        Self.log.notice("Album Flow closed")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        model.showControls()
        switch event.keyCode {
        case 53: escape() // Esc
        case 123: model.move(by: -1) // ←
        case 124: model.move(by: 1) // →
        case 115: model.go(to: 0) // Home
        case 119: model.go(to: model.albums.count - 1) // End
        case 116: model.move(by: -10) // Page Up
        case 121: model.move(by: 10) // Page Down
        case 36, 76: model.playCentre() // Return
        case 49: MusicManager.shared.togglePlay() // Space
        case 125, 126: model.toggleFlip() // ↓ ↑
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " })
            else { return false }
            model.typeAhead(characters)
        }
        return true
    }

    /// Closes if the user switches to another app (the window sits above everything).
    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.previousApp = nil
                self?.close()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                if let frame = (window.screen ?? NSScreen.main)?.frame { window.setFrame(frame, display: true) }
            }
        })
    }
}

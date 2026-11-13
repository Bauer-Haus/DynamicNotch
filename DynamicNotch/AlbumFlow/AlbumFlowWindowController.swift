//
//  AlbumFlowWindowController.swift
//  DynamicNotch
//
//  Opens Album Flow full screen over a display and closes it again.
//

import AppKit
import Combine
import os

@MainActor
final class AlbumFlowWindowController {
    static let shared = AlbumFlowWindowController()
    private static let log = os.Logger.app("albumFlow")

    private var window: FullScreenOverlayWindow?
    private var model: AlbumFlowModel?
    private var previousApp: NSRunningApplication?
    private var observers: [Any] = []
    private var songChanges: AnyCancellable?

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
        guard let screen = screen ?? FullScreenOverlayWindow.screenUnderPointer() else { return }
        let model = AlbumFlowModel()
        let music = MusicManager.shared
        model.load(startingAt: music.isPlayerIdle ? nil : Self.nowPlaying())
        model.showControls()
        // Turns to each new album as the music moves on. Like the notch's waveform and the
        // visualizer, it goes by the cover changing as well as the song's name (whichever
        // arrives), then reads the song once its details have settled.
        songChanges = Publishers.Merge(music.$albumArt.map { _ in () }, music.$songTitle.map { _ in () })
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak model] in
                MainActor.assumeIsolated { model?.follow(Self.nowPlaying()) }
            }

        let window = FullScreenOverlayWindow(screen: screen, content: AlbumFlowScreen(model: model) { [weak self] in self?.close() })
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.onEscape = { [weak self] in self?.escape() }
        window.onClose = { [weak self] in self?.close() }

        previousApp = .frontmostOtherApp
        self.window = window
        self.model = model

        window.present(fadeDuration: 0.4)
        observe(window)
        Self.log.notice("Album Flow opened")
    }

    private static func nowPlaying() -> AlbumFlowModel.NowPlaying {
        let music = MusicManager.shared
        return .init(title: music.songTitle, artist: music.artistName, album: music.album)
    }

    /// Esc: turns a flipped cover back first, then closes.
    func escape() {
        if let model, model.isFlipped { model.unflip() } else { close() }
    }

    func close() {
        guard let window else { return }
        self.window = nil
        model = nil
        songChanges = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        window.dismiss(fadeDuration: 0.25)
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
                guard let self, let front = NSWorkspace.shared.frontmostApplication, !front.isThisApp else { return }
                // Reading the Music library the first time hands focus to a background helper
                // for a moment; that isn't the user switching apps, so take it back.
                if front.activationPolicy != .regular {
                    Self.log.notice("Album Flow: \(front.bundleIdentifier ?? "?", privacy: .public) took focus; taking it back")
                    NSApp.activate(ignoringOtherApps: true)
                    self.window?.makeKeyAndOrderFront(nil)
                    return
                }
                Self.log.notice("Album Flow: closing, \(front.bundleIdentifier ?? "?", privacy: .public) is now in front")
                self.previousApp = nil
                self.close()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.refitToScreen() }
        })
    }
}

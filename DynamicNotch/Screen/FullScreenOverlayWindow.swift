//
//  FullScreenOverlayWindow.swift
//  DynamicNotch
//
//  The borderless window the visualizer and Album Flow cover a display with.
//

import AppKit
import SwiftUI

/// A black, borderless window over a whole display, above the menu bar and the notch like a
/// screen saver. It takes the keyboard: keys go to `onKey` first, Esc calls `onEscape` and
/// ⌘W calls `onClose`.
final class FullScreenOverlayWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    var onClose: (() -> Void)?

    init(screen: NSScreen, content: some View) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .mainMenu + 4
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = NSHostingView(rootView: content)
        setFrame(screen.frame, display: false)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The display under the pointer, else the main one.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }

    /// Brings the app forward and fades the window in.
    func present(fadeDuration: TimeInterval) {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeDuration
            animator().alphaValue = 1
        }
    }

    /// Fades out, then takes the window off screen and drops its content.
    func dismiss(fadeDuration: TimeInterval, then completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                completion?()
                self.orderOut(nil)
                self.contentView = nil
            }
        })
    }

    /// Fills its display again after the screen arrangement changes.
    func refitToScreen() {
        if let frame = (screen ?? NSScreen.main)?.frame { setFrame(frame, display: true) }
    }
}

extension NSRunningApplication {
    /// Whether this is DynamicNotch itself.
    var isThisApp: Bool { processIdentifier == ProcessInfo.processInfo.processIdentifier }

    /// The app in front, unless it's DynamicNotch: the one to hand focus back to on closing.
    @MainActor static var frontmostOtherApp: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, !front.isThisApp else { return nil }
        return front
    }
}

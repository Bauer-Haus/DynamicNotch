//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import SwiftUI

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }
    
    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readOnly
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Black rounded corners at the bottom of the built-in notched screen, so it matches its top
/// corners. Measured from a photo of a 14" MacBook Pro's top corner against an on-screen
/// grid: an Apple continuous corner of 18 pt at 1512 x 982 (36 pixels, 3.6 mm), within
/// ~0.1 pt along the whole curve. Clicks pass through, and like the real corners they don't
/// show in screenshots or recordings. They sit above every window, full-screen apps and the
/// lock screen included. Settings can turn them off.
@MainActor
final class ScreenCornerMasks {
    static let shared = ScreenCornerMasks()

    /// The top corners' radius on the panel itself.
    static let cornerRadiusMillimetres: CGFloat = 3.6
    /// A continuous corner curves in from ~1.5x its radius along each edge.
    static let maskSizeFactor: CGFloat = 1.6

    private var windows: [NSWindow] = []
    private var settingObserver: AnyCancellable?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ScreenCornerMasks.shared.refresh() }
        }
        settingObserver = Defaults.publisher(.roundBottomScreenCorners, options: [])
            .receive(on: DispatchQueue.main)
            .sink { _ in Task { @MainActor in ScreenCornerMasks.shared.refresh() } }
    }

    /// Puts the corners on every screen with a camera notch (the 2021-and-later MacBook Pro
    /// and Air design: round top corners, square bottom ones).
    func refresh() {
        windows.forEach { window in
            SkyLightOperator.shared.undelegateWindow(window)
            window.close()
        }
        windows = []
        guard Defaults[.roundBottomScreenCorners] else { return }
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            let radius = Self.cornerRadius(on: screen)
            guard radius > 0 else { continue }
            let size = (radius * Self.maskSizeFactor).rounded(.up)
            let frame = screen.frame
            windows.append(makeWindow(
                frame: NSRect(x: frame.minX, y: frame.minY, width: size, height: size),
                corner: .bottomLeft, radius: radius))
            windows.append(makeWindow(
                frame: NSRect(x: frame.maxX - size, y: frame.minY, width: size, height: size),
                corner: .bottomRight, radius: radius))
        }
    }

    /// The radius in points: 3.6 mm at the screen's current scaling (18 pt at 1512 x 982 on a 14").
    static func cornerRadius(on screen: NSScreen) -> CGFloat {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return 0 }
        let millimetres = CGDisplayScreenSize(number.uint32Value).width
        guard millimetres > 0 else { return 0 }
        return cornerRadiusMillimetres * screen.frame.width / millimetres
    }

    enum Corner { case bottomLeft, bottomRight }

    /// Black everywhere in `bounds` outside an Apple continuous corner of `radius` sitting in
    /// that corner of the screen.
    static func maskPath(in bounds: CGRect, corner: Corner, radius: CGFloat) -> CGPath {
        let side = bounds.width * 4
        // A large rounded rectangle whose bottom-left (or bottom-right) corner is the screen's.
        let inside = CGRect(
            x: corner == .bottomLeft ? bounds.minX : bounds.maxX - side,
            y: bounds.minY, width: side, height: side)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: inside).cgPath)
        return path
    }

    private func makeWindow(frame: NSRect, corner: Corner, radius: CGFloat) -> NSWindow {
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // The highest level there is: above menus, alerts, full-screen apps and screen savers.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.sharingType = .none

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let shape = CAShapeLayer()
        shape.frame = view.bounds
        shape.fillColor = NSColor.black.cgColor
        shape.fillRule = .evenOdd
        shape.path = Self.maskPath(in: view.bounds, corner: corner, radius: radius)
        view.layer?.addSublayer(shape)
        window.contentView = view
        // The window server's own top layer, as the notch uses on the lock screen: above
        // full-screen apps and the lock screen, on every Space.
        SkyLightOperator.shared.delegateWindow(window)
        window.orderFrontRegardless()
        return window
    }
}

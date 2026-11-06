//
//  ScreenCornerMasks.swift
//  DynamicNotch
//
//  The black rounded bottom screen corners that match the top ones.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import SwiftUI

/// Black rounded corners at the bottom of the built-in notched screen, so it matches its top
/// corners. The size comes from the window server, which knows each MacBook panel's own
/// corner radius (it differs by model and screen size). Its figure is for a slightly
/// different curve from Apple's continuous corner, so it's scaled to match a photo of a 14"
/// MacBook Pro's top corner against an on-screen grid: a continuous corner of 18 pt at
/// 1512 x 982 (3.6 mm), within ~0.1 pt along the whole curve, where the window server says
/// 20.19 pt. Clicks pass through, and like the real corners they don't
/// show in screenshots or recordings. They sit above every window, full-screen apps and the
/// lock screen included. Settings can turn them off.
@MainActor
final class ScreenCornerMasks {
    static let shared = ScreenCornerMasks()

    /// Fallback when the window server gives no radius: the 14" MacBook Pro's, on the panel itself.
    static let cornerRadiusMillimetres: CGFloat = 3.6
    /// The continuous-corner radius that matches the window server's figure (18 / 20.19, see above).
    static let systemRadiusScale: CGFloat = 18 / 20.19
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

    /// The radius in points at the screen's current scaling: the panel's own, from the window
    /// server, or 3.6 mm (18 pt at 1512 x 982 on a 14") if it has none.
    static func cornerRadius(on screen: NSScreen) -> CGFloat {
        guard let displayID = screen.onlineDisplayID else { return 0 }
        if let radii = systemCornerRadii(displayID) {
            // Already round at the bottom (or not a notched panel): nothing to add.
            guard radii.bottom < 1, radii.top > 0 else { return 0 }
            return radii.top * systemRadiusScale
        }
        let millimetres = CGDisplayScreenSize(displayID).width
        guard millimetres > 0 else { return 0 }
        return cornerRadiusMillimetres * screen.frame.width / millimetres
    }

    private typealias GetCornerRadii = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?,
        UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?
    ) -> Int32

    /// SkyLight's private `SLSDisplayGetCornerRadii`: the panel's corner radii in points at the
    /// current scaling, bottom pair first. Nil if it isn't there or fails.
    private static let getCornerRadii: GetCornerRadii? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "SLSDisplayGetCornerRadii") else { return nil }
        return unsafeBitCast(symbol, to: GetCornerRadii.self)
    }()

    static func systemCornerRadii(_ displayID: CGDirectDisplayID) -> (top: CGFloat, bottom: CGFloat)? {
        guard let getCornerRadii else { return nil }
        var bottomA = 0.0, bottomB = 0.0, topA = 0.0, topB = 0.0
        guard getCornerRadii(displayID, &bottomA, &bottomB, &topA, &topB) == 0 else { return nil }
        let top = max(topA, topB)
        guard top > 0, top < 200 else { return nil }
        return (CGFloat(top), CGFloat(max(bottomA, bottomB)))
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

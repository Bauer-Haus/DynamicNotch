//
import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import SwiftUI

// MARK: - Bars view

/// Whether anyone can see the screens: false while the displays sleep or another user's
/// session is in front. The notch window also shows on the lock screen, so window
/// occlusion alone doesn't always report it hidden when the display turns off.
@MainActor
final class ScreenActivity {
    static let shared = ScreenActivity()
    static let didChange = Notification.Name("DynamicNotch.screenActivityChanged")

    private(set) var isActive = true
    private var screensAsleep = false { didSet { update() } }
    private var sessionInactive = false { didSet { update() } }

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        let observe: (Notification.Name, @escaping @MainActor @Sendable (ScreenActivity) -> Void) -> Void = { name, change in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { change(ScreenActivity.shared) }
            }
        }
        observe(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
    }

    private func update() {
        let active = !screensAsleep && !sessionInactive
        guard active != isActive else { return }
        isActive = active
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

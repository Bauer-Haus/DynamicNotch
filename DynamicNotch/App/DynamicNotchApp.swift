//
//  DynamicNotchApp.swift
//  DynamicNotch
//
//  The app entry point and its menu bar menu (Settings, Check for Updates, Restart, Quit).
//

import AVFoundation
import Combine
import Defaults
import SwiftUI

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow
    @ObservedObject private var updater = AppUpdater.shared

    var body: some Scene {
        // A MacBook screen with its notch (18 x 12 pt, 1.5 pt lines like Apple's menu bar icons,
        // rounded top corners, square bottom ones); a
        // template image, so macOS tints it to match the menu bar.
        MenuBarExtra("DynamicNotch", image: "menubar", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Divider()
            Button("Restart DynamicNotch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

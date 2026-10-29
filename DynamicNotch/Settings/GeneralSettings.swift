//
//  GeneralSettings.swift
//  DynamicNotch
//
//  Settings, General page: startup, displays and privacy.
//

import Defaults
import LaunchAtLogin
import SwiftUI

struct GeneralSettings: View {
    @ObservedObject var coordinator = NotchCoordinator.shared
    @Default(.menubarIcon) var menubarIcon
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.showOnLockScreen) var showOnLockScreen
    @Default(.hideFromScreenRecording) var hideFromScreenRecording
    @State private var screens = Self.connectedScreens()

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLogin.Toggle {
                    SettingsLabel("Open at login", symbol: "power", color: .green)
                }
                Toggle(isOn: $menubarIcon) {
                    SettingsLabel(
                        "Show in menu bar",
                        subtitle: "Settings is also in the notch's right-click menu.",
                        symbol: "menubar.rectangle", color: .gray)
                }
            }

            Section("Displays") {
                Toggle(isOn: $showOnAllDisplays) {
                    SettingsLabel("Show on every display", symbol: "rectangle.on.rectangle", color: .blue)
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(name: .showOnAllDisplaysChanged, object: nil)
                }
                if !showOnAllDisplays {
                    Picker(selection: $coordinator.preferredScreenUUID) {
                        ForEach(screens, id: \.uuid) { screen in
                            Text(screen.name).tag(screen.uuid as String?)
                        }
                    } label: {
                        SettingsLabel("Display", symbol: "display", color: .blue)
                    }
                    Toggle(isOn: $automaticallySwitchDisplay) {
                        SettingsLabel(
                            "Use the main display when it's not connected",
                            symbol: "arrow.left.arrow.right", color: .blue)
                    }
                    .onChange(of: automaticallySwitchDisplay) {
                        NotificationCenter.default.post(name: .automaticallySwitchDisplayChanged, object: nil)
                    }
                }
            }
            .onChange(of: NSScreen.screens) { screens = Self.connectedScreens() }

            Section("Privacy") {
                Toggle(isOn: $showOnLockScreen) {
                    SettingsLabel("Show on the lock screen", symbol: "lock.fill", color: .orange)
                }
                Toggle(isOn: $hideFromScreenRecording) {
                    SettingsLabel(
                        "Hide from screenshots and recordings",
                        symbol: "record.circle", color: .red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit DynamicNotch") { NSApp.terminate(nil) }
                }
            }
        }
    }

    private static func connectedScreens() -> [(uuid: String, name: String)] {
        NSScreen.screens.compactMap { screen in
            screen.displayUUID.map { ($0, screen.localizedName) }
        }
    }
}

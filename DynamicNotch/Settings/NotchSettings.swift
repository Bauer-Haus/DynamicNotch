//
//  NotchSettings.swift
//  DynamicNotch
//
//  Settings, Notch page: opening, gestures, size and look.
//

import Defaults
import SwiftUI

struct NotchSettings: View {
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.enableHaptics) var enableHaptics
    @Default(.enableGestures) var enableGestures
    @Default(.closeGestureEnabled) var closeGestureEnabled
    @Default(.mediaSwipeGestures) var mediaSwipeGestures
    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.enableShadow) var enableShadow
    @Default(.roundBottomScreenCorners) var roundBottomScreenCorners

    var body: some View {
        Form {
            Section("Opening") {
                Toggle(isOn: $openNotchOnHover) {
                    SettingsLabel(
                        "Open on hover",
                        subtitle: "Otherwise, click the notch to open it.",
                        symbol: "cursorarrow.motionlines", color: .blue)
                }
                .onChange(of: openNotchOnHover) {
                    // Without hover, swiping is the other way to open it.
                    if !openNotchOnHover { enableGestures = true }
                }
                if openNotchOnHover {
                    SettingsSlider(
                        label: SettingsLabel("Hover delay", symbol: "timer", color: .blue),
                        value: $minimumHoverDuration, range: 0...1, step: 0.1
                    ) { String(format: "%.1f s", $0) }
                }
                Toggle(isOn: $enableHaptics) {
                    SettingsLabel(
                        "Haptic feedback",
                        subtitle: "A tap on the trackpad as the notch opens.",
                        symbol: "hand.tap.fill", color: .blue)
                }
            }

            Section("Gestures") {
                Toggle(isOn: $enableGestures) {
                    SettingsLabel(
                        "Two-finger swipes",
                        subtitle: "Swipe down on the notch to open it.",
                        symbol: "hand.draw.fill", color: .purple)
                }
                .disabled(!openNotchOnHover)
                if enableGestures {
                    Toggle(isOn: $closeGestureEnabled) {
                        SettingsLabel("Swipe up to close", symbol: "arrow.up", color: .purple)
                    }
                    Toggle(isOn: $mediaSwipeGestures) {
                        SettingsLabel(
                            "Swipe sideways to change track",
                            symbol: "arrow.left.and.right", color: .purple)
                    }
                    Picker(selection: $gestureSensitivity) {
                        Text("Low").tag(CGFloat(300))
                        Text("Medium").tag(CGFloat(200))
                        Text("High").tag(CGFloat(100))
                    } label: {
                        SettingsLabel("Sensitivity", symbol: "dial.medium.fill", color: .purple)
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section {
                heightPicker(
                    "Displays with a notch", symbol: "macbook", mode: $notchHeightMode,
                    options: [(.matchRealNotchSize, "Notch"), (.matchMenuBar, "Menu bar"), (.custom, "Custom")])
                if notchHeightMode == .custom {
                    SettingsSlider(
                        label: SettingsLabel("Height", symbol: "arrow.up.and.down", color: .teal),
                        value: $notchHeight, range: 15...45, step: 1
                    ) { "\(Int($0)) pt" }
                }
                heightPicker(
                    "Other displays", symbol: "display", mode: $nonNotchHeightMode,
                    options: [(.matchMenuBar, "Menu bar"), (.matchRealNotchSize, "Notch"), (.custom, "Custom")])
                if nonNotchHeightMode == .custom {
                    SettingsSlider(
                        label: SettingsLabel("Height", symbol: "arrow.up.and.down", color: .teal),
                        value: $nonNotchHeight, range: 0...40, step: 1
                    ) { "\(Int($0)) pt" }
                }
            } header: {
                Text("Closed height")
            }
            .onChange(of: notchHeightMode) { postHeightChange() }
            .onChange(of: notchHeight) { postHeightChange() }
            .onChange(of: nonNotchHeightMode) { postHeightChange() }
            .onChange(of: nonNotchHeight) { postHeightChange() }

            Section("Look") {
                Toggle(isOn: $enableShadow) {
                    SettingsLabel(
                        "Shadow",
                        subtitle: "A soft shadow round the open notch.",
                        symbol: "shadow", color: .gray)
                }
                Toggle(isOn: $roundBottomScreenCorners) {
                    SettingsLabel(
                        "Round bottom screen corners (PROLED XDR)",
                        subtitle: "Black corners at the bottom of the screen to match the top.",
                        symbol: "rectangle.roundedbottom", color: .gray)
                }
            }
        }
    }

    private func heightPicker(
        _ title: LocalizedStringKey, symbol: String, mode: Binding<WindowHeightMode>,
        options: [(WindowHeightMode, LocalizedStringKey)]
    ) -> some View {
        Picker(selection: mode) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        } label: {
            SettingsLabel(title, symbol: symbol, color: .teal)
        }
    }

    private func postHeightChange() {
        NotificationCenter.default.post(name: .notchHeightChanged, object: nil)
    }
}

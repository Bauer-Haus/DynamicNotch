//
//  MusicSettings.swift
//  DynamicNotch
//
//  Settings, Music page: the music source, the closed notch, full screen and the open
//  player's controls.
//

import Defaults
import SwiftUI

struct MusicSettings: View {
    @ObservedObject var coordinator = NotchCoordinator.shared
    @Default(.mediaController) var mediaController
    @Default(.coloredSpectrogram) var coloredSpectrogram
    @Default(.waitInterval) var waitInterval
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableLyrics) var enableLyrics

    var body: some View {
        Form {
            Section {
                Picker(selection: $mediaController) {
                    ForEach(MediaControllerType.available) { controller in
                        Text(controller.rawValue).tag(controller)
                    }
                } label: {
                    SettingsLabel("Music source", symbol: "music.note", color: .pink)
                }
                .onChange(of: mediaController) {
                    NotificationCenter.default.post(name: .mediaControllerChanged, object: nil)
                }
            } footer: {
                if !MusicManager.shared.isNowPlayingDeprecated {
                    Text("Now Playing works with every music and video app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Closed notch") {
                Toggle(isOn: $coordinator.musicLiveActivityEnabled.animation()) {
                    SettingsLabel(
                        "Show what's playing",
                        subtitle: "The album cover and waveform either side of the notch.",
                        symbol: "waveform", color: .pink)
                }
                if coordinator.musicLiveActivityEnabled {
                    Toggle(isOn: $coloredSpectrogram) {
                        SettingsLabel(
                            "Album colours in the waveform",
                            subtitle: "Otherwise the bars are grey.",
                            symbol: "paintpalette.fill", color: .pink)
                    }
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            SettingsLabel(
                                "Keep showing after pausing",
                                symbol: "pause.fill", color: .pink)
                            Spacer()
                            Text("\(Int(waitInterval)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Full screen") {
                Picker(selection: $hideNotchOption) {
                    Text("Always").tag(HideNotchOption.always)
                    Text("When the music app is full screen").tag(HideNotchOption.nowPlayingOnly)
                    Text("Never").tag(HideNotchOption.never)
                } label: {
                    SettingsLabel(
                        "Hide the notch",
                        symbol: "arrow.up.left.and.arrow.down.right", color: .orange)
                }
            }

            Section("Open player") {
                ControlRowEditor()
                Toggle(isOn: $enableLyrics) {
                    SettingsLabel(
                        "Lyrics",
                        subtitle: "The current line under the artist's name.",
                        symbol: "quote.bubble.fill", color: .pink)
                }
            }
        }
    }
}

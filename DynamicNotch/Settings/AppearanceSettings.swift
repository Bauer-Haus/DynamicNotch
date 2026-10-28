//
//  AppearanceSettings.swift
//  DynamicNotch
//
//  Settings, Appearance pane: waveform colours and screen corners.
//

import AVFoundation
import Defaults
import LaunchAtLogin
import SwiftUI

struct AppearanceSettings: View {
    @ObservedObject var coordinator = NotchCoordinator.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .coloredSpectrogram) {
                    Text("Colored spectrogram")
                }
                Defaults.Toggle(key: .roundBottomScreenCorners) {
                    Text("Round bottom screen corners")
                }
            } header: {
                Text("Media")
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Appearance")
    }
}

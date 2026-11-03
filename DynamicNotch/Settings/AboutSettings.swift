//
//  AboutSettings.swift
//  DynamicNotch
//
//  Settings, About page: the app, its version and where it lives.
//

import SwiftUI

struct AboutSettings: View {
    @ObservedObject private var updater = AppUpdater.shared

    private var version: String {
        let version = Bundle.main.releaseVersionNumber ?? "?"
        let build = Bundle.main.buildVersionNumber ?? "?"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text("DynamicNotch")
                        .font(.title2.weight(.semibold))
                    Text(version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section {
                Toggle(isOn: $updater.automaticallyChecksForUpdates) {
                    SettingsLabel("Automatically check for updates", symbol: "arrow.triangle.2.circlepath", color: .blue)
                }
                HStack {
                    SettingsLabel("Software update", symbol: "arrow.down.circle", color: .green)
                    Spacer()
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/Bauer-Haus/DynamicNotch")!) {
                    HStack {
                        SettingsLabel("Source code on GitHub", symbol: "chevron.left.forwardslash.chevron.right", color: .gray)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Made by BauerHaus · GPL-3.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }
}

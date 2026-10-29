//
//  SettingsView.swift
//  DynamicNotch
//
//  The Settings window: a sidebar of pages, laid out like System Settings.
//

import SwiftUI

/// The pages of the Settings window.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notch, music, about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .music: "Music"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .notch: "macbook"
        case .music: "music.note"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .notch: .blue
        case .music: .pink
        case .about: .indigo
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, color: pane.color)
                }
                .tag(pane)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(190)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralSettings()
                case .notch: NotchSettings()
                case .music: MusicSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane?.title ?? "General")
        }
        .frame(minWidth: 700, idealWidth: 720, minHeight: 480, idealHeight: 600)
    }
}

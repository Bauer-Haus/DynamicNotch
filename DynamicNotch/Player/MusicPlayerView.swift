//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import AVKit
import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: NotchViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        // Laid out like Apple's Dynamic Island: cover, song and live waveform on top, a
        // full-width progress bar, then a full-width row of controls (sizes: `OpenPlayer`).
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                    .frame(width: MusicPlayerImageSizes.size.opened.width,
                           height: MusicPlayerImageSizes.size.opened.height)
                SongInfoView()
                    .padding(.leading, OpenPlayer.artToText)
                    .drawingGroup()
                    .compositingGroup()
                AlbumWaveform(width: OpenPlayer.waveformSize.width, height: OpenPlayer.waveformSize.height)
                    .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                    // Level with the title's capitals.
                    .padding(.top, OpenPlayer.waveformTop)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.leading, 8)
            }
            .frame(height: MusicPlayerImageSizes.size.opened.height)

            PlaybackProgressView()
                .padding(.top, OpenPlayer.progressTop)

            MusicControlsView()
                .padding(.top, OpenPlayer.controlsTop)
        }
    }
}

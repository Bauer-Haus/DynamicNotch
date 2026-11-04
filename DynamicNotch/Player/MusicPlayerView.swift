//
//  MusicPlayerView.swift
//  DynamicNotch
//
//  The open notch's player layout: cover, title and waveform on top, then the progress bar
//  and controls.
//

import AVKit
import Combine
import Defaults
import SwiftUI

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
                let side = OpenPlayer.waveformSide(closedHeight: vm.closedNotchSize.height)
                AlbumWaveform(width: side, height: side)
                    .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                    .frame(width: side, height: side)
                    .hiddenWhileClosedNotchCovers(vm)
                    // Level with the title's capitals.
                    .padding(.top, max(0, OpenPlayer.waveformCentre - side / 2))
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

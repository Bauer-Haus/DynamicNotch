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
                    .modifier(OpensVisualizer(vm: vm))
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

/// Clicking the open player's waveform opens the full-screen visualizer; it grows a little
/// under the pointer to show it can be clicked.
private struct OpensVisualizer: ViewModifier {
    let vm: NotchViewModel
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.15 : 1)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { h in withAnimation(.smooth(duration: 0.2)) { hovering = h } }
            .onTapGesture { vm.openVisualizer() }
            .help("Open Visualizer")
    }
}

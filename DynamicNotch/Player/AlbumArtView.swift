//
//  AlbumArtView.swift
//  DynamicNotch
//
//  The album cover in the open player; clicking it opens the music app.
//

import AVKit
import Combine
import Defaults
import SwiftUI

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var coordinator = NotchCoordinator.shared
    let albumArtNamespace: Namespace.ID

    /// False while the closed cover is still growing into this one on an open.
    @State private var takenOver = false

    var body: some View {
        // The closed cover morphs to and from this one solid on top of it. Hide this copy while
        // it does, so it can't show round the edges (squared corners on an open, a blurred
        // glow on a close). It leaves 0.35 s into an open, when this copy has settled.
        albumArtButton
            .opacity(takenOver && !(vm.notchState == .closed && closedCoverShows) ? 1 : 0)
            .transaction { $0.animation = nil }
            .onAppear {
                guard closedCoverShows else { takenOver = true; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { takenOver = true }
            }
    }

    /// The closed notch shows the cover (same test as `NotchView`'s closed layout).
    private var closedCoverShows: Bool {
        (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                albumArtImage
            }
            .buttonStyle(PlainButtonStyle())
            // Shrink to 85% when paused by padding, not scaleEffect, so the cover's real frame
            // shrinks too and the closed cover morphs to and from the size you see.
            .padding(musicManager.isPlaying ? 0 : MusicPlayerImageSizes.size.opened.width * 0.075)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.displayedAlbumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                AlbumArtShape(openRadius: Defaults[.cornerRadiusScaling]
                    ? MusicPlayerImageSizes.cornerRadiusInset.opened
                    : MusicPlayerImageSizes.cornerRadiusInset.closed)
            )
    }
}

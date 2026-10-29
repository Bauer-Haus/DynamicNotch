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
    let albumArtNamespace: Namespace.ID

    var body: some View {
        albumArtButton
            .hiddenWhileClosedNotchCovers(vm)
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
                AlbumArtShape()
            )
    }
}

/// The closed notch's cover and waveform morph to and from the open player's, drawn solid on
/// top. This hides the open player's copy while that happens, so it can't show round the
/// edges (squared corners on an open, a blurred glow on a close). On an open it appears
/// 0.35 s in, when it has settled and the closed copy starts to fade.
private struct HiddenWhileClosedNotchCovers: ViewModifier {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var coordinator = NotchCoordinator.shared
    @State private var takenOver = false

    func body(content: Content) -> some View {
        content
            .opacity(takenOver && !(vm.notchState == .closed && closedNotchShowsPlayer) ? 1 : 0)
            .transaction { $0.animation = nil }
            .onAppear {
                guard closedNotchShowsPlayer else { takenOver = true; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { takenOver = true }
            }
    }

    /// Same test as `NotchView`'s closed layout.
    private var closedNotchShowsPlayer: Bool {
        (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
    }
}

extension View {
    func hiddenWhileClosedNotchCovers(_ vm: NotchViewModel) -> some View {
        modifier(HiddenWhileClosedNotchCovers(vm: vm))
    }
}

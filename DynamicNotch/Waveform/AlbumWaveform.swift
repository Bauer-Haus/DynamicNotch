//
//  AlbumWaveform.swift
//  DynamicNotch
//
//  The waveform with the blurred album art showing through its bars.
//

import Defaults
import SwiftUI

/// The live waveform with the blurred album art showing through its bars, as on the
/// iPhone. Used in the closed notch and in the open player.
struct AlbumWaveform: View {
    @ObservedObject var musicManager = MusicManager.shared
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if Defaults[.coloredSpectrogram], let backdrop = musicManager.visualizerBackdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Color.gray.gradient)
            }
        }
        // Fills the size it's given (`width` x `height` unless a transition morphs it), so it
        // grows and shrinks with the notch instead of swapping sizes at the end.
        .frame(minWidth: 0, idealWidth: width, maxWidth: .infinity,
               minHeight: 0, idealHeight: height, maxHeight: .infinity)
        .mask {
            AudioSpectrumView(isPlaying: $musicManager.isPlaying, bundleID: musicManager.bundleIdentifier)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

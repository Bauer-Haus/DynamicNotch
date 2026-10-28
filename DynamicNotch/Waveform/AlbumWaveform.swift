//
import AVKit
import Combine
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
        .frame(width: width, height: height)
        .mask {
            AudioSpectrumView(isPlaying: $musicManager.isPlaying, bundleID: musicManager.bundleIdentifier)
                .frame(width: width, height: height)
        }
    }
}

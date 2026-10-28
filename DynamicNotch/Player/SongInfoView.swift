//
import AVKit
import Combine
import Defaults
import SwiftUI

/// Title, artist and (if on) the current lyric line, beside the cover.
struct SongInfoView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.enableLyrics) private var enableLyrics

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    $musicManager.songTitle,
                    font: .system(size: OpenPlayer.textSize, weight: .semibold), nsFont: .title2,
                    textColor: .white, frameWidth: width, lineHeight: OpenPlayer.textLineHeight)
                MarqueeText(
                    $musicManager.artistName,
                    font: .system(size: OpenPlayer.textSize), nsFont: .title2,
                    textColor: .gray, frameWidth: width, lineHeight: OpenPlayer.textLineHeight)
                if enableLyrics {
                    // Only timed lyrics change during a song; otherwise nothing needs redrawing.
                    TimelineView(.animation(minimumInterval: 0.25, paused: !musicManager.isPlaying || musicManager.syncedLyrics.isEmpty)) { timeline in
                        let currentElapsed: Double = {
                            guard musicManager.isPlaying else { return musicManager.elapsedTime }
                            let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                            let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                            return min(max(progressed, 0), musicManager.songDuration)
                        }()
                        let line: String = {
                            if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                            if !musicManager.syncedLyrics.isEmpty {
                                return musicManager.lyricLine(at: currentElapsed)
                            }
                            let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                        }()
                        let isPersian = line.unicodeScalars.contains { scalar in
                            let v = scalar.value
                            return v >= 0x0600 && v <= 0x06FF
                        }
                        MarqueeText(
                            .constant(line),
                            font: .subheadline,
                            nsFont: .subheadline,
                            textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                            frameWidth: width
                        )
                        .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                        .lineLimit(1)
                        .opacity(musicManager.isPlaying ? 1 : 0)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            // Apple sets the song low beside the art, the artist's baseline near its bottom.
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

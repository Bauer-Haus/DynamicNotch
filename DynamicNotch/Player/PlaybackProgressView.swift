//
//  PlaybackProgressView.swift
//  DynamicNotch
//
//  Elapsed time, progress bar and time remaining.
//

import AVKit
import Combine
import Defaults
import SwiftUI

/// Elapsed time, a full-width progress bar and the time remaining, like the iPhone.
struct PlaybackProgressView: View {
    @ObservedObject var musicManager = MusicManager.shared
    /// Starts at the song's position, not 0:00, so the times don't jump as the player opens.
    @State private var sliderValue: Double = MusicManager.shared.estimatedPlaybackPosition()
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        // The bar moves ~1 pt per second and the labels show whole seconds, so twice a
        // second is enough; nothing redraws while paused.
        TimelineView(.animation(minimumInterval: 0.5, paused: !musicManager.isPlaying || musicManager.playbackRate == 0)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
        }
        .frame(height: OpenPlayer.progressHeight)
    }
}

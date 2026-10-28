//
//  MusicControlsView.swift
//  DynamicNotch
//
//  The row of media buttons (previous, play/pause, next and any extras chosen in Settings).
//

import AVKit
import Combine
import Defaults
import SwiftUI

/// The row of controls across the open notch (the buttons are chosen in Settings).
struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        let slots = Self.shownSlots(slotConfig, limit: slotLimit)
        let cell = Self.cellWidth(count: slots.count)
        // Each control in an equal cell, centred: Apple's spacing for three, closer for more.
        HStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                slotView(for: slot)
                    .frame(minWidth: cell, maxWidth: slot == .volume ? nil : cell)
            }
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(PlainButtonStyle())
    }

    /// The controls to show: the chosen slots, up to the limit, leaving out empty ones.
    static func shownSlots(_ config: [MusicControlButton], limit: Int) -> [MusicControlButton] {
        let limit = min(max(limit, MusicControlButton.minSlotCount), MusicControlButton.maxSlotCount)
        return config.prefix(limit).filter { $0 != .none }
    }

    /// Width of each control's cell: Apple's pitch, or less when more controls must fit.
    static func cellWidth(count: Int) -> CGFloat {
        let room = OpenPlayer.islandWidth - 2 * OpenPlayer.sideInset
        return min(OpenPlayer.controlPitch, room / CGFloat(max(count, 1)))
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .systemAccent : .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", iconColor: .white, scale: .large, pointSize: slot.pointSize) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .output:
            OutputPickerButton(size: slot.pointSize)
        case .none:
            EmptyView()
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .white
        case .all, .one:
            return .systemAccent
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium,
                    pointSize: MusicControlButton.favorite.pointSize) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "star.fill" : "star"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .systemAccent : .gray
    }
}

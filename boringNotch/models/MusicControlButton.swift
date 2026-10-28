//
//  MusicControlButton.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-16.
//

import CoreGraphics
import Defaults

enum MusicControlButton: String, CaseIterable, Identifiable, Codable, Defaults.Serializable {
    case shuffle
    case previous
    case playPause
    case next
    case repeatMode
    case volume
    case favorite
    case goBackward
    case goForward
    case output
    case none

    var id: String { rawValue }

    /// The iPhone's expanded Dynamic Island: favourite, back, play/pause, forward, output.
    static let defaultLayout: [MusicControlButton] = [
        .favorite,
        .previous,
        .playPause,
        .next,
        .output
    ]

    static let minSlotCount: Int = 3
    static let maxSlotCount: Int = 5

    static let pickerOptions: [MusicControlButton] = [
        .shuffle,
        .previous,
        .playPause,
        .next,
        .repeatMode,
        .favorite,
        .volume,
        .goBackward,
        .goForward,
        .output
    ]

    var label: String {
        switch self {
        case .shuffle:
            return "Shuffle"
        case .previous:
            return "Previous"
        case .playPause:
            return "Play/Pause"
        case .next:
            return "Next"
        case .repeatMode:
            return "Repeat"
        case .volume:
            return "Volume"
        case .favorite:
            return "Favorite"
        case .goBackward:
            return "Backward 15s"
        case .goForward:
            return "Forward 15s"
        case .output:
            return "Output (AirPlay)"
        case .none:
            return "Empty slot"
        }
    }

    var iconName: String {
        switch self {
        case .shuffle:
            return "shuffle"
        case .previous:
            return "backward.fill"
        case .playPause:
            return "playpause"
        case .next:
            return "forward.fill"
        case .repeatMode:
            return "repeat"
        case .volume:
            return "speaker.wave.2.fill"
        case .favorite:
            return "star"
        case .goBackward:
            return "gobackward.15"
        case .goForward:
            return "goforward.15"
        case .output:
            return "airplay.audio"
        case .none:
            return ""
        }
    }

    var prefersLargeScale: Bool {
        self == .playPause
    }

    /// Icon size in the open notch, matching the iPhone's controls.
    var pointSize: CGFloat {
        switch self {
        case .playPause: return 54
        case .previous, .next: return 40
        case .favorite: return 34
        case .output: return 32
        default: return 30
        }
    }
}

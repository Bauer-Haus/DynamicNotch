//
//  MusicControlButton.swift
//  DynamicNotch
//
//  Every media button that can go in the control row, with its icon and size.
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

    /// Apple's MacBook Dynamic Island: back, play/pause, forward, with the outer two of the
    /// five slots empty. (The iPhone also shows ☆ and AirPlay there; drag them in to add them.)
    static let defaultLayout: [MusicControlButton] = [
        .none,
        .previous,
        .playPause,
        .next,
        .none
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

    /// Icon size in the open notch. Play/pause and skip match Apple's MacBook island (glyphs
    /// 27.6 pt and 27.6 x 16.2 pt tall); the others keep the iPhone's sizes relative to skip.
    var pointSize: CGFloat {
        switch self {
        case .playPause: return 34
        case .previous, .next: return 21.3
        case .favorite: return 18
        case .output: return 17
        default: return 16
        }
    }
}

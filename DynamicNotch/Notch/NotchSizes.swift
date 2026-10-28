//
//  NotchSizes.swift
//  DynamicNotch
//
//  Every size in the notch: Apple-measured open player dimensions and the closed notch size
//  for each screen.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)

/// The open player, matched to Apple's own MacBook Dynamic Island. Measured from Apple's
/// picture of it on the same wallpaper as a screenshot of this app, scaled so the wallpaper's
/// stripes line up (1.198, matched three ways): an island 285 x 152 pt. Distances below the
/// camera are from the top of the album art, which sits just under the camera housing.
enum OpenPlayer {
    static let islandWidth: CGFloat = 285
    /// Island edge to the art, the times and the controls.
    static let sideInset: CGFloat = 16
    static let artSize: CGFloat = 50
    static let artCornerRadius: CGFloat = 10
    static let artToText: CGFloat = 9
    /// Title and artist; Apple's capitals are 10.2 pt tall.
    static let textSize: CGFloat = 13.5
    /// Title to artist, capital to capital.
    static let textLineHeight: CGFloat = 16.7
    /// The live waveform beside the title. Apple's bars are 1.8 pt wide on a 2.9 pt pitch,
    /// which at our bars' proportions is a 17.2 pt full height, the six spanning 16.2 pt.
    /// Centred 25.1 pt below the art's top and 28.3 pt in from the island's right edge.
    static let waveformSize = CGSize(width: 24.6, height: 17.2)
    static let waveformTop: CGFloat = 16.5
    /// The progress row: its bar's centre is 19.8 pt below the art.
    static let progressHeight: CGFloat = 16
    static let progressTop: CGFloat = 10.9
    static let timeSize: CGFloat = 10.5
    static let timeToBar: CGFloat = 5.4
    static let barThickness: CGFloat = 5.3
    static let barDrop: CGFloat = 3.7
    /// The controls' centres are 105.6 pt below the top of the art.
    static let controlsTop: CGFloat = 9.9
    /// Centre to centre: Apple's three controls are 75.3 pt apart. More share the width.
    static let controlPitch: CGFloat = 75.3
    /// Art top to the island's bottom edge: 136.4 pt.
    static let bottomInset: CGFloat = 12
    static let bottomCornerRadius: CGFloat = 36
    /// The press circle behind a control (the iPhone's, sized to these controls).
    static let pressCircle: CGFloat = 50
    /// The open island's shadow (fitted to the iPhone's).
    static let shadowRadius: CGFloat = 19.2
}

/// Where the notch meets the top of the screen its corners curve like the hardware notch's
/// own corners: ~8 pt, measured from a photo of a 14" MacBook Pro (8.0 and 8.7 pt by two
/// methods). Closed and open, so the corners don't change size as the notch opens.
let notchTopCornerRadius: CGFloat = 8

/// Apple's island plus the top corners on each side; 32 pt for the camera housing, then 136.4 pt.
let openNotchSize: CGSize = .init(width: OpenPlayer.islandWidth + 2 * notchTopCornerRadius, height: 168)
/// Room around the open island for its shadow, which fades out by ~40 pt below it (fitted to the
/// iPhone's), with some to spare so it fades out completely (measured on screen).
let islandShadowMargin: CGFloat = 60
/// The window is the open island plus room for its shadow. What's outside the island is
/// see-through and passes clicks through.
let windowSize: CGSize = .init(width: openNotchSize.width + 2 * islandShadowMargin, height: openNotchSize.height + islandShadowMargin)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: notchTopCornerRadius, bottom: OpenPlayer.bottomCornerRadius), closed: (top: notchTopCornerRadius, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: OpenPlayer.artCornerRadius, closed: 4.0)
    static let size = (opened: CGSize(width: OpenPlayer.artSize, height: OpenPlayer.artSize), closed: CGSize(width: 20, height: 20))
}

/// The screen the notch is on: the one with this UUID, or the main screen if none is given.
/// (A UUID that matches no connected screen gives nil, not the main screen.)
@MainActor func notchScreen(_ screenUUID: String?) -> NSScreen? {
    guard let uuid = screenUUID else { return NSScreen.main }
    return NSScreen.screen(withUUID: uuid)
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    notchScreen(screenUUID)?.frame
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    if let screen = notchScreen(screenUUID) {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}

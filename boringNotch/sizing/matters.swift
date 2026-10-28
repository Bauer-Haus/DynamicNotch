//
//  sizeMatters.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)

let shadowPadding: CGFloat = 20
/// The open player's sizes are the iPhone's expanded Dynamic Island (measured, about 2:1)
/// times this. 1.0 matched the iPhone's look on a desktop monitor but felt big next to
/// macOS's 13-17 pt interface text and covered ~38% of a 14" MacBook screen.
let openPlayerScale: CGFloat = 0.8

/// Where the notch meets the top of the screen its corners curve like the hardware notch's
/// own corners: ~8 pt, measured from a photo of a 14" MacBook Pro (8.0 and 8.7 pt by two
/// methods). Closed and open, so the corners don't change size as the notch opens.
let notchTopCornerRadius: CGFloat = 8

/// 540 x 266 pt at full scale, plus the top corners on each side.
let openNotchSize: CGSize = .init(width: 540 * openPlayerScale + 2 * notchTopCornerRadius, height: 266 * openPlayerScale)
let windowSize: CGSize = .init(width: openNotchSize.width, height: openNotchSize.height + shadowPadding)
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: notchTopCornerRadius, bottom: 52 * openPlayerScale), closed: (top: notchTopCornerRadius, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 17 * openPlayerScale, closed: 4.0)
    static let size = (opened: CGSize(width: 86 * openPlayerScale, height: 86 * openPlayerScale), closed: CGSize(width: 20, height: 20))
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

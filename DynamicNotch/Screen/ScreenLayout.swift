//
//  ScreenLayout.swift
//  DynamicNotch
//
//  The connected screens as plain values, to tell whether the layout really changed.
//

import AppKit

/// Which screens are connected and where. Saved as values: NSScreen objects kept from an
/// earlier layout can describe a display that has gone (a new ID after waking from sleep),
/// or change underneath the comparison, so comparing against them was unreliable.
struct ScreenLayout: Equatable {
    struct Screen: Hashable {
        let uuid: String?
        let x, y, width, height: CGFloat
    }

    let screens: Set<Screen>
    let count: Int

    init(_ screens: [Screen]) {
        self.screens = Set(screens)
        count = screens.count
    }

    @MainActor static var current: ScreenLayout {
        ScreenLayout(NSScreen.screens.map { screen in
            let f = screen.frame
            return Screen(uuid: screen.displayUUID, x: f.minX, y: f.minY, width: f.width, height: f.height)
        })
    }
}

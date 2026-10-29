//
//  Color+AccentColor.swift
//  DynamicNotch
//
//  The Mac's accent colour.
//

import SwiftUI

extension Color {
    /// The accent colour picked in System Settings > Appearance (not the app's own accent
    /// colour). Used where Apple Music uses its red: shuffle and repeat when on, favourites.
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
}

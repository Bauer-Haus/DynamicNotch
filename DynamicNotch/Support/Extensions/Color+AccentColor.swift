//
//  Color+AccentColor.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-24.
//

import SwiftUI
import Defaults

extension Color {
    /// The accent colour picked in System Settings > Appearance (not the app's own accent
    /// colour). Used where Apple Music uses its red: shuffle and repeat when on, favourites.
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }

    static var effectiveAccent: Color {
        if let nsColor = NSColor.customAccent {
            return Color(nsColor: nsColor)
        }
        // Explicitly the Mac's accent colour, like NSColor.effectiveAccent (the app's own
        // AccentColor asset is empty, which falls back to the same colour anyway).
        return .systemAccent
    }
    
    /// Returns a darker version of the accent color suitable for backgrounds
    static var effectiveAccentBackground: Color {
        if let nsColor = NSColor.customAccent {
            return Color(nsColor: nsColor.withSystemEffect(.disabled))
        }
        return Color.effectiveAccent.opacity(0.25)
    }
}

extension NSColor {
    /// The custom accent colour saved in this app's Settings, whether or not it is on.
    static var savedCustomAccent: NSColor? {
        guard let data = Defaults[.customAccentColorData] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    /// The custom accent colour, if one is turned on in Settings.
    static var customAccent: NSColor? {
        Defaults[.useCustomAccentColor] ? savedCustomAccent : nil
    }

    static var effectiveAccent: NSColor {
        if let nsColor = NSColor.customAccent {
            return nsColor
        }
        return NSColor.controlAccentColor
    }
    
    /// Returns a darker version of the accent color as NSColor suitable for backgrounds
    static var effectiveAccentBackground: NSColor {
        if let nsColor = NSColor.customAccent {
            return nsColor.withSystemEffect(.disabled)
        }
        return NSColor.controlAccentColor.withAlphaComponent(0.25)
    }
}

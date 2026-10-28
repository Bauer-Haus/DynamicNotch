//
//  AppIcons.swift
//  DynamicNotch
//
//  App icons by bundle ID, cached.
//

import SwiftUI
import AppKit

/// App icons by bundle id. Looking an app up through LaunchServices on every view update
/// is wasteful; icons don't change while the app runs.
private let appIconCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 16
    return cache
}()

func AppIconAsNSImage(for bundleID: String) -> NSImage? {
    if let cached = appIconCache.object(forKey: bundleID as NSString) {
        return cached
    }
    let workspace = NSWorkspace.shared
    guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let appIcon = workspace.icon(forFile: appURL.path)
    appIcon.size = NSSize(width: 256, height: 256)
    appIconCache.setObject(appIcon, forKey: bundleID as NSString)
    return appIcon
}

func AppIcon(for bundleID: String) -> Image {
    Image(nsImage: AppIconAsNSImage(for: bundleID) ?? NSWorkspace.shared.icon(for: .applicationBundle))
}

//
//  NSScreen+UUID.swift
//  DynamicNotch
//
//  Finds screens by their stable display ID.
//

import AppKit
import CoreGraphics

extension NSScreen {
    /// The display's Core Graphics ID, if that display is still online.
    ///
    /// An NSScreen kept from before a reconfiguration (waking from sleep gives the built-in
    /// display a new ID) still reports its old ID; asking Core Graphics about it logged
    /// "Invalid display" and returned nothing useful. Such a screen reports nil here.
    var onlineDisplayID: CGDirectDisplayID? {
        Self.onlineDisplayID(
            screenNumber: deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            online: Self.onlineDisplayIDs())
    }

    /// A screen's display ID if it's among the `online` ones.
    static func onlineDisplayID(screenNumber: NSNumber?, online: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        guard let screenNumber else { return nil }
        let id = CGDirectDisplayID(screenNumber.uint32Value)
        return online.contains(id) ? id : nil
    }

    /// Returns a persistent UUID for this display (nil for a display that's gone).
    var displayUUID: String? {
        Self.displayUUID(for: onlineDisplayID)
    }

    /// The UUID string of an online display.
    static func displayUUID(for displayID: CGDirectDisplayID?) -> String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// The connected screen with this UUID.
    ///
    /// Looked up afresh each time rather than from a cache: the cache was rebuilt on the same
    /// screen-change notification other code reacts to, so whichever ran first could get the
    /// screens from before the change (and position the notch from a stale frame).
    @MainActor static func screen(withUUID uuid: String) -> NSScreen? {
        screens.first { $0.displayUUID == uuid }
    }

    /// UUID to NSScreen mapping for all connected screens.
    @MainActor static var screensByUUID: [String: NSScreen] {
        var result: [String: NSScreen] = [:]
        for screen in screens {
            if let uuid = screen.displayUUID { result[uuid] = screen }
        }
        return result
    }
}

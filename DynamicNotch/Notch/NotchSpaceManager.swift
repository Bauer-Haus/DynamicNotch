//
//  NotchSpaceManager.swift
//  DynamicNotch
//
//  A private macOS Space above all others that holds the notch windows, so they show over
//  full-screen apps.
//

import Foundation

class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {
        notchSpace = CGSSpace(level: 2147483647) // Max level
    }
}

//
//  Logger.swift
//  DynamicNotch
//
//  The app's unified-log categories.
//

import Foundation
import os

extension os.Logger {
    /// A logger under the app's subsystem, e.g. `.app("waveform")`.
    static func app(_ category: String) -> os.Logger {
        os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: category)
    }
}

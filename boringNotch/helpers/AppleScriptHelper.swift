//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

class AppleScriptHelper {
    /// NSAppleScript isn't thread-safe, so every script runs on this one queue.
    private static let queue = DispatchQueue(label: "boringNotch.appleScript", qos: .userInitiated)
    /// Compiled scripts keyed by source. Compiling is the slow part and the same few
    /// scripts (player info, play/pause, ...) run on every update.
    private static let compiled: NSCache<NSString, NSAppleScript> = {
        let cache = NSCache<NSString, NSAppleScript>()
        cache.countLimit = 64
        return cache
    }()

    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let key = scriptText as NSString
                var error: NSDictionary?
                let script: NSAppleScript
                if let cached = compiled.object(forKey: key) {
                    script = cached
                } else if let fresh = NSAppleScript(source: scriptText), fresh.compileAndReturnError(&error) {
                    compiled.setObject(fresh, forKey: key)
                    script = fresh
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleScriptError", code: 1,
                        userInfo: error as? [String: Any] ?? [NSLocalizedDescriptionKey: "Could not compile script"]))
                    return
                }

                // Swift imports the result as non-optional; a failure is reported via `error`.
                let descriptor = script.executeAndReturnError(&error)
                if error == nil {
                    continuation.resume(returning: descriptor)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleScriptError", code: 1,
                        userInfo: error as? [String: Any] ?? [NSLocalizedDescriptionKey: "Unknown error"]))
                }
            }
        }
    }

    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}

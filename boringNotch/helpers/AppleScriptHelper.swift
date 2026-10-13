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

    /// Wraps a script so the Apple Events it sends give up after `seconds`. Without it, a
    /// hung Music or Spotify would block this serial queue and every later script.
    static func withTimeout(_ scriptText: String, seconds: Int) -> String {
        "with timeout of \(seconds) seconds\n\(scriptText)\nend timeout"
    }

    /// Runs a script, giving up after `timeout` seconds (default 10).
    @discardableResult
    class func execute(_ scriptText: String, timeout: Int = 10) async throws -> NSAppleEventDescriptor? {
        let source = withTimeout(scriptText, seconds: timeout)
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            // Backstop in case the script itself doesn't return (the queue stays busy, but
            // the caller isn't left waiting).
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout + 2)) {
                if once.claim() {
                    continuation.resume(throwing: NSError(
                        domain: "AppleScriptError", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Script timed out"]))
                }
            }
            queue.async {
                let key = source as NSString
                var error: NSDictionary?
                let script: NSAppleScript
                if let cached = compiled.object(forKey: key) {
                    script = cached
                } else if let fresh = NSAppleScript(source: source), fresh.compileAndReturnError(&error) {
                    compiled.setObject(fresh, forKey: key)
                    script = fresh
                } else {
                    if once.claim() {
                        continuation.resume(throwing: NSError(
                            domain: "AppleScriptError", code: 1,
                            userInfo: error as? [String: Any] ?? [NSLocalizedDescriptionKey: "Could not compile script"]))
                    }
                    return
                }

                // Swift imports the result as non-optional; a failure is reported via `error`.
                let descriptor = script.executeAndReturnError(&error)
                guard once.claim() else { return }
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

/// Lets exactly one of several racing callbacks resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

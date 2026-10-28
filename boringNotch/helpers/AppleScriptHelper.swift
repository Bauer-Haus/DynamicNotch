//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit

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

/// The AppleScript the app sends to Music and Spotify, kept in one place so every media
/// source sends exactly the same commands (a copy of the favourite script once broke
/// while the other kept working).
enum PlayerScript {
    static let musicBundleID = "com.apple.Music"
    static let spotifyBundleID = "com.spotify.client"

    /// The scripting name of an app whose volume can be controlled, if any.
    static func appName(forVolumeOf bundleID: String) -> String? {
        switch bundleID {
        case musicBundleID: return "Music"
        case spotifyBundleID: return "Spotify"
        default: return nil
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Volume as the whole percent the players take, dropping the fraction (45.7% -> 45).
    /// The notch's click confirmation compares against this, so both must use it.
    static func volumePercent(_ level: Double) -> Int {
        Int(max(0, min(1, level)) * 100)
    }

    static func setVolume(_ level: Double, app: String) -> String {
        "tell application \"\(app)\" to set sound volume to \(volumePercent(level))"
    }

    /// Returns the volume in percent, or 50 if the app isn't running.
    static func getVolume(app: String) -> String {
        """
        tell application "\(app)"
            if it is running then
                get sound volume
            else
                return 50
            end if
        end tell
        """
    }

    static func setMusicFavorite(_ favorite: Bool) -> String {
        """
        tell application "Music"
            try
                set favorited of current track to \(favorite ? "true" : "false")
            end try
        end tell
        """
    }

    static let getMusicFavorite = """
        tell application "Music"
            try
                return favorited of current track
            on error
                return false
            end try
        end tell
        """
}

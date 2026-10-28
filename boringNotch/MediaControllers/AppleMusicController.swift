//
//  AppleMusicController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class AppleMusicController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.apple.Music",
        playbackRate: 1
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool {
        return true
    }

    private var notificationTask: Task<Void, Never>?
    /// Artwork is only fetched when the track changes; it can be megabytes per transfer.
    private var artworkTrackID: String?
    private var artworkData: Data?
    private var artworkRetryTask: Task<Void, Never>?

    // MARK: - Initialization
    init() {
        setupPlaybackStateChangeObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async {
        await executeCommand("play")
    }
    
    func pause() async {
        await executeCommand("pause")
    }
    
    func togglePlay() async {
        await executeCommand("playpause")
    }
    
    func nextTrack() async {
        await executeCommand("next track")
    }
    
    func previousTrack() async {
        await executeCommand("previous track")
    }
    
    func seek(to time: Double) async {
        await executeCommand("set player position to \(time)")
        await updatePlaybackInfo()
    }
    
    func toggleShuffle() async {
        await executeCommand("set shuffle enabled to not shuffle enabled")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func toggleRepeat() async {
        await executeCommand("""
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func setVolume(_ level: Double) async {
        // The notch already shows the new level; a full status query after every step of a
        // slider drag only queued up behind other commands.
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
    }
    
    func isActive() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func setFavorite(_ favorite: Bool) async {
        let script = """
        tell application \"Music\"
            try
                set favorited of current track to \(favorite ? "true" : "false")
            end try
        end tell
        """
        try? await AppleScriptHelper.executeVoid(script)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    /// One status query at a time, plus at most one waiting: each takes ~100 ms and only the
    /// newest answer matters, so a burst of requests no longer stacks up ahead of commands.
    private let updateLock = NSLock()
    private var updateRunning = false
    private var updateRequested = false

    func updatePlaybackInfo() async {
        guard startUpdate() else { return }
        repeat {
            await performPlaybackInfoUpdate()
        } while runUpdateAgain()
    }

    /// True if this call should run the query; false if one is running (it will run again).
    private func startUpdate() -> Bool {
        updateLock.withLock {
            if updateRunning {
                updateRequested = true
                return false
            }
            updateRunning = true
            return true
        }
    }

    /// True if another request came in while the query ran.
    private func runUpdateAgain() -> Bool {
        updateLock.withLock {
            if updateRequested {
                updateRequested = false
                return true
            }
            updateRunning = false
            return false
        }
    }

    private func performPlaybackInfoUpdate() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 11 else { return }
        var updatedState = self.playbackState
        
        updatedState.isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        updatedState.title = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        updatedState.artist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        updatedState.album = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        updatedState.currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        updatedState.duration = descriptor.atIndex(6)?.doubleValue ?? 0
        updatedState.isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let repeatModeValue = descriptor.atIndex(8)?.int32Value ?? 0
        updatedState.repeatMode = RepeatMode(rawValue: Int(repeatModeValue)) ?? .off
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        updatedState.volume = Double(volumePercentage) / 100.0
        let trackID = descriptor.atIndex(10)?.stringValue ?? ""
        if trackID != artworkTrackID {
            artworkTrackID = trackID
            artworkRetryTask?.cancel()
            let previous = artworkData
            let fresh = trackID.isEmpty ? nil : await fetchArtwork(title: updatedState.title)
            if let fresh, fresh != previous {
                artworkData = fresh
            } else if !trackID.isEmpty {
                // On stations Music still has the previous song's artwork (or none) when the
                // track changes. Keep showing what we have and look again until it updates.
                retryArtwork(for: trackID, title: updatedState.title, previous: previous, latest: fresh)
            } else {
                artworkData = nil
            }
        }
        updatedState.artwork = artworkData
        let lovedState = descriptor.atIndex(11)?.booleanValue ?? false
        updatedState.isFavorite = lovedState
        updatedState.lastUpdated = Date()
        self.playbackState = updatedState
    }
    
    // MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        let script = "tell application \"Music\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Music"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffle enabled
                set repeatState to song repeat
                if repeatState is off then
                    set repeatValue to 1
                else if repeatState is one then
                    set repeatValue to 2
                else if repeatState is all then
                    set repeatValue to 3
                end if

                set trackID to persistent ID of current track
                set currentVolume to sound volume
                set favoriteState to favorited of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, currentVolume, trackID, favoriteState}
            on error
                return {false, "Not Playing", "Unknown", "Unknown", 0, 0, false, 0, 50, "", false}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }

    /// Delays before each new look at a station track's artwork (about 8 s in all).
    static let artworkRetryDelays: [Double] = [0.5, 1, 1.5, 2, 3]

    private func retryArtwork(for trackID: String, title: String, previous: Data?, latest: Data?) {
        artworkRetryTask = Task { [weak self] in
            var latest = latest
            for delay in Self.artworkRetryDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.artworkTrackID == trackID else { return }
                latest = await self.fetchArtwork(title: title)
                if let latest, latest != previous {
                    self.publishArtwork(latest)
                    return
                }
            }
            // Never changed: consecutive songs from the same album really share artwork.
            guard let self, !Task.isCancelled, self.artworkTrackID == trackID else { return }
            self.publishArtwork(latest)
        }
    }

    private func publishArtwork(_ data: Data?) {
        artworkData = data
        var state = playbackState
        state.artwork = data
        state.lastUpdated = Date()
        playbackState = state
    }

    /// The current track's artwork. Station (radio) tracks have none in Music's scripting
    /// interface, so for those it comes from macOS's Now Playing info instead.
    private func fetchArtwork(title: String) async -> Data? {
        if let data = await scriptArtwork() { return data }
        return await Self.nowPlayingArtwork(title: title)
    }

    private func scriptArtwork() async -> Data? {
        let script = """
        tell application "Music"
            try
                return data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        """
        guard let data = try? await AppleScriptHelper.execute(script)?.data, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - Now Playing artwork (stations)

    /// Asks macOS's Now Playing info for Music's artwork, through the same helper the Now
    /// Playing source uses. Only accepted if it belongs to `title`, so a cover that hasn't
    /// caught up with a song change is never shown for the wrong song.
    static func nowPlayingArtwork(title: String) async -> Data? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = [script.path, framework, "get"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Never wait on a stuck helper for long.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { process.terminate() }
                }
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: artwork(fromNowPlayingJSON: output, title: title))
            }
        }
    }

    /// Music's artwork from the Now Playing helper's `get` output, if it is for `title`.
    static func artwork(fromNowPlayingJSON data: Data, title: String) -> Data? {
        guard let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              info["bundleIdentifier"] as? String == "com.apple.Music",
              info["title"] as? String == title,
              let encoded = info["artworkData"] as? String,
              let artwork = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              !artwork.isEmpty
        else { return nil }
        return artwork
    }
}

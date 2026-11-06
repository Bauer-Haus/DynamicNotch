//
//  AppleMusicController.swift
//  DynamicNotch
//
//  Music source for Apple Music, through AppleScript.
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
        try? await AppleScriptHelper.executeVoid(PlayerScript.setVolume(level, app: "Music"))
    }
    
    func isActive() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func setFavorite(_ favorite: Bool) async {
        try? await AppleScriptHelper.executeVoid(PlayerScript.setMusicFavorite(favorite))
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
        let previousAlbum = self.playbackState.album
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
        let isStation = descriptor.atIndex(12)?.booleanValue ?? false
        if trackID != artworkTrackID {
            artworkTrackID = trackID
            artworkRetryTask?.cancel()
            let previous = artworkData
            let song = Song(title: updatedState.title, artist: updatedState.artist, album: updatedState.album)
            let sameAlbum = Self.isSameAlbum(song.album, previousAlbum)
            let fresh = trackID.isEmpty ? nil : await fetchArtwork(title: song.title, isStation: isStation)
            if let fresh, Self.accepts(fresh, previous: previous, sameAlbum: sameAlbum) {
                artworkData = fresh
            } else if !trackID.isEmpty {
                // Music often has the previous song's artwork (or none) when the track changes.
                // Only an album's next song may keep it; for any other, show none (the notch
                // keeps the old cover a moment, then the app icon) rather than the wrong one,
                // and look again until the right one comes.
                if !sameAlbum { artworkData = nil }
                retryArtwork(for: trackID, song: song, isStation: isStation, previous: previous, sameAlbum: sameAlbum)
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
                set isStation to (class of current track) is URL track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, currentVolume, trackID, favoriteState, isStation}
            on error
                return {false, "Not Playing", "Unknown", "Unknown", 0, 0, false, 0, 50, "", false, false}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }

    /// Delays before each new look at a song's artwork when it isn't there yet (about 8 s in all).
    static let artworkRetryDelays: [Double] = [0.5, 1, 1.5, 2, 3]
    /// The same for a station's song: Now Playing can take 15-30 s to get its cover.
    static let stationArtworkRetryDelays: [Double] = artworkRetryDelays + [4, 5, 6, 8]
    /// After this many looks without it, ask Apple's catalog too.
    static let catalogAfterTries = 2

    struct Song: Equatable {
        var title: String
        var artist: String
        var album: String
    }

    /// Whether two songs are from the same album, so the same cover is right for both.
    static func isSameAlbum(_ album: String, _ previous: String) -> Bool {
        let unknown: Set<String> = ["", "Unknown", "Self Love"]
        return !unknown.contains(album) && album == previous
    }

    /// Whether `art` can be the new song's cover: a different one from before, or the same
    /// one when the song is from the same album.
    static func accepts(_ art: Data, previous: Data?, sameAlbum: Bool) -> Bool {
        art != previous || sameAlbum
    }

    private func retryArtwork(for trackID: String, song: Song, isStation: Bool, previous: Data?, sameAlbum: Bool) {
        artworkRetryTask = Task { [weak self] in
            var latest: Data?
            let delays = isStation ? Self.stationArtworkRetryDelays : Self.artworkRetryDelays
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.artworkTrackID == trackID else { return }
                latest = await self.fetchArtwork(title: song.title, isStation: isStation)
                if let art = latest, Self.accepts(art, previous: previous, sameAlbum: sameAlbum) {
                    self.publishArtwork(art)
                    return
                }
                if index + 1 == Self.catalogAfterTries,
                   let art = await CatalogArtwork.fetch(title: song.title, artist: song.artist, album: song.album) {
                    guard !Task.isCancelled, self.artworkTrackID == trackID else { return }
                    self.publishArtwork(art)
                    return
                }
            }
            guard let self, !Task.isCancelled, self.artworkTrackID == trackID else { return }
            // The album's next song really can share the cover; any other gets none rather
            // than the last song's.
            if sameAlbum { self.publishArtwork(latest ?? previous) }
        }
    }

    private func publishArtwork(_ data: Data?) {
        artworkData = data
        var state = playbackState
        state.artwork = data
        state.lastUpdated = Date()
        playbackState = state
    }

    /// The current track's artwork. macOS's Now Playing info comes first: it is checked against
    /// the song's title, and it is what Control Center shows. Music's scripting interface can
    /// still hold another song's cover, or none, for songs streamed from Apple Music. On a
    /// station it keeps the previous song's cover after the song changes, and as a different
    /// file from Now Playing's, so it can't be told apart: stations never use it.
    private func fetchArtwork(title: String, isStation: Bool) async -> Data? {
        if let data = await Self.nowPlayingArtwork(title: title) { return data }
        if isStation { return nil }
        return await scriptArtwork()
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

    // MARK: - Scripted artwork (for the Now Playing source)

    /// Music's artwork for the current track from its scripting interface, if that track is
    /// `title`. Never launches Music.
    static func scriptArtwork(forTitle title: String) async -> Data? {
        guard PlayerScript.isRunning(PlayerScript.musicBundleID) else { return nil }
        let script = """
        tell application "Music"
            try
                return {name of current track, data of artwork 1 of current track}
            on error
                return {"", ""}
            end try
        end tell
        """
        guard let result = try? await AppleScriptHelper.execute(script) else { return nil }
        return artwork(fromScriptResult: result, title: title)
    }

    /// The artwork in a `{name, artwork data}` script result, if the name is `title`.
    static func artwork(fromScriptResult result: NSAppleEventDescriptor, title: String) -> Data? {
        guard result.numberOfItems >= 2,
              result.atIndex(1)?.stringValue == title,
              let data = result.atIndex(2)?.data, !data.isEmpty,
              result.atIndex(2)?.descriptorType != typeUnicodeText
        else { return nil }
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

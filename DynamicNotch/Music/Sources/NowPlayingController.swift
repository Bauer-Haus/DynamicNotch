//
//  NowPlayingController.swift
//  DynamicNotch
//
//  Music source for any app, read from macOS's Now Playing info through the bundled helper.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "com.apple.Music"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == PlayerScript.musicBundleID, PlayerScript.isRunning(bundleID) {
            try? await AppleScriptHelper.executeVoid(PlayerScript.setMusicFavorite(favorite))
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    /// Music sometimes gives Now Playing a song with no artwork (seen with Apple-made
    /// playlists), so the previous song's stays or the app icon shows. Then the cover is asked
    /// for in Music itself, and failing that in Apple's catalog (`CatalogArtwork`).
    private var artworkFallbackTrack: String?
    private var artworkFallbackTask: Task<Void, Never>?
    /// Waits before each look: the art often follows the title by a moment by itself.
    static let artworkFallbackDelays: [Double] = [1, 1, 1.5, 2, 3]

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?
    /// Wait before restarting the helper after it exits; doubles on each quick failure.
    private var restartDelay: TimeInterval = 0.5
    static let maxRestartDelay: TimeInterval = 30

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }
    }

    deinit {
        streamTask?.cancel()
        
        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close()
            }
        }
        
        if let process = self.process {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote can't set an app's volume, so script the playing app directly.
        let bundleID = playbackState.bundleIdentifier
        if let app = PlayerScript.appName(forVolumeOf: bundleID), PlayerScript.isRunning(bundleID) {
            try? await AppleScriptHelper.executeVoid(PlayerScript.setVolume(level, app: app))
        }
        playbackState.volume = max(0, min(1, level))
    }
    
    // MARK: - Setup Methods
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]
        
        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        
        self.process = process
        self.pipeHandler = pipeHandler

        let started = Date()
        do {
            try process.run()
        } catch {
            print("[NowPlaying] Failed to launch mediaremote-adapter.pl: \(error)")
            await helperExited(ranFor: 0)
            return
        }
        // Holds self only weakly (per update), so the controller can be released, which
        // cancels this task and stops the helper.
        streamTask = Task { [weak self, pipeHandler] in
            await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
                await self?.handleAdapterUpdate(update)
            }
            // The stream only ends when the helper exits (crashed, killed, ...).
            guard !Task.isCancelled else { return }
            await self?.helperExited(ranFor: Date().timeIntervalSince(started))
        }
    }

    /// Restarts the helper so song info keeps coming. A helper that ran for a while gets a
    /// quick restart; one that keeps failing backs off up to `maxRestartDelay`.
    private func helperExited(ranFor seconds: TimeInterval) async {
        restartDelay = Self.nextRestartDelay(after: restartDelay, ranFor: seconds)
        print("[NowPlaying] Helper stopped after \(Int(seconds)) s; restarting in \(Int(restartDelay)) s")
        try? await Task.sleep(for: .seconds(restartDelay))
        guard !Task.isCancelled else { return }
        if let process, process.isRunning { process.terminate() }
        await pipeHandler?.close()
        await setupNowPlayingObserver()
    }

    static func nextRestartDelay(after current: TimeInterval, ranFor seconds: TimeInterval) -> TimeInterval {
        seconds > 60 ? 1 : min(max(1, current * 2), maxRestartDelay)
    }

    // MARK: - Update Methods
    /// Formatters are expensive to create; the adapter sends an update on every change.
    private static let timestampFormatter = ISO8601DateFormatter()

    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        
        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)
        
        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        
        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newPlaybackState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if diff {
            // A partial update without artwork leaves it unchanged.
            newPlaybackState.artwork = self.playbackState.artwork
        }

        if let dateString = payload.timestamp,
           let date = Self.timestampFormatter.date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        
        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)

        ArtworkLog.log.debug("NowPlaying diff=\(diff) title=\(newPlaybackState.title, privacy: .public) sent=\(ArtworkLog.id(payload.artworkData.flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }), privacy: .public) state=\(ArtworkLog.id(newPlaybackState.artwork), privacy: .public)")
        updateArtworkFallback(for: newPlaybackState, artworkArrived: payload.artworkData != nil)
        self.playbackState = newPlaybackState
        
        // Fetch favorite state for supported apps asynchronously
        // await fetchFavoriteStateIfSupported()
    }
    
    /// On a new Music song that came without artwork, look for it in Music itself; stop
    /// looking once Now Playing sends some.
    private func updateArtworkFallback(for state: PlaybackState, artworkArrived: Bool) {
        let track = Self.trackKey(state)
        guard track != artworkFallbackTrack else {
            if artworkArrived { artworkFallbackTask?.cancel() }
            return
        }
        artworkFallbackTrack = track
        artworkFallbackTask?.cancel()
        guard Self.needsArtworkFallback(state, artworkArrived: artworkArrived) else { return }

        // What's showing now: the previous song's cover, or none.
        let stale = state.artwork
        let (title, artist, album) = (state.title, state.artist, state.album)
        artworkFallbackTask = Task { [weak self] in
            for delay in Self.artworkFallbackDelays {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self?.artworkFallbackTrack == track else { return }
                var found = await AppleMusicController.scriptArtwork(forTitle: title)
                // Same as before: an album's next song, or Music hasn't caught up yet.
                if found == stale { found = nil }
                if found == nil {
                    found = await CatalogArtwork.fetch(title: title, artist: artist, album: album)
                }
                guard let art = found else { continue }
                guard let self, !Task.isCancelled, self.artworkFallbackTrack == track else { return }
                ArtworkLog.log.debug("Fallback found \(ArtworkLog.id(art), privacy: .public) for \(title, privacy: .public)")
                var updated = self.playbackState
                updated.artwork = art
                self.playbackState = updated
                return
            }
        }
    }

    static func trackKey(_ state: PlaybackState) -> String {
        [state.bundleIdentifier, state.title, state.artist, state.album].joined(separator: "\u{1F}")
    }

    /// Only Music can be asked, and only a song with no fresh artwork needs it.
    static func needsArtworkFallback(_ state: PlaybackState, artworkArrived: Bool) -> Bool {
        state.bundleIdentifier == PlayerScript.musicBundleID && !state.title.isEmpty && !artworkArrived
    }

     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == PlayerScript.musicBundleID {
             guard PlayerScript.isRunning(bundleID) else { return }
             if let result = try? await AppleScriptHelper.execute(PlayerScript.getMusicFavorite) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

actor JSONLinesPipeHandler {
    private let pipe: Pipe
    private let fileHandle: FileHandle
    /// Bytes received but not yet terminated by a newline. Lines carrying artwork are
    /// hundreds of KB, so lines are split on raw bytes, scanning only the new data.
    private var buffer = Data()
    private let decoder = JSONDecoder()
    
    init() {
        self.pipe = Pipe()
        self.fileHandle = pipe.fileHandleForReading
    }
    
    func getPipe() -> Pipe {
        return pipe
    }
    
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            try await self.processLines(as: type) { decodedObject in
                await onLine(decodedObject)
            }
        } catch {
            print("Error processing JSON stream: \(error)")
        }
    }
    
    private func processLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async throws {
        let newline = UInt8(ascii: "\n")
        while true {
            let data = try await readData()
            guard !data.isEmpty else { break }

            var searchFrom = buffer.count
            buffer.append(data)
            var lineStart = buffer.startIndex
            while let end = buffer[(buffer.startIndex + searchFrom)...].firstIndex(of: newline) {
                let line = buffer[lineStart ..< end]
                if !line.isEmpty, let decoded = try? decoder.decode(T.self, from: Data(line)) {
                    await onLine(decoded)
                }
                lineStart = end + 1
                searchFrom = lineStart - buffer.startIndex
            }
            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex ..< lineStart)
            }
        }
    }

    private func readData() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
    
    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("Error closing pipe handler: \(error)")
        }
    }
}

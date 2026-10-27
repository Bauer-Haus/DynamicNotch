//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

@MainActor
class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    /// Blurred album art the visualizer bars show through (nil until the first art loads).
    @Published var visualizerBackdrop: NSImage?
    /// Brightness added to the album art so very dark covers stay visible (0 for most).
    @Published var albumArtLift: CGFloat = 0
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil
    /// Shows the app icon if a new track's artwork doesn't arrive within `artworkWait`.
    private var appIconFallback: Task<Void, Never>?
    nonisolated static let artworkWait: TimeInterval = 1.5

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Turning lyrics on fetches them for the song that's already playing.
        Defaults.publisher(.enableLyrics, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Before anything has played the title is a placeholder, not a real song.
                guard let self, self.bundleIdentifier != nil else { return }
                self.fetchLyricsIfAvailable(bundleIdentifier: self.bundleIdentifier, title: self.songTitle, artist: self.artistName, duration: self.songDuration, force: true)
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    // No deinit: `shared` lives as long as the app, and its subscriptions cancel themselves
    // if it is ever released. `destroy()` is for tearing down explicitly.
    public func destroy() {
        debounceIdleTask?.cancel()
        lyricsTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                appIconFallback?.cancel()
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // A new track's artwork often arrives a moment after its title (stations take
                // ~0.1-0.5 s). Keep the current art briefly; use the app icon only if none comes.
                appIconFallback?.cancel()
                let bundleID = state.bundleIdentifier
                appIconFallback = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.artworkWait))
                    guard let self, !Task.isCancelled, self.artworkData == nil,
                          let appIconImage = AppIconAsNSImage(for: bundleID) else { return }
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist, duration: state.duration)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
        guard !runningApps.isEmpty else { return }

        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private var lyricsTask: Task<Void, Never>?
    /// Title + artist the current lyrics belong to, so artwork-only updates don't refetch.
    private var lyricsKey: String?

    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String, duration: Double, force: Bool = false) {
        guard Defaults[.enableLyrics], !title.isEmpty else {
            lyricsTask?.cancel()
            lyricsKey = nil
            DispatchQueue.main.async {
                self.isFetchingLyrics = false
                self.currentLyrics = ""
                self.syncedLyrics = []
            }
            return
        }

        let key = title + "\u{1F}" + artist
        guard force || key != lyricsKey else { return }
        lyricsKey = key
        lyricsTask?.cancel()

        lyricsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isFetchingLyrics = true
            self.currentLyrics = ""
            self.syncedLyrics = []

            // Time-synced lyrics show the line being sung, so they win. Apple Music's own
            // lyrics have no timing and are only used when the web has no synced version.
            let web = await Self.webLyrics(title: title, artist: artist, duration: duration)
            var plain = web.plain
            if web.synced.isEmpty, bundleIdentifier?.contains("com.apple.Music") == true,
               !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty {
                let native = await Self.appleMusicLyrics()
                if !native.isEmpty { plain = native }
            }

            // A newer track may have started while we were waiting.
            guard !Task.isCancelled, self.lyricsKey == key else { return }
            self.syncedLyrics = web.synced
            self.currentLyrics = plain
            self.isFetchingLyrics = false
        }
    }

    nonisolated private static func appleMusicLyrics() async -> String {
        let script = """
        tell application "Music"
            try
                set l to lyrics of current track
                if l is missing value then return ""
                return l
            on error
                return ""
            end try
        end tell
        """
        let result = try? await AppleScriptHelper.execute(script)
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated private static func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    /// Looks the track up on LRCLIB (free, no account). Picks the result whose length
    /// matches the playing track, preferring one with timed lines.
    nonisolated private static func webLyrics(title: String, artist: String, duration: Double) async -> (plain: String, synced: [(time: Double, text: String)]) {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        // URLQueryItem encodes "&", "+" and "#" in titles, which plain percent-encoding misses.
        components.queryItems = [
            URLQueryItem(name: "track_name", value: normalizedQuery(title)),
            URLQueryItem(name: "artist_name", value: normalizedQuery(artist)),
        ]
        guard let url = components.url else { return ("", []) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("boringNotch (https://github.com/Bauer-Haus/boring.notch)", forHTTPHeaderField: "User-Agent")

        // LRCLIB is sometimes briefly overloaded (503) or rate-limits (429): try once more.
        for attempt in 0 ..< 2 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard !Task.isCancelled else { return ("", []) }
            let reply = try? await URLSession.shared.data(for: request)
            let status = (reply?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let data = reply?.0 {
                return lyrics(fromSearchResults: data, duration: duration)
            }
            guard Self.isWorthRetrying(status: status) else { break }
        }
        return ("", [])
    }

    /// No reply (network error, timeout), rate limiting or a server error.
    nonisolated static func isWorthRetrying(status: Int) -> Bool {
        status == 0 || status == 429 || (500 ..< 600).contains(status)
    }

    /// Picks the LRCLIB search result whose length matches the playing track, preferring
    /// one with timed lines, and returns its plain and timed lyrics.
    nonisolated static func lyrics(fromSearchResults data: Data, duration: Double) -> (plain: String, synced: [(time: Double, text: String)]) {
        guard let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !results.isEmpty
        else { return ("", []) }

        func lengthMatches(_ item: [String: Any]) -> Bool {
            guard duration > 0, let d = item["duration"] as? Double else { return true }
            return abs(d - duration) <= 3
        }
        func hasSynced(_ item: [String: Any]) -> Bool {
            !((item["syncedLyrics"] as? String) ?? "").isEmpty
        }
        let candidates = results.filter(lengthMatches)
        guard let best = candidates.first(where: hasSynced) ?? candidates.first ?? results.first else { return ("", []) }

        if best["instrumental"] as? Bool == true {
            return ("♪ Instrumental", [])
        }
        let plain = ((best["plainLyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let synced = parseLRC((best["syncedLyrics"] as? String) ?? "")
        return (plain.isEmpty ? synced.map(\.text).joined(separator: "\n") : plain, synced)
    }

    // MARK: - Synced lyrics helpers
    /// Matches one LRC timestamp: [m:ss], [mm:ss.xx] or [mm:ss.xxx].
    nonisolated private static let lrcTimestamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

    nonisolated static func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(time: Double, text: String)] = []
        for lineSub in lrc.split(whereSeparator: \.isNewline) {
            let nsLine = String(lineSub) as NSString
            // A line can carry several timestamps when it repeats ("[00:12.00][01:30.00]text").
            let matches = lrcTimestamp.matches(in: nsLine as String, range: NSRange(location: 0, length: nsLine.length))
            guard let last = matches.last else { continue }
            let text = nsLine.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fracRange = match.range(at: 3)
                // ".5" is half a second and ".05" five hundredths, so read it as a decimal.
                let fraction = fracRange.location != NSNotFound ? Double("0." + nsLine.substring(with: fracRange)) ?? 0 : 0
                result.append((minutes * 60 + seconds + fraction, text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        return Self.line(in: syncedLyrics, at: elapsed)
    }

    /// The line being sung at `elapsed`: the last one starting at or before it (the first
    /// line before the song reaches it). `lines` must be sorted by time and not empty.
    nonisolated static func line(in lines: [(time: Double, text: String)], at elapsed: Double) -> String {
        var low = 0
        var high = lines.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return lines[idx].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Album art is drawn well under 256 pt even in the open notch; a 512 px copy is plenty.
            if let artworkImage = NSImage.thumbnail(from: artworkData, maxPixelSize: 512) ?? NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if usesAverageColor {
                self.calculateAverageColor()
            }
        }
        newAlbumArt.visualizerBackdrop { [weak self] image, luminance in
            guard let self, self.albumArt === newAlbumArt else { return }
            withAnimation(.smooth) {
                self.visualizerBackdrop = image
                self.albumArtLift = NSImage.darkArtLift(averageLuminance: luminance)
            }
        }
    }

    /// The album-art colour tints the visualizer, the player text and optionally the slider.
    private var usesAverageColor: Bool {
        Defaults[.coloredSpectrogram] || Defaults[.sliderColor] == .albumArt
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                await self?.activeController?.updatePlaybackInfo()
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        // Check if bundle identifier is valid and if the app is actually running
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty,
              NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = """
            tell application "Music"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else if bundleID == "com.spotify.client" {
            script = """
            tell application "Spotify"
                if it is running then
                    get sound volume
                else
                    return 50
                end if
            end tell
            """
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}

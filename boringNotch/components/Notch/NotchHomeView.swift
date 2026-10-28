//
//  NotchHomeView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-18.
//  Modified by Harsh Vardhan Goswami & Richard Kunkli & Mustafa Ramadan
//

import AVKit
import Combine
import Defaults
import SwiftUI

// MARK: - Music Player Components

struct MusicPlayerView: View {
    @EnvironmentObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        // Laid out like the iPhone's expanded Dynamic Island: cover, song and live waveform
        // on top, a full-width progress bar, then a full-width row of controls.
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                AlbumArtView(vm: vm, albumArtNamespace: albumArtNamespace)
                    .frame(width: MusicPlayerImageSizes.size.opened.width,
                           height: MusicPlayerImageSizes.size.opened.height)
                SongInfoView()
                    .padding(.leading, 27 * openPlayerScale)
                    .drawingGroup()
                    .compositingGroup()
                AlbumWaveform(width: 35 * openPlayerScale, height: 28 * openPlayerScale)
                    .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.leading, 12 * openPlayerScale)
            }
            .frame(height: MusicPlayerImageSizes.size.opened.height)

            PlaybackProgressView()
                .padding(.top, 26 * openPlayerScale)

            MusicControlsView()
                .padding(.top, 18 * openPlayerScale)
        }
    }
}

/// The live waveform with the blurred album art showing through its bars, as on the
/// iPhone. Used in the closed notch and in the open player.
struct AlbumWaveform: View {
    @ObservedObject var musicManager = MusicManager.shared
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if Defaults[.coloredSpectrogram], let backdrop = musicManager.visualizerBackdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(Color.gray.gradient)
            }
        }
        .frame(width: width, height: height)
        .mask {
            AudioSpectrumView(isPlaying: $musicManager.isPlaying, bundleID: musicManager.bundleIdentifier)
                .frame(width: width, height: height)
        }
    }
}

struct AlbumArtView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var vm: BoringViewModel
    let albumArtNamespace: Namespace.ID

    var body: some View {
        albumArtButton
    }

    private var albumArtButton: some View {
        ZStack {
            Button {
                musicManager.openMusicApp()
            } label: {
                albumArtImage
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(musicManager.isPlaying ? 1 : 0.85)
            
            albumArtDarkOverlay
        }
    }

    private var albumArtDarkOverlay: some View {
        Rectangle()
            .aspectRatio(1, contentMode: .fit)
            .foregroundColor(Color.black)
            .opacity(musicManager.isPlaying ? 0 : 0.8)
            .blur(radius: 50)
    }
                

    private var albumArtImage: some View {
        Image(nsImage: musicManager.displayedAlbumArt)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .clipped()
            .clipShape(
                RoundedRectangle(
                    cornerRadius: Defaults[.cornerRadiusScaling]
                        ? MusicPlayerImageSizes.cornerRadiusInset.opened
                        : MusicPlayerImageSizes.cornerRadiusInset.closed,
                    style: .continuous)
            )
    }
}

/// Title, artist and (if on) the current lyric line, beside the cover.
struct SongInfoView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.enableLyrics) private var enableLyrics

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    $musicManager.songTitle,
                    font: .system(size: 24 * openPlayerScale, weight: .semibold), nsFont: .title2,
                    textColor: .white, frameWidth: width)
                MarqueeText(
                    $musicManager.artistName,
                    font: .system(size: 24 * openPlayerScale), nsFont: .title2,
                    textColor: .gray, frameWidth: width)
                if enableLyrics {
                    // Only timed lyrics change during a song; otherwise nothing needs redrawing.
                    TimelineView(.animation(minimumInterval: 0.25, paused: !musicManager.isPlaying || musicManager.syncedLyrics.isEmpty)) { timeline in
                        let currentElapsed: Double = {
                            guard musicManager.isPlaying else { return musicManager.elapsedTime }
                            let delta = timeline.date.timeIntervalSince(musicManager.timestampDate)
                            let progressed = musicManager.elapsedTime + (delta * musicManager.playbackRate)
                            return min(max(progressed, 0), musicManager.songDuration)
                        }()
                        let line: String = {
                            if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                            if !musicManager.syncedLyrics.isEmpty {
                                return musicManager.lyricLine(at: currentElapsed)
                            }
                            let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                            return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                        }()
                        let isPersian = line.unicodeScalars.contains { scalar in
                            let v = scalar.value
                            return v >= 0x0600 && v <= 0x06FF
                        }
                        MarqueeText(
                            .constant(line),
                            font: .subheadline,
                            nsFont: .subheadline,
                            textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                            frameWidth: width
                        )
                        .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                        .lineLimit(1)
                        .opacity(musicManager.isPlaying ? 1 : 0)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Elapsed time, a full-width progress bar and the time remaining, like the iPhone.
struct PlaybackProgressView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast

    var body: some View {
        // The bar moves ~1 pt per second and the labels show whole seconds, so twice a
        // second is enough; nothing redraws while paused.
        TimelineView(.animation(minimumInterval: 0.5, paused: !musicManager.isPlaying || musicManager.playbackRate == 0)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
        }
        .frame(height: 20 * openPlayerScale)
    }
}

/// The row of controls across the open notch (the buttons are chosen in Settings).
struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        let slots = activeSlots
        HStack(spacing: 0) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                if index > 0 { Spacer(minLength: 0) }
                slotView(for: slot)
            }
        }
        .padding(.horizontal, 15 * openPlayerScale)
        .buttonStyle(PlainButtonStyle())
    }

    private var activeSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        return Self.fillingEmptySlots(Array(padded.prefix(sanitizedLimit)))
    }

    /// Empty slots show the iPhone's button for that position (☆ on the left, AirPlay on
    /// the right) unless it is already in another slot.
    static func fillingEmptySlots(_ slots: [MusicControlButton]) -> [MusicControlButton] {
        let defaults = MusicControlButton.defaultLayout
        var result = slots
        for (i, slot) in slots.enumerated() where slot == .none {
            // Match from the nearer end, so a shorter row still gets ☆ first and AirPlay last.
            let fromEnd = slots.count - 1 - i
            let candidate = i <= fromEnd
                ? defaults[min(i, defaults.count - 1)]
                : defaults[max(0, defaults.count - 1 - fromEnd)]
            if candidate != .none, !result.contains(candidate) { result[i] = candidate }
        }
        return result
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .systemAccent : .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.toggleShuffle()
            }
        case .previous:
            HoverButton(icon: "backward.fill", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", iconColor: .white, scale: .large, pointSize: slot.pointSize) {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.toggleRepeat()
            }
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.skip(seconds: -15)
            }
        case .goForward:
            HoverButton(icon: "goforward.15", iconColor: .white, scale: .medium, pointSize: slot.pointSize) {
                MusicManager.shared.skip(seconds: 15)
            }
        case .output:
            OutputPickerButton(size: slot.pointSize)
        case .none:
            Color.clear.frame(width: 44, height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .white
        case .all, .one:
            return .systemAccent
        }
    }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium,
                    pointSize: MusicControlButton.favorite.pointSize) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "star.fill" : "star"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .systemAccent : .gray
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}

// MARK: - Volume Control View

struct VolumeControlView: View {
    @ObservedObject var musicManager = MusicManager.shared
    @State private var volumeSliderValue: Double = 0.5
    @State private var dragging: Bool = false
    @State private var showVolumeSlider: Bool = false
    @State private var lastVolumeUpdateTime: Date = Date.distantPast
    private let volumeUpdateThrottle: TimeInterval = 0.1
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                if musicManager.volumeControlSupported {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        showVolumeSlider.toggle()
                    }
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(musicManager.volumeControlSupported ? .white : .gray)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!musicManager.volumeControlSupported)
            .frame(width: 24)

            if showVolumeSlider && musicManager.volumeControlSupported {
                CustomSlider(
                    value: $volumeSliderValue,
                    range: 0.0...1.0,
                    color: .white,
                    dragging: $dragging,
                    lastDragged: .constant(Date.distantPast),
                    onValueChange: { newValue in
                        MusicManager.shared.setVolume(to: newValue)
                    },
                    onDragChange: { newValue in
                        let now = Date()
                        if now.timeIntervalSince(lastVolumeUpdateTime) > volumeUpdateThrottle {
                            MusicManager.shared.setVolume(to: newValue)
                            lastVolumeUpdateTime = now
                        }
                    }
                )
                .frame(width: 48, height: 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .clipped()
        .onReceive(musicManager.$volume) { volume in
            if !dragging {
                volumeSliderValue = volume
            }
        }
        .onReceive(musicManager.$volumeControlSupported) { supported in
            if !supported {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showVolumeSlider = false
                }
            }
        }
        .onChange(of: showVolumeSlider) { _, isShowing in
            if isShowing {
                // Sync volume from app when slider appears
                Task {
                    await MusicManager.shared.syncVolumeFromActiveApp()
                }
            }
        }
        .onDisappear {
            // volumeUpdateTask?.cancel() // No longer needed
        }
    }
    
    
    private var volumeIcon: String {
        if !musicManager.volumeControlSupported {
            return "speaker.slash"
        } else if volumeSliderValue == 0 {
            return "speaker.slash.fill"
        } else if volumeSliderValue < 0.33 {
            return "speaker.1.fill"
        } else if volumeSliderValue < 0.66 {
            return "speaker.2.fill"
        } else {
            return "speaker.3.fill"
        }
    }
}

// MARK: - Main View

struct NotchHomeView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    let albumArtNamespace: Namespace.ID

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed ? 30 : 0)
    }
}

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var onValueChange: (Double) -> Void


    var body: some View {
        HStack(spacing: 11 * openPlayerScale) {
            Text(timeString(from: sliderValue))
                .monospacedDigit()
            CustomSlider(
                value: $sliderValue,
                range: 0...duration,
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange,
                thickness: 8 * openPlayerScale
            )
            // Time left, as on the iPhone (-3:49).
            Text("−" + timeString(from: max(0, duration - sliderValue)))
                .monospacedDigit()
        }
        .font(.system(size: 15 * openPlayerScale, weight: .medium))
        .foregroundColor(.gray)
        .onChange(of: currentDate) {
           guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition(at: currentDate)
        }
        // The timeline is paused while music is paused; still follow seeks and track changes.
        .onChange(of: elapsedTime) {
            guard !dragging, timestampDate.timeIntervalSince(lastDragged) > -1 else { return }
            sliderValue = MusicManager.shared.estimatedPlaybackPosition()
        }
    }

    func timeString(from seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    /// Bar thickness at rest; it grows by 4 pt while dragged.
    var thickness: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = dragging ? thickness + 4 : thickness
            let rangeSpan = range.upperBound - range.lowerBound

            let progress = rangeSpan == .zero ? 0 : (value - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: thickness + 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation {
                            dragging = true
                        }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: dragging)
        }
    }
}

/// The output picker (AirPlay, speakers, headphones). macOS's picker draws a small fixed-size
/// icon, so this shows an iPhone-sized icon and presses the (nearly invisible) picker behind it,
/// which opens macOS's own output menu.
struct OutputPickerButton: View {
    let size: CGFloat
    @State private var holder = RoutePickerHolder()

    var body: some View {
        HoverButton(icon: "airplay.audio", iconColor: .gray, scale: .medium, pointSize: size) {
            holder.open()
        }
        .background(
            RoutePickerHost(picker: holder.picker)
                .frame(width: size, height: size)
                .opacity(0.02)
        )
    }
}

final class RoutePickerHolder {
    let picker: AVRoutePickerView = {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }()

    /// Presses the picker's own button, which shows the output menu below it.
    func open() {
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            for sub in view.subviews { if let found = button(in: sub) { return found } }
            return nil
        }
        button(in: picker)?.performClick(nil)
    }
}

private struct RoutePickerHost: NSViewRepresentable {
    let picker: AVRoutePickerView
    func makeNSView(context: Context) -> AVRoutePickerView { picker }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

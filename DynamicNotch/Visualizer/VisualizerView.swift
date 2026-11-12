//
//  VisualizerView.swift
//  DynamicNotch
//
//  The full-screen visualizer's content: the Metal scene, with the song and controls
//  floating over it while the pointer moves.
//

import Combine
import Defaults
import MetalKit
import SwiftUI

@MainActor
final class VisualizerModel: ObservableObject {
    let renderer: VisualizerRenderer
    weak var metalView: MTKView?

    @Published var showsArtwork: Bool {
        didSet {
            renderer.showsArtwork = showsArtwork
            Defaults[.visualizerShowsArtwork] = showsArtwork
        }
    }
    @Published var speakerLayout: SpeakerLayout {
        didSet {
            renderer.speakerLayout = speakerLayout
            Defaults[.visualizerSpeakers] = speakerLayout.rawValue
        }
    }
    @Published private(set) var controlsVisible = true
    var isHoveringControls = false

    static let controlsHideDelay: TimeInterval = 2.5
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init?() {
        guard let renderer = VisualizerRenderer(device: MTLCreateSystemDefaultDevice()) else { return nil }
        self.renderer = renderer
        self.showsArtwork = Defaults[.visualizerShowsArtwork]
        self.speakerLayout = SpeakerLayout(rawValue: Defaults[.visualizerSpeakers]) ?? .stereo
        renderer.showsArtwork = showsArtwork
        renderer.speakerLayout = speakerLayout

        let music = MusicManager.shared
        music.$albumArt
            .removeDuplicates { $0 === $1 }
            .sink { [weak renderer] art in renderer?.setArtwork(art) }
            .store(in: &cancellables)
        music.$isPlaying
            .sink { [weak renderer] playing in renderer?.isPlaying = playing }
            .store(in: &cancellables)
        // Show the new song's name for a moment.
        music.$songTitle
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.showControls() }
            .store(in: &cancellables)
        showControls()
    }

    func showControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = true }
        }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.controlsHideDelay))
            guard let self, !Task.isCancelled else { return }
            if self.isHoveringControls {
                self.showControls()
                return
            }
            withAnimation(.easeInOut(duration: 0.6)) { self.controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    func cycleSpeakerLayout() {
        let all = SpeakerLayout.allCases
        speakerLayout = all[(speakerLayout.rawValue + 1) % all.count]
        showControls()
    }

    func toggleArtwork() {
        showsArtwork.toggle()
        showControls()
    }

    func setPaused(_ paused: Bool) {
        metalView?.isPaused = paused
    }
}

struct VisualizerView: View {
    @ObservedObject var model: VisualizerModel
    @ObservedObject var musicManager = MusicManager.shared
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                MetalHost(model: model)

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    songPanel
                        .padding(.bottom, max(40, geo.size.height * 0.07))
                }
                .padding(20)
                .opacity(model.controlsVisible ? 1 : 0)
                .allowsHitTesting(model.controlsVisible)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .onContinuousHover { _ in model.showControls() }
        .onTapGesture(count: 2) { onClose() }
        .onTapGesture { model.showControls() }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            GlassIconButton(icon: "xmark", help: "Close (Esc)", action: onClose)

            Spacer()

            speakerPicker

            GlassIconButton(icon: model.showsArtwork ? "photo.fill" : "photo",
                            help: model.showsArtwork ? "Hide Album Art (A)" : "Show Album Art (A)") {
                model.toggleArtwork()
            }
        }
        .onHover { model.isHoveringControls = $0 }
    }

    /// Off / 2.0 / 2.1 / 5.1 speaker pulses.
    private var speakerPicker: some View {
        HStack(spacing: 2) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 10)
                .padding(.trailing, 4)
            ForEach(SpeakerLayout.allCases) { layout in
                Button {
                    withAnimation(.smooth(duration: 0.25)) { model.speakerLayout = layout }
                    model.showControls()
                } label: {
                    Text(layout.title)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.speakerLayout == layout ? .white : .white.opacity(0.6))
                        .frame(minWidth: 34)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .background {
                            if model.speakerLayout == layout { Capsule().fill(.white.opacity(0.16)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .help("Speaker pulses (S)")
        .padding(.trailing, 8)
    }

    private var songPanel: some View {
        VStack(spacing: 14) {
            VStack(spacing: 3) {
                Text(musicManager.songTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(1)
            .shadow(color: .black.opacity(0.4), radius: 8)

            HStack(spacing: 26) {
                GlassIconButton(icon: "backward.fill", size: 18, help: "Previous (←)") { musicManager.previousTrack() }
                GlassIconButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", size: 24, help: "Play/Pause (Space)") {
                    musicManager.togglePlay()
                }
                GlassIconButton(icon: "forward.fill", size: 18, help: "Next (→)") { musicManager.nextTrack() }
            }
        }
        .frame(maxWidth: 560)
        .onHover { model.isHoveringControls = $0 }
    }

    private var subtitle: String {
        [musicManager.artistName, musicManager.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

private struct GlassIconButton: View {
    let icon: String
    var size: CGFloat = 14
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2.4, height: size * 2.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .scaleEffect(hovering ? 1.06 : 1)
        .onHover { h in withAnimation(.smooth(duration: 0.2)) { hovering = h } }
        .help(help)
    }
}

private struct MetalHost: NSViewRepresentable {
    let model: VisualizerModel

    func makeNSView(context: Context) -> VisualizerMetalView {
        let view = model.renderer.makeView()
        model.metalView = view
        return view
    }

    func updateNSView(_ nsView: VisualizerMetalView, context: Context) {}
}

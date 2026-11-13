//
//  AlbumFlowScreen.swift
//  DynamicNotch
//
//  Album Flow's full-screen content: the covers, the front album's name beneath them, a
//  scroll bar, and the back of a turned-over cover listing its songs.
//

import AppKit
import SwiftUI

struct AlbumFlowScreen: View {
    @ObservedObject var model: AlbumFlowModel
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = AlbumFlowLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                FlowHost(model: model)

                switch model.status {
                case .loading:
                    message {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Reading your Music library…")
                    }
                case .noAccess:
                    message {
                        Image(systemName: "music.note.list").font(.system(size: 44))
                        Text("DynamicNotch needs access to your Music library")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Turn on DynamicNotch in Privacy & Security › Media & Apple Music, then open Album Flow again.")
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                case .empty:
                    message {
                        Image(systemName: "square.stack").font(.system(size: 44))
                        Text("No albums in your Music library yet").font(.system(size: 20, weight: .semibold))
                    }
                case .ready:
                    albumName(layout: layout)
                    if let album = model.flippedAlbum, model.flip > 0.5 {
                        AlbumBack(album: album, model: model)
                            .frame(width: layout.side, height: layout.side)
                            .rotation3DEffect(.degrees(Double(model.flip) * 180 - 180), axis: (0, 1, 0),
                                              perspective: 0.45)
                            .position(x: layout.centre.x, y: geo.size.height - layout.centre.y)
                    }
                    ScrollBar(model: model, position: model.scrollPosition)
                        .frame(width: min(geo.size.width * 0.5, 720), height: 16)
                        .position(x: geo.size.width / 2, y: geo.size.height - max(28, geo.size.height * 0.055))
                }

                GlassButton(icon: "xmark", help: "Close (Esc)", action: onClose)
                    .padding(20)
                    .opacity(model.controlsVisible || model.status != .ready ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: model.controlsVisible)
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private func message<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14, content: content)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The front album's title and artist, under the reflections, as in iTunes.
    @ViewBuilder
    private func albumName(layout: AlbumFlowLayout) -> some View {
        if model.albums.indices.contains(model.centreIndex) {
            let album = model.albums[model.centreIndex]
            let top = layout.size.height - layout.centre.y + layout.side * 0.5 + layout.side * 0.42
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    if model.playingIndex == model.centreIndex {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: max(11, layout.side * 0.04)))
                            .foregroundStyle(Color(white: 0.75))
                            .symbolEffect(.variableColor.iterative, isActive: MusicManager.shared.isPlaying)
                            .help("Playing now")
                    }
                    Text(album.title)
                        .font(.system(size: max(13, layout.side * 0.05), weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(album.artist)
                    .font(.system(size: max(12, layout.side * 0.042)))
                    .foregroundStyle(Color(white: 0.62))
            }
            .lineLimit(1)
            .frame(width: layout.size.width * 0.7)
            .position(x: layout.size.width / 2, y: top)
            .allowsHitTesting(false)
        }
    }
}

/// The back of a turned-over cover: the album's songs. Click one to play from it.
private struct AlbumBack: View {
    let album: LibraryAlbum
    @ObservedObject var model: AlbumFlowModel
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 400
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10 * unit) {
                    VStack(alignment: .leading, spacing: 2 * unit) {
                        Text(album.title)
                            .font(.system(size: 17 * unit, weight: .bold))
                        Text(album.year > 0 ? "\(album.artist) · \(String(album.year))" : album.artist)
                            .font(.system(size: 13 * unit))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        model.play(album, from: 0)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14 * unit, weight: .bold))
                            .frame(width: 34 * unit, height: 34 * unit)
                            .background(Circle().fill(.white.opacity(0.16)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Play Album")
                }
                .padding(.horizontal, 16 * unit)
                .padding(.vertical, 12 * unit)

                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(album.tracks.enumerated()), id: \.offset) { index, track in
                            row(index: index, track: track, unit: unit)
                        }
                    }
                    .padding(.vertical, 4 * unit)
                }
                .scrollIndicators(.never)
            }
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)], startPoint: .top, endPoint: .bottom)
            )
            .overlay(Rectangle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .clipShape(Rectangle())
        }
    }

    private func row(index: Int, track: LibraryTrack, unit: CGFloat) -> some View {
        Button {
            model.play(album, from: index)
        } label: {
            HStack(spacing: 10 * unit) {
                Text(track.number > 0 ? "\(track.number)" : "\(index + 1)")
                    .font(.system(size: 12 * unit).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 22 * unit, alignment: .trailing)
                Text(track.title)
                    .font(.system(size: 13 * unit))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(Self.time(track.duration))
                    .font(.system(size: 12 * unit).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 16 * unit)
            .padding(.vertical, 6 * unit)
            .background(hovered == index ? Color.white.opacity(0.1) : (index.isMultiple(of: 2) ? Color.white.opacity(0.03) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// The scroll bar under the covers: drag it, or click along it, to go anywhere.
private struct ScrollBar: View {
    @ObservedObject var model: AlbumFlowModel
    @ObservedObject var position: AlbumFlowModel.ScrollPosition

    var body: some View {
        GeometryReader { geo in
            let count = max(1, model.albums.count)
            let thumb = max(44, geo.size.width * min(1, 9 / CGFloat(count)))
            let travel = max(1, geo.size.width - thumb)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.72), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(width: thumb)
                    .padding(2)
                    .offset(x: position.fraction * travel)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.scrub(toFraction: (value.location.x - thumb / 2) / travel)
            })
        }
        .opacity(model.albums.count > 1 ? 1 : 0)
    }
}

private struct GlassButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

private struct FlowHost: NSViewRepresentable {
    let model: AlbumFlowModel

    func makeNSView(context: Context) -> AlbumFlowView { AlbumFlowView(model: model) }
    func updateNSView(_ nsView: AlbumFlowView, context: Context) {}
}

//
//  AlbumFlowModel.swift
//  DynamicNotch
//
//  Album Flow's state: the albums, where the flow is (a continuous position that eases
//  towards the album it's headed for), the flipped cover, and the covers loaded so far.
//

import AppKit
import Combine
import os

/// Where each cover sits for a given offset from the centre, in points with the centre
/// cover's middle at the origin, y up. The centre cover faces the viewer; the others stand
/// in two stacks turned 70 degrees to face the middle, their outer edges nearer the viewer.
struct AlbumFlowLayout: Equatable {
    var size: CGSize

    static let sideAngle: CGFloat = 70 * .pi / 180

    /// The covers' side.
    var side: CGFloat { max(60, min(size.height * 0.40, size.width * 0.30)) }
    /// The centre cover's middle, from the view's bottom-left.
    var centre: CGPoint { CGPoint(x: size.width / 2, y: size.height * 0.56) }
    /// From the centre to the first cover of each stack.
    var gap: CGFloat { side * 0.80 }
    /// Between covers in a stack.
    var spacing: CGFloat { side * 0.21 }
    /// How far back the stacks stand.
    var depth: CGFloat { side * 0.60 }
    /// The perspective's viewing distance.
    var eyeDistance: CGFloat { side * 2.6 }
    /// How far the pointer or fingers move to pass one cover.
    var pointsPerAlbum: CGFloat { spacing * 1.5 }

    struct Placement: Equatable {
        var x: CGFloat
        var z: CGFloat
        var angle: CGFloat
    }

    func placement(offset d: CGFloat) -> Placement {
        let a = max(-1, min(1, d))
        return Placement(x: a * gap + (d - a) * spacing, z: -abs(a) * depth, angle: -a * Self.sideAngle)
    }

    /// Covers each side of the centre that can be on screen.
    var reach: Int { Int(((size.width / 2 - gap) / spacing).rounded(.up)) + 3 }

    /// Screen x of a point on a cover (`u` from -0.5, left edge, to 0.5), relative to the
    /// centre, and the scale perspective gives it there.
    func project(offset d: CGFloat, u: CGFloat, extraAngle: CGFloat = 0) -> (x: CGFloat, scale: CGFloat) {
        let p = placement(offset: d)
        let angle = p.angle + extraAngle
        let local = u * side
        let x = p.x + local * cos(angle)
        let z = p.z - local * sin(angle)
        let scale = eyeDistance / (eyeDistance - z)
        return (x * scale, scale)
    }
}

@MainActor
final class AlbumFlowModel: ObservableObject {
    enum Status: Equatable { case loading, ready, empty, noAccess }

    @Published private(set) var status: Status = .loading
    @Published private(set) var albums: [LibraryAlbum] = []
    /// The album at the front.
    @Published private(set) var centreIndex = 0
    /// The front cover flipped over to its track list: 0 front, 1 back.
    @Published private(set) var flip: CGFloat = 0
    @Published private(set) var flippedAlbum: LibraryAlbum?
    @Published var controlsVisible = true

    /// The scroll bar's position, 0...1 (its own object, as it changes every frame).
    let scrollPosition = ScrollPosition()
    final class ScrollPosition: ObservableObject {
        @Published var fraction: CGFloat = 0
    }

    /// Where the flow is, in albums, and where it's headed.
    private(set) var position: CGFloat = 0
    private(set) var target: CGFloat = 0
    private var flipTarget: CGFloat = 0
    /// Covers by album ID; `nil` once loading found none.
    private(set) var covers: [UInt64: CGImage?] = [:]
    private var loadingCovers: Set<UInt64> = []
    var coverPixels = 600
    /// Bumped when a cover arrives, so the view refreshes that one.
    private(set) var coverGeneration = 0

    /// Called when there's something new to draw (the view starts its display link).
    var needsAnimation: (() -> Void)?

    private var typed = ""
    private var typeAheadTime: TimeInterval = 0
    private var snapTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    var isSettled: Bool {
        abs(position - target) < 0.0005 && abs(flip - flipTarget) < 0.001 && loadingCovers.isEmpty
    }

    func load(startingAt playing: (album: String, artist: String)?) {
        status = .loading
        Task {
            do {
                let albums = try await AlbumLibrary.shared.load()
                self.albums = albums
                status = albums.isEmpty ? .empty : .ready
                var start = 0
                if let playing, !playing.album.isEmpty {
                    start = albums.firstIndex { $0.title == playing.album && ($0.artist == playing.artist || $0.tracks.contains { $0.artist == playing.artist }) }
                        ?? albums.firstIndex { $0.title == playing.album }
                        ?? 0
                }
                position = CGFloat(start)
                target = position
                updateCentre()
                needsAnimation?()
            } catch {
                status = .noAccess
            }
        }
    }

    /// Shows `albums` without reading the library (tests).
    func show(_ albums: [LibraryAlbum], covers: [UInt64: CGImage], at index: Int) {
        self.albums = albums
        self.covers = covers.mapValues { .some($0) }
        status = albums.isEmpty ? .empty : .ready
        position = CGFloat(index)
        target = position
        updateCentre()
    }

    /// Jumps straight to `position` (tests).
    func setPosition(_ position: CGFloat) {
        self.position = position
        target = position
        updateCentre()
    }

    // MARK: Moving

    private var lastIndex: CGFloat { CGFloat(max(0, albums.count - 1)) }

    func go(to index: Int) {
        guard !albums.isEmpty else { return }
        unflip()
        target = CGFloat(min(max(0, index), albums.count - 1))
        needsAnimation?()
    }

    func move(by albums: Int) { go(to: Int(target.rounded()) + albums) }

    /// Scrolling or dragging by `delta` albums: follows the fingers, and settles on the
    /// nearest album once they stop.
    func drag(by delta: CGFloat, settleAfter: TimeInterval? = 0.18) {
        guard !albums.isEmpty else { return }
        unflip()
        // Past the ends it gives, like a rubber band.
        var next = target + delta
        if next < 0 { next = target < 0 ? target + delta * 0.3 : next * 0.3 }
        if next > lastIndex { next = target > lastIndex ? target + delta * 0.3 : lastIndex + (next - lastIndex) * 0.3 }
        target = max(-0.6, min(lastIndex + 0.6, next))
        needsAnimation?()
        snapTask?.cancel()
        if let settleAfter {
            snapTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(settleAfter))
                guard let self, !Task.isCancelled else { return }
                self.settle()
            }
        }
    }

    /// Lets go: carries on with `velocity` (albums per second) for a moment, then stops on
    /// an album.
    func settle(velocity: CGFloat = 0) {
        snapTask?.cancel()
        guard !albums.isEmpty else { return }
        let carried = target + max(-40, min(40, velocity * 0.22))
        target = max(0, min(lastIndex, carried.rounded()))
        needsAnimation?()
    }

    func scrub(toFraction fraction: CGFloat) {
        guard !albums.isEmpty else { return }
        unflip()
        target = (max(0, min(1, fraction)) * lastIndex).rounded()
        needsAnimation?()
    }

    /// Typing jumps to the first album by an artist starting with what was typed.
    func typeAhead(_ characters: String) {
        let now = ProcessInfo.processInfo.systemUptime
        typed = now - typeAheadTime > 1.0 ? characters : typed + characters
        typeAheadTime = now
        let prefix = typed.lowercased()
        if let index = albums.firstIndex(where: { AlbumGrouping.sortName($0.artist).lowercased().hasPrefix(prefix) })
            ?? albums.firstIndex(where: { $0.title.lowercased().hasPrefix(prefix) }) {
            go(to: index)
        }
    }

    // MARK: Flipping and playing

    var isFlipped: Bool { flipTarget > 0.5 }

    func toggleFlip() {
        guard albums.indices.contains(centreIndex) else { return }
        if isFlipped { unflip(); return }
        // Only once it has stopped on the album.
        target = target.rounded()
        position = target
        flippedAlbum = albums[centreIndex]
        flipTarget = 1
        needsAnimation?()
    }

    func unflip() {
        guard flipTarget != 0 else { return }
        flipTarget = 0
        needsAnimation?()
    }

    func playCentre(from track: Int = 0) {
        guard albums.indices.contains(centreIndex) else { return }
        AlbumLibrary.shared.play(albums[centreIndex], from: track)
    }

    func play(_ album: LibraryAlbum, from track: Int) {
        AlbumLibrary.shared.play(album, from: track)
    }

    // MARK: Animation

    /// Advances the flow by `dt` seconds.
    func step(dt: CGFloat) {
        // Eases towards the target like Cover Flow: quick to start, gentle to stop.
        let ease = 1 - exp(-dt / 0.11)
        position += (target - position) * ease
        if abs(position - target) < 0.0005 { position = target }
        let flipEase = 1 - exp(-dt / 0.085)
        flip += (flipTarget - flip) * flipEase
        if abs(flip - flipTarget) < 0.001 {
            flip = flipTarget
            if flip == 0 { flippedAlbum = nil }
        }
        updateCentre()
        let fraction = albums.count > 1 ? max(0, min(1, position / lastIndex)) : 0
        if abs(scrollPosition.fraction - fraction) > 0.0001 { scrollPosition.fraction = fraction }
    }

    private func updateCentre() {
        let index = Int(max(0, min(lastIndex, position.rounded())))
        if index != centreIndex { centreIndex = index }
    }

    // MARK: Covers

    func cover(for album: LibraryAlbum) -> CGImage?? { covers[album.id] }

    /// Starts loading the covers of albums `indices`, nearest the centre first, a few at a
    /// time so a fast scroll doesn't queue up hundreds.
    func requestCovers(near indices: ClosedRange<Int>) {
        guard !albums.isEmpty else { return }
        let lo = max(0, indices.lowerBound), hi = min(albums.count - 1, indices.upperBound)
        guard lo <= hi else { return }
        let centre = Int(position.rounded())
        let wanted = (lo ... hi).sorted { abs($0 - centre) < abs($1 - centre) }
        for index in wanted where loadingCovers.count < 4 {
            let album = albums[index]
            guard covers[album.id] == nil, !loadingCovers.contains(album.id) else { continue }
            loadingCovers.insert(album.id)
            let pixels = coverPixels
            Task {
                let image = await AlbumLibrary.shared.cover(for: album, maxPixels: pixels)
                self.loadingCovers.remove(album.id)
                self.covers[album.id] = .some(image)
                self.coverGeneration += 1
                self.needsAnimation?()
            }
        }
    }

    // MARK: Controls

    func showControls() {
        if !controlsVisible { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.controlsVisible = false
        }
    }
}

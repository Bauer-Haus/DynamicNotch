//
//  AlbumFlowView.swift
//  DynamicNotch
//
//  The covers, drawn with Core Animation: the front cover facing you, the rest in two
//  stacks turned 70 degrees towards it, each with its reflection on a black floor. Scroll,
//  swipe or drag to flip through them; click a cover to bring it to the front, click the front one
//  to turn it over to its songs, double-click it to play.
//

import AppKit
import QuartzCore

/// One cover and its reflection.
final class CoverLayer: CALayer {
    let image = CALayer()
    let reflection = CALayer()
    let shade = CALayer()
    var albumID: UInt64 = 0
    var hasCover = false
    private var side: CGFloat = 0

    /// Space between a cover and its reflection, as a share of its side.
    static let reflectionGap: CGFloat = 0.004
    /// How much of the cover the reflection shows (it has faded to black by then).
    static let reflectionShare: CGFloat = 0.6

    override init() {
        super.init()
        allowsEdgeAntialiasing = true
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        // The reflection is one opaque picture, already flipped and faded to black (see
        // `reflectionImage`): fading it with a layer on top let the cover's colour show
        // through as bright lines along its edges.
        reflection.contentsGravity = .resize
        reflection.backgroundColor = NSColor.black.cgColor
        for layer in [image, reflection] {
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
            layer.allowsEdgeAntialiasing = true
            addSublayer(layer)
        }
        shade.backgroundColor = NSColor.black.cgColor
        shade.opacity = 0
        shade.allowsEdgeAntialiasing = true
        addSublayer(shade)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resize(side: CGFloat) {
        guard side != self.side else { return }
        self.side = side
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        image.frame = bounds
        let gap = side * Self.reflectionGap
        let height = side * Self.reflectionShare
        reflection.frame = CGRect(x: 0, y: -gap - height, width: side, height: height)
        shade.frame = CGRect(x: 0, y: -gap - height, width: side, height: side + gap + height)
    }

    func setCover(_ cover: CGImage, reflection reflected: CGImage) {
        image.contents = cover
        reflection.contents = reflected
    }

    /// The floor's reflection of `cover`: its lower part upside down, strongest (40%) where
    /// it meets the cover and black by `fadeShare` of the way down, on black, so a nearer
    /// cover's reflection hides the ones behind it as the covers do.
    static func reflectionImage(of cover: CGImage, fadeShare: CGFloat = 0.92) -> CGImage? {
        let width = cover.width
        let height = max(1, Int(CGFloat(cover.height) * reflectionShare))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Upside down: the cover's bottom row at the top of the reflection.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cover, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(cover.height)))
        ctx.restoreGState()
        let colors = [CGColor(gray: 0, alpha: 0.6), CGColor(gray: 0, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)),
                                   end: CGPoint(x: 0, y: CGFloat(height) * (1 - fadeShare)),
                                   options: [.drawsAfterEndLocation])
        }
        return ctx.makeImage()
    }
}

final class AlbumFlowView: NSView {
    let model: AlbumFlowModel
    private let stage = CALayer()
    private var coverLayers: [Int: CoverLayer] = [:]
    private var albumCount = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private(set) var layoutInfo = AlbumFlowLayout(size: .zero)

    // Dragging.
    private var dragStart: NSPoint?
    private var lastDragX: CGFloat = 0
    private var lastDragTime: TimeInterval = 0
    private var isDragging = false
    private var dragVelocity: CGFloat = 0
    private var pendingFlip: DispatchWorkItem?

    /// Turns the angles of `AlbumFlowLayout` into Core Animation's. Both turn a point at x
    /// on the cover to depth -x sin(angle), so they agree (checked by the tests' renders).
    static let rotationSign: CGFloat = 1

    init(model: AlbumFlowModel) {
        self.model = model
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        root.addSublayer(stage)
        model.needsAnimation = { [weak self] in self?.startAnimating() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutInfo = AlbumFlowLayout(size: bounds.size)
        let scale = window?.backingScaleFactor ?? 2
        model.coverPixels = min(1200, Int(layoutInfo.side * scale))
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimating() } else { stopAnimating() }
    }

    // MARK: Animation

    func startAnimating() {
        guard link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    func stopAnimating() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1 / 60 : min(1 / 20, link.timestamp - lastTimestamp)
        lastTimestamp = link.timestamp
        MainActor.assumeIsolated {
            model.step(dt: CGFloat(dt))
            redraw()
            if model.isSettled, !isDragging { stopAnimating() }
        }
    }

    /// Places every cover that can be on screen for the model's position.
    @MainActor
    func redraw() {
        let layout = layoutInfo
        guard layout.size.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let c = layout.centre
        stage.bounds = CGRect(x: -c.x, y: -c.y, width: layout.size.width, height: layout.size.height)
        stage.anchorPoint = CGPoint(x: c.x / layout.size.width, y: c.y / layout.size.height)
        stage.position = c
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / layout.eyeDistance
        stage.sublayerTransform = perspective

        let albums = model.albums
        if albums.count != albumCount {
            // A new library: start afresh.
            coverLayers.values.forEach { $0.removeFromSuperlayer() }
            coverLayers = [:]
            albumCount = albums.count
        }
        guard !albums.isEmpty else { return }
        let position = model.position
        let reach = layout.reach
        let lo = max(0, Int(position.rounded(.down)) - reach)
        let hi = min(albums.count - 1, Int(position.rounded(.up)) + reach)
        for (index, layer) in coverLayers where index < lo || index > hi {
            layer.removeFromSuperlayer()
            coverLayers[index] = nil
        }
        let half = layout.size.width / 2
        for index in lo ... hi {
            let album = albums[index]
            let layer = coverLayers[index] ?? {
                let layer = CoverLayer()
                stage.addSublayer(layer)
                coverLayers[index] = layer
                return layer
            }()
            layer.resize(side: layout.side)
            if layer.albumID != album.id || !layer.hasCover {
                layer.albumID = album.id
                switch model.cover(for: album) {
                case .some(.some(let image)):
                    layer.setCover(image, reflection: reflection(of: image, album: album.id))
                    layer.hasCover = true
                case .some(.none):
                    layer.setCover(Self.placeholder, reflection: Self.placeholderReflection)
                    layer.hasCover = true
                case .none:
                    layer.setCover(Self.placeholder, reflection: Self.placeholderReflection)
                    layer.hasCover = false
                }
            }

            let d = CGFloat(index) - position
            let p = layout.placement(offset: d)
            var angle = p.angle
            var hidden = false
            if index == model.centreIndex, model.flip > 0 {
                // Turning over to its songs: the back (drawn by SwiftUI) takes over past 90°.
                angle += model.flip * .pi
                hidden = model.flip > 0.5
            }
            layer.isHidden = hidden
            layer.position = CGPoint(x: p.x, y: 0)
            // Nearer the centre draws on top.
            layer.zPosition = p.z - abs(d) * 0.01
            layer.transform = CATransform3DMakeRotation(angle * Self.rotationSign, 0, 1, 0)
            // The stacks fade into the dark towards the screen's edges.
            let screenX = abs(layout.project(offset: d, u: 0).x)
            let edge = max(0, min(1, (screenX / half - 0.4) / 0.62))
            layer.shade.opacity = Float(edge * edge * (3 - 2 * edge) * 0.92 + min(1, abs(d)) * 0.1)
        }
        model.requestCovers(near: lo ... hi)
    }

    /// Reflections made so far, by album (a few hundred at most).
    private var reflections: [UInt64: CGImage] = [:]

    private func reflection(of cover: CGImage, album: UInt64) -> CGImage {
        if let made = reflections[album] { return made }
        if reflections.count > 400 { reflections.removeAll(keepingCapacity: true) }
        let made = CoverLayer.reflectionImage(of: cover) ?? Self.placeholderReflection
        reflections[album] = made
        return made
    }

    static let placeholderReflection: CGImage = CoverLayer.reflectionImage(of: placeholder)!

    /// The album whose cover is under `point` (view coordinates), front-most first.
    @MainActor
    func album(at point: NSPoint) -> Int? {
        let layout = layoutInfo
        guard !model.albums.isEmpty else { return nil }
        let rx = point.x - layout.centre.x, ry = point.y - layout.centre.y
        let position = model.position
        let candidates = coverLayers.keys.sorted { abs(CGFloat($0) - position) < abs(CGFloat($1) - position) }
        for index in candidates {
            let d = CGFloat(index) - position
            let left = layout.project(offset: d, u: -0.5), right = layout.project(offset: d, u: 0.5)
            let lo = min(left.x, right.x), hi = max(left.x, right.x)
            guard rx >= lo, rx <= hi, hi - lo > 1 else { continue }
            let t = (rx - left.x) / (right.x - left.x)
            let scale = left.scale + (right.scale - left.scale) * t
            if abs(ry) <= layout.side / 2 * scale { return index }
        }
        return nil
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            model.showControls()
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let delta = abs(dx) > abs(dy) ? dx : dy
            if event.hasPreciseScrollingDeltas {
                let ended = event.momentumPhase == .ended || (event.phase == .ended && event.momentumPhase == [])
                model.drag(by: -delta / layoutInfo.pointsPerAlbum, settleAfter: ended ? 0.0 : 0.18)
            } else if delta != 0 {
                model.move(by: delta > 0 ? -1 : 1)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        lastDragX = dragStart?.x ?? 0
        lastDragTime = event.timestamp
        isDragging = false
        dragVelocity = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            if !isDragging, abs(point.x - start.x) > 4 {
                isDragging = true
                pendingFlip?.cancel()
            }
            guard isDragging else { return }
            let dx = point.x - lastDragX
            let dt = max(0.001, event.timestamp - lastDragTime)
            let albums = -dx / layoutInfo.pointsPerAlbum
            dragVelocity = dragVelocity * 0.6 + (albums / CGFloat(dt)) * 0.4
            lastDragX = point.x
            lastDragTime = event.timestamp
            model.drag(by: albums, settleAfter: nil)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; isDragging = false }
        MainActor.assumeIsolated {
            if isDragging {
                // A drag that stopped before letting go doesn't fling.
                let still = event.timestamp - lastDragTime > 0.08
                model.settle(velocity: still ? 0 : dragVelocity)
                return
            }
            click(at: point, count: event.clickCount)
        }
    }

    @MainActor
    private func click(at point: NSPoint, count: Int) {
        guard let index = album(at: point) else {
            model.unflip()
            return
        }
        if index != model.centreIndex || abs(model.position - CGFloat(index)) > 0.3 {
            model.go(to: index)
            return
        }
        pendingFlip?.cancel()
        if count >= 2 {
            model.unflip()
            model.playCentre()
            return
        }
        // Waits to see if it's a double-click (play) before turning the cover over.
        let flip = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.model.toggleFlip() }
        }
        pendingFlip = flip
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: flip)
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated { model.showControls() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Placeholder

    /// A cover for albums without one: grey, with a note, like iTunes'.
    static let placeholder: CGImage = {
        let side = 512
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [NSColor(white: 0.36, alpha: 1).cgColor, NSColor(white: 0.18, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(side)), end: .zero, options: [])
        if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 220, weight: .regular)) {
            let size = note.size
            let rect = CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                              width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let tinted = NSImage(size: size, flipped: false) { r in
                note.draw(in: r)
                NSColor(white: 0.62, alpha: 1).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()!
    }()
}

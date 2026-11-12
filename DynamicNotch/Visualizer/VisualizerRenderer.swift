//
//  VisualizerRenderer.swift
//  DynamicNotch
//
//  Drives the visualizer's Metal shader: smooths the live analysis into motion, tracks
//  beats as ripples, fades between covers' colours, and draws every display frame.
//

import AppKit
import MetalKit
import simd

/// The speaker pulses shown over the flow.
enum SpeakerLayout: Int, CaseIterable, Identifiable {
    case off, stereo, twoOne, fiveOne

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .stereo: return "2.0"
        case .twoOne: return "2.1"
        case .fiveOne: return "5.1"
        }
    }

    /// For each of the shader's slots, the analyzer's speaker (`SpeakerLevels.Speaker`), or -1.
    var sources: [Int] {
        typealias S = SpeakerLevels.Speaker
        switch self {
        case .off: return [-1, -1, -1, -1, -1, -1]
        case .stereo: return [S.left, S.right, -1, -1, -1, -1]
        case .twoOne: return [S.leftMain, S.rightMain, -1, S.sub, -1, -1]
        case .fiveOne: return [S.frontLeft, S.frontRight, S.centre, S.sub, S.surroundLeft, S.surroundRight]
        }
    }

    /// Levels in the shader's slot order: left, right, centre, sub, surround left, surround right.
    func slots(_ s: SpeakerLevels) -> [Float] {
        switch self {
        case .off: return [0, 0, 0, 0, 0, 0]
        case .stereo: return [s.left, s.right, 0, 0, 0, 0]
        case .twoOne: return [s.leftMain, s.rightMain, 0, s.sub, 0, 0]
        case .fiveOne: return [s.frontLeft, s.frontRight, s.centre, s.sub, s.surroundLeft, s.surroundRight]
        }
    }
}

/// An MTKView that renders at a capped pixel count: the scenes are soft light, so a 5K
/// display doesn't need every pixel drawn, and the fans stay quiet.
final class VisualizerMetalView: MTKView {
    static let maxPixels: CGFloat = 4_200_000

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let points = bounds.width * bounds.height
        guard points > 0 else { return }
        let scale = min(backing, sqrt(Self.maxPixels / points))
        drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }
}

final class VisualizerRenderer: NSObject, MTKViewDelegate {
    // Layout of the uniform buffer (VizUniforms in VisualizerShader), in float4s.
    private enum Slot {
        static let frame = 0, energy = 1, beat = 2, art = 3, colours = 4, rippleAge = 9, rippleStrength = 10
        static let speakerLevel = 11, speakerRingAge = 13, speakerRingStrength = 16, speakerPunch = 19, count = 21
    }

    /// The cover's half-size as a fraction of the screen height.
    static let artHalfSize: Float = 0.165
    static let paletteFade: Double = 0.9

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private var artTexture: MTLTexture
    private var uniforms = [SIMD4<Float>](repeating: .zero, count: Slot.count)

    // Settings, set on the main thread.
    var showsArtwork = true
    var isPlaying = true
    var speakerLayout: SpeakerLayout = .stereo

    // Animation state (main thread, in `draw`).
    private var frame = VisualizerFrame()
    private var energy = SIMD4<Float>(repeating: 0)
    private var beat: Float = 0
    private var lastBeatCount: Int?
    private var rippleAge = SIMD4<Float>(repeating: 10)
    private var rippleStrength = SIMD4<Float>(repeating: 0)
    private var nextRipple = 0
    private var phase: Double = 0
    private var lastTime: CFTimeInterval = 0
    private var startTime = CACurrentMediaTime()
    private var lastEnsure: CFTimeInterval = 0
    private var artAlpha: Float = 0
    private var artScale: Float = 0.92
    private var colours = [SIMD3<Float>](repeating: .zero, count: 5)
    private var targetColours = [SIMD3<Float>](repeating: .zero, count: 5)
    private var artVersion = 0
    // Speaker pulses: smoothed level, a slower average to spot hits against, and two rings
    // per speaker that travel out on each hit.
    private var speakerLevel = [Float](repeating: 0, count: 6)
    /// A flash on each hit that dies away in ~70 ms, so the pulse kicks with the drums.
    private var speakerPunch = [Float](repeating: 0, count: 6)
    private var lastHitCount: SIMD16<Int32>?
    private var speakerRingAge = [Float](repeating: 10, count: 12)
    private var speakerRingStrength = [Float](repeating: 0, count: 12)
    private var speakerNextRing = [Int](repeating: 0, count: 6)
    /// Left and right channel levels for the flow itself (whatever the speaker layout).
    private var stereo = SIMD2<Float>(repeating: 0)
    private var layoutAlpha: Float = 1
    private var shownLayout: SpeakerLayout = .stereo
    /// Where frames come from: the live tap (replaced for offscreen renders).
    private var readAudio: (inout VisualizerFrame) -> TimeInterval = { VisualizerAudio.shared.read(into: &$0) }

    init?(device: MTLDevice?) {
        guard let device,
              let queue = device.makeCommandQueue(),
              let pipeline = Self.pipeline(device: device)
        else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: blank) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.textureLoader = MTKTextureLoader(device: device)
        self.artTexture = texture
        super.init()
        setPalette(.fallback, immediately: true)
    }

    /// Compiled once (~0.1 s) and kept for later openings. Locked: renderers made at the same
    /// time on different threads (the tests) raced on it and crashed.
    private static var cachedPipeline: (device: MTLDevice, state: MTLRenderPipelineState)?
    private static let pipelineLock = NSLock()

    private static func pipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        if let cached = cachedPipeline, cached.device === device { return cached.state }
        do {
            let library = try device.makeLibrary(source: VisualizerShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "viz_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "viz_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            cachedPipeline = (device, state)
            return state
        } catch {
            NSLog("Visualizer shader failed: \(error)")
            return nil
        }
    }

    func makeView() -> VisualizerMetalView {
        let view = VisualizerMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        return view
    }

    /// New cover: its texture and palette are made off the main thread.
    func setArtwork(_ image: NSImage) {
        artVersion += 1
        let version = artVersion
        let loader = textureLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let palette = ArtPalette.make(from: cg)
            let texture = Self.coverTexture(cg, loader: loader)
            DispatchQueue.main.async {
                guard let self, version == self.artVersion else { return }
                if let texture { self.artTexture = texture }
                self.setPalette(palette, immediately: false)
            }
        }
    }

    /// The cover as a texture. It's first redrawn into plain 8-bit sRGB RGBA: Metal's loader
    /// takes an image's bytes as they are, so covers stored another way (CMYK, as print
    /// artwork often is, or with the channels in another order) came out in the wrong colours,
    /// a yellow cover showing blue. Redrawing converts them like every other view does.
    static func coverTexture(_ image: CGImage, loader: MTKTextureLoader, maxSide: Int = 1024) -> MTLTexture? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rgba = ctx.makeImage() else { return nil }
        return try? loader.newTexture(cgImage: rgba, options: [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }

    private func setPalette(_ palette: ArtPalette, immediately: Bool) {
        targetColours = [palette.background] + palette.accents
        if immediately { colours = targetColours }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(0.1, now - lastTime))
        lastTime = now
        update(dt: dt, now: now)

        let size = view.drawableSize
        uniforms[Slot.frame] = SIMD4(Float(size.width), Float(size.height), Float(now - startTime), Float(phase))

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer()
        else { return }
        encode(pass, in: buffer)
        buffer.present(drawable)
        buffer.commit()
    }

    private func encode(_ pass: MTLRenderPassDescriptor, in buffer: MTLCommandBuffer) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setFragmentTexture(artTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Runs `seconds` of animation at 60 fps on frames from `audio`, then draws one frame
    /// offscreen (tests: nothing appears on screen).
    func renderOffscreen(width: Int, height: Int, seconds: Double, artwork: CGImage? = nil,
                         audio: (_ time: Double, _ frame: inout VisualizerFrame) -> Void) -> CGImage? {
        if let artwork {
            if let texture = Self.coverTexture(artwork, loader: textureLoader) {
                artTexture = texture
            }
            setPalette(ArtPalette.make(from: artwork), immediately: true)
        }
        readAudio = { _ in 0 }
        let dt = 1.0 / 60
        var t = 0.0
        while t < seconds {
            audio(t, &frame)
            update(dt: Float(dt), now: startTime + t)
            t += dt
        }
        uniforms[Slot.frame] = SIMD4(Float(width), Float(height), Float(t), Float(phase))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(pass, in: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Animation

    private static func approach(_ value: Float, _ target: Float, dt: Float, rise: Float, fall: Float) -> Float {
        let tau = target > value ? rise : fall
        return value + (target - value) * (1 - expf(-dt / tau))
    }

    private func update(dt: Float, now: CFTimeInterval) {
        let age = readAudio(&frame)
        let live = age < 0.5
        if !live, isPlaying, now - lastEnsure > 1 {
            lastEnsure = now
            AudioLevelMonitor.shared.ensureRunning()
        }

        // Without audio (still starting, or no permission) the light breathes gently instead.
        let breathe = Float(0.5 + 0.5 * sin(now * 1.3))
        let targetEnergy: SIMD4<Float> = live
            ? SIMD4(frame.bass, frame.mid, frame.treble, frame.loudness)
            : (isPlaying ? SIMD4(0.2, 0.2, 0.15, 0.3) * (0.7 + 0.3 * breathe) : .zero)
        for k in 0 ..< 4 {
            energy[k] = Self.approach(energy[k], targetEnergy[k], dt: dt, rise: k == 0 ? 0.05 : 0.08, fall: k == 0 ? 0.22 : 0.3)
        }

        // Beats: a flash that decays, and a ripple that travels outwards.
        if live, let last = lastBeatCount, frame.beatCount != last {
            let strength = frame.beatStrength
            beat = max(beat, 0.35 + 0.65 * strength)
            rippleAge[nextRipple] = 0
            rippleStrength[nextRipple] = 0.4 + 0.6 * strength
            nextRipple = (nextRipple + 1) % 4
        }
        lastBeatCount = live ? frame.beatCount : nil
        beat *= expf(-dt / 0.22)
        rippleAge += SIMD4(repeating: dt)

        // Motion speeds up with the music, so the picture moves with the song's energy.
        phase += Double(dt * (0.22 + 1.5 * energy.w + 0.9 * energy.x + 1.2 * beat))

        artAlpha = Self.approach(artAlpha, showsArtwork ? 1 : 0, dt: dt, rise: 0.25, fall: 0.18)
        // The cover's own beat effects (its swell, glow and ripples) would read as a middle
        // speaker in 2.0, which has none: off there, faded with the layout change.
        let middle: Float = shownLayout == .stereo ? 1 - layoutAlpha : 1
        let targetScale: Float = (isPlaying ? 1 : 0.94) + middle * (0.045 * energy.x + 0.03 * beat)
        artScale = Self.approach(artScale, targetScale, dt: dt, rise: 0.06, fall: 0.2)
        for i in 0 ..< colours.count {
            let k = 1 - expf(-dt / Float(Self.paletteFade))
            colours[i] += (targetColours[i] - colours[i]) * k
        }

        updateSpeakers(dt: dt, now: now, live: live)

        uniforms[Slot.energy] = energy
        uniforms[Slot.beat] = SIMD4(beat, Float(shownLayout.rawValue), layoutAlpha, middle)
        uniforms[Slot.art] = SIMD4(Self.artHalfSize, artScale, artAlpha, isPlaying ? 1 : 0)
        for i in 0 ..< 5 { uniforms[Slot.colours + i] = SIMD4(colours[i], 1) }
        uniforms[Slot.rippleAge] = rippleAge
        uniforms[Slot.rippleStrength] = rippleStrength
        uniforms[Slot.speakerLevel] = SIMD4(speakerLevel[0], speakerLevel[1], speakerLevel[2], speakerLevel[3])
        uniforms[Slot.speakerLevel + 1] = SIMD4(speakerLevel[4], speakerLevel[5], stereo.x, stereo.y)
        uniforms[Slot.speakerPunch] = SIMD4(speakerPunch[0], speakerPunch[1], speakerPunch[2], speakerPunch[3])
        uniforms[Slot.speakerPunch + 1] = SIMD4(speakerPunch[4], speakerPunch[5], 0, 0)
        for i in 0 ..< 3 {
            uniforms[Slot.speakerRingAge + i] = SIMD4(speakerRingAge[4 * i], speakerRingAge[4 * i + 1],
                                                      speakerRingAge[4 * i + 2], speakerRingAge[4 * i + 3])
            uniforms[Slot.speakerRingStrength + i] = SIMD4(speakerRingStrength[4 * i], speakerRingStrength[4 * i + 1],
                                                           speakerRingStrength[4 * i + 2], speakerRingStrength[4 * i + 3])
        }
    }

    /// Follows each speaker's level closely (up at once, down in ~0.1 s) and, on each hit
    /// the analyzer finds, flashes it and sends a ring out.
    private func updateSpeakers(dt: Float, now: CFTimeInterval, live: Bool) {
        // Changing layout: fade the old pulses out, then the new ones in.
        if shownLayout != speakerLayout {
            layoutAlpha = max(0, layoutAlpha - dt / 0.25)
            if layoutAlpha == 0 {
                shownLayout = speakerLayout
                for i in 0 ..< 6 { speakerLevel[i] = 0; speakerPunch[i] = 0 }
                for i in 0 ..< 12 { speakerRingStrength[i] = 0 }
            }
        } else {
            layoutAlpha = min(1, layoutAlpha + dt / 0.35)
        }
        let targetStereo = live ? SIMD2(frame.speakers.left, frame.speakers.right) : SIMD2(repeating: 0.3 * energy.w)
        for k in 0 ..< 2 { stereo[k] = Self.approach(stereo[k], targetStereo[k], dt: dt, rise: 0.05, fall: 0.25) }
        let targets = live ? shownLayout.slots(frame.speakers) : [Float](repeating: 0, count: 6)
        let sources = shownLayout.sources
        let counts = frame.speakers.hitCount
        for i in 0 ..< 6 {
            let isSub = i == 3
            speakerLevel[i] = Self.approach(speakerLevel[i], targets[i], dt: dt,
                                            rise: isSub ? 0.012 : 0.008, fall: isSub ? 0.13 : 0.09)
            speakerPunch[i] *= expf(-dt / (isSub ? 0.09 : 0.07))
            let source = sources[i]
            guard live, source >= 0, let last = lastHitCount, counts[source] != last[source] else { continue }
            let strength = frame.speakers.hitStrength[source]
            speakerPunch[i] = max(speakerPunch[i], strength)
            let ring = 2 * i + speakerNextRing[i]
            speakerNextRing[i] ^= 1
            speakerRingAge[ring] = 0
            speakerRingStrength[ring] = strength
        }
        lastHitCount = live ? counts : nil
        for i in 0 ..< 12 { speakerRingAge[i] += dt }
    }
}

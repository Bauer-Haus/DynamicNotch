//
//  VisualizerTests.swift
//  DynamicNotch
//
//  The full-screen visualizer: its analysis on synthetic audio, its palettes, and its
//  picture rendered offscreen (nothing is shown on screen).
//

import AppKit
import Foundation
import Metal
import Testing
@testable import DynamicNotch

@Suite("Visualizer")
struct VisualizerTests {
    static let sampleRate = 48_000.0

    /// Runs `seconds` of audio from `signal` through a fresh analyzer, calling `each` per frame.
    private func analyse(seconds: Double, _ signal: (Double) -> Float,
                         each: (VisualizerFrame) -> Void = { _ in }) throws -> VisualizerAnalyzer {
        let analyzer = try #require(VisualizerAnalyzer(sampleRate: Self.sampleRate))
        let chunk = 512
        var buffer = [Float](repeating: 0, count: chunk)
        var n = 0
        while Double(n) < seconds * Self.sampleRate {
            for i in 0 ..< chunk { buffer[i] = signal(Double(n + i) / Self.sampleRate) }
            n += chunk
            if buffer.withUnsafeBufferPointer({ analyzer.push($0) }) { each(analyzer.frame) }
        }
        return analyzer
    }

    @Test func toneLightsItsOwnBand() throws {
        let analyzer = try analyse(seconds: 1) { t in 0.5 * Float(sin(2 * .pi * 1000 * t)) }
        let bands = analyzer.frame.bands
        let loudest = try #require(bands.indices.max { bands[$0] < bands[$1] })
        // Band edges are log-spaced 32 Hz ... 16 kHz: 1 kHz sits in band ~35.
        let expected = Int(64 * log2(1000.0 / 32) / log2(16000.0 / 32))
        #expect(abs(loudest - expected) <= 1)
        #expect(bands[loudest] > 0.9)
        #expect(bands[5] < 0.2)
        #expect(bands[60] < 0.2)
    }

    @Test func silenceStaysDark() throws {
        var beats = 0
        let analyzer = try analyse(seconds: 2, { _ in 0 }) { beats = $0.beatCount }
        #expect(analyzer.frame.bands.allSatisfy { $0 == 0 })
        #expect(analyzer.frame.loudness == 0)
        #expect(beats == 0)
    }

    /// A kick every half second (120 BPM) over a steady chord.
    private static func kickTrack(gain: Float) -> (Double) -> Float {
        { t in
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let kick = Float(exp(-beat * 18) * sin(2 * .pi * (55 + 90 * exp(-beat * 30)) * beat))
            let pad = Float(0.12 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)))
            return gain * (0.8 * kick + pad)
        }
    }

    @Test func findsTheBeat() throws {
        var count = 0
        _ = try analyse(seconds: 8, Self.kickTrack(gain: 0.7)) { count = $0.beatCount }
        // 16 kicks; the first second or so is spent learning the track.
        #expect(count >= 12 && count <= 17)
    }

    @Test func adaptsToQuietMasters() throws {
        let loud = try analyse(seconds: 4, Self.kickTrack(gain: 0.7)).frame
        let quiet = try analyse(seconds: 4, Self.kickTrack(gain: 0.07)).frame // 20 dB down
        let loudSum = loud.bands.reduce(0, +)
        let quietSum = quiet.bands.reduce(0, +)
        #expect(quietSum > loudSum * 0.7)
    }

    // MARK: Speakers

    /// Runs stereo audio through a fresh analyzer and returns the last speaker levels.
    private func speakers(seconds: Double = 2, _ signal: (Double) -> (Float, Float)) throws -> SpeakerLevels {
        let analyzer = try #require(VisualizerAnalyzer(sampleRate: Self.sampleRate))
        let chunk = 512
        var left = [Float](repeating: 0, count: chunk)
        var right = [Float](repeating: 0, count: chunk)
        var n = 0
        while Double(n) < seconds * Self.sampleRate {
            for i in 0 ..< chunk { (left[i], right[i]) = signal(Double(n + i) / Self.sampleRate) }
            n += chunk
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in _ = analyzer.push(left: l, right: r) } }
        }
        return analyzer.frame.speakers
    }

    private static func tone(_ hz: Double, _ t: Double, _ amplitude: Float = 0.5) -> Float {
        amplitude * Float(sin(2 * .pi * hz * t))
    }

    @Test func leftOnlyLightsLeft() throws {
        let s = try speakers { t in (Self.tone(1000, t), 0) }
        #expect(s.left > 0.8 && s.right < 0.1)
        #expect(s.frontLeft > 0.8 && s.frontRight < 0.1)
        // Panned hard, it stays in front.
        #expect(s.surroundLeft < 0.1 && s.surroundRight < 0.1)
    }

    @Test func midsGoToLeftAndRight() throws {
        let s = try speakers { t in let v = Self.tone(1000, t); return (v, v) }
        #expect(s.frontLeft > 0.8 && s.frontRight > 0.8)
        #expect(s.centre < 0.1 && s.sub < 0.1)
        #expect(s.surroundLeft < 0.1 && s.surroundRight < 0.1)
    }

    @Test func highsGoToTheCentre() throws {
        let s = try speakers { t in let v = Self.tone(8000, t); return (v, v) }
        #expect(s.centre > 0.8)
        #expect(s.frontLeft < 0.1 && s.frontRight < 0.1 && s.sub < 0.1)
        // 2.0 and 2.1 still play them on both sides.
        #expect(s.left > 0.8 && s.rightMain > 0.8)
    }

    @Test func lowsGoToTheSub() throws {
        let s = try speakers { t in let v = Self.tone(50, t); return (v, v) }
        #expect(s.sub > 0.8)
        #expect(s.leftMain < 0.1 && s.rightMain < 0.1)
        #expect(s.frontLeft < 0.1 && s.centre < 0.1)
        #expect(s.left > 0.8)
    }

    @Test func ambienceGoesToTheSurrounds() throws {
        let s = try speakers { t in let v = Self.tone(1000, t); return (v, -v) }
        #expect(s.surroundLeft > 0.8 && s.surroundRight > 0.8)
        #expect(s.frontLeft < 0.1 && s.centre < 0.1)
    }

    /// A full mix: each speaker gets its part.
    @Test func mixSplitsAcrossSpeakers() throws {
        let s = try speakers(seconds: 3) { t in
            let low = Self.tone(55, t, 0.4), mid = Self.tone(700, t, 0.2), high = Self.tone(7000, t, 0.03)
            let room = Self.tone(1300, t, 0.05)
            return (low + mid + high + room, low + mid + high - room)
        }
        for (name, level) in [("sub", s.sub), ("FL", s.frontLeft), ("FR", s.frontRight), ("C", s.centre),
                              ("SL", s.surroundLeft), ("SR", s.surroundRight)] {
            #expect(level > 0.3, "\(name) = \(level)")
        }
    }

    @Test func silenceLightsNoSpeaker() throws {
        let s = try speakers { _ in (0, 0) }
        #expect([s.left, s.right, s.centre, s.sub, s.surroundLeft, s.surroundRight].allSatisfy { $0 == 0 })
    }

    // MARK: Palette

    private static func image(_ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    @Test func navyAndGoldCover() {
        let cover = Self.image { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.12, blue: 0.27, alpha: 1)) // navy
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.68, blue: 0.35, alpha: 1)) // gold
            ctx.fill(CGRect(x: 8, y: 26, width: 48, height: 12))
        }
        let palette = ArtPalette.make(from: cover)
        #expect(palette.accents.count == 4)
        // A dark blue field...
        #expect(palette.background.z > palette.background.x)
        #expect(palette.background.max() < 0.2)
        // ...with gold light first.
        let gold = palette.accents[0]
        #expect(gold.x > gold.z && gold.y > gold.z)
    }

    /// Thin blue line art on a white cover (like a sketch): blue must lead, not grey.
    private static let lineArtCover = image { ctx in
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.15, blue: 0.95, alpha: 1))
        ctx.setLineWidth(0.8)
        for i in 0 ..< 6 {
            ctx.move(to: CGPoint(x: 18 + i * 4, y: 10))
            ctx.addLine(to: CGPoint(x: 30 + i * 2, y: 54))
        }
        ctx.strokePath()
    }

    @Test func lineArtOnWhite() {
        let palette = ArtPalette.make(from: Self.lineArtCover)
        // A dark blue backdrop, not grey...
        let bg = ArtPalette.hsb(palette.background)
        #expect(bg.y > 0.5 && bg.x > 0.55 && bg.x < 0.75)
        #expect(bg.z < 0.2)
        // ...lit in blue, with the cover's white as a highlight.
        let lead = palette.accents[0]
        #expect(lead.z > lead.x + 0.3)
        #expect(palette.accents.contains { $0.min() > 0.9 })
    }

    @Test func greyCoverStaysGrey() {
        let cover = Self.image { ctx in
            for i in 0 ..< 8 {
                ctx.setFillColor(CGColor(gray: CGFloat(i) / 8, alpha: 1))
                ctx.fill(CGRect(x: i * 8, y: 0, width: 8, height: 64))
            }
        }
        let palette = ArtPalette.make(from: cover)
        for accent in palette.accents {
            #expect(accent.max() - accent.min() < 0.02)
        }
    }

    // MARK: Rendering

    static let navyGoldCover = image { ctx in
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.12, blue: 0.27, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.68, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 26, width: 48, height: 12))
    }

    /// A stereo mix: the kick in the middle, a hi-hat-like burst on the left, a vocal-like
    /// tone on the right and an out-of-phase pad for the surrounds.
    private static func stereoMix(_ t: Double) -> (Float, Float) {
        let kick = kickTrack(gain: 0.6)(t)
        let eighth = t.truncatingRemainder(dividingBy: 0.25)
        let hat = Float(exp(-eighth * 40)) * tone(6000, t, 0.25)
        let vocal = tone(660, t, 0.2) * Float(0.6 + 0.4 * sin(t * 3))
        let pad = tone(440, t, 0.08)
        return (kick + hat + pad, kick + vocal - pad)
    }

    @Test(arguments: ["NavyGold", "LineArt", "Stereo", "TwoOne", "FiveOne"])
    func flowRenders(_ name: String) throws {
        let renderer = try #require(VisualizerRenderer(device: MTLCreateSystemDefaultDevice()))
        let cover = name == "LineArt" ? Self.lineArtCover : Self.navyGoldCover
        renderer.speakerLayout = ["Stereo": .stereo, "TwoOne": .twoOne, "FiveOne": .fiveOne][name] ?? .off
        let analyzer = try #require(VisualizerAnalyzer(sampleRate: Self.sampleRate))
        var n = 0
        var left = [Float](repeating: 0, count: 800) // one 60 fps frame of audio
        var right = [Float](repeating: 0, count: 800)
        let image = try #require(renderer.renderOffscreen(width: 960, height: 600, seconds: 3, artwork: cover) { time, frame in
            for i in 0 ..< left.count { (left[i], right[i]) = Self.stereoMix(Double(n + i) / Self.sampleRate) }
            n += left.count
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in _ = analyzer.push(left: l, right: r) } }
            frame = analyzer.frame
        })

        // Lit and varied: not a blank or flat screen.
        let rep = NSBitmapImageRep(cgImage: image)
        var lumas: [Double] = []
        for y in stride(from: 0, to: image.height, by: 20) {
            for x in stride(from: 0, to: image.width, by: 20) {
                let c = rep.colorAt(x: x, y: y)!
                lumas.append(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
            }
        }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        let spread = sqrt(lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count))
        #expect(mean > 0.03)
        #expect(spread > 0.02)

        // VISUALIZER_SNAPSHOT=1 (TEST_RUNNER_VISUALIZER_SNAPSHOT=1 with xcodebuild) prints the
        // frame as base64 JPEG, since the sandboxed test host can't write outside its container.
        if ProcessInfo.processInfo.environment["VISUALIZER_SNAPSHOT"] == "1",
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            // In short lines: the test log cuts long ones.
            let text = jpeg.base64EncodedString()
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 800, limitedBy: text.endIndex) ?? text.endIndex
                print("SNAPSHOT \(name) \(text[start ..< end])")
                start = end
            }
        }
    }
}

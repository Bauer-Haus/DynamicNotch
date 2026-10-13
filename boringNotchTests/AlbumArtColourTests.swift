//
//  AlbumArtColourTests.swift
//  boringNotchTests
//
//  The blurred album art behind the visualizer bars, and the lift for dark covers.
//

import AppKit
import Testing
@testable import Boring_Notch

@Suite("Album art colours")
struct AlbumArtColourTests {
    /// A solid-colour square "album cover".
    private func cover(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGFloat = 300) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        return image
    }

    private func backdrop(of image: NSImage) async -> (NSImage?, CGFloat) {
        await withCheckedContinuation { continuation in
            image.visualizerBackdrop { continuation.resume(returning: ($0, $1)) }
        }
    }

    /// The centre pixel of the backdrop as 0...255 RGB.
    private func centre(of image: NSImage) throws -> (r: Int, g: Int, b: Int) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        let colour = try #require(rep.colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.deviceRGB))
        return (Int((colour.redComponent * 255).rounded()), Int((colour.greenComponent * 255).rounded()),
                Int((colour.blueComponent * 255).rounded()))
    }

    // MARK: Brightness floor

    @Test func blackCoverGivesLightGreyBars() async throws {
        let (image, luminance) = await backdrop(of: cover(0, 0, 0))
        let pixel = try centre(of: try #require(image))
        // The iPhone shows about (99, 100, 106) for a black cover.
        let floor = Int(NSImage.minimumBarBrightness)
        #expect(abs(pixel.r - floor) <= 3 && abs(pixel.g - floor) <= 3 && abs(pixel.b - floor) <= 3, "\(pixel)")
        #expect(luminance < 0.02)
    }

    @Test func colourfulCoverKeepsItsColour() async throws {
        // Orange, like the World a Music cover's shirt.
        let (image, _) = await backdrop(of: cover(0.85, 0.5, 0.15))
        let pixel = try centre(of: try #require(image))
        #expect(pixel.r > pixel.g && pixel.g > pixel.b, "still orange: \(pixel)")
        #expect(pixel.r > Int(NSImage.minimumBarBrightness), "above the floor, so not lifted")
    }

    @Test func floorAddsEvenlySoGreysStayNeutral() {
        var pixels: [UInt8] = [3, 2, 5, 255,   200, 100, 50, 255,   102, 0, 0, 255]
        NSImage.liftToMinimumBrightness(rgba: &pixels, minimum: 102)
        #expect(Array(pixels[0 ..< 3]) == [100, 99, 102])   // near-black: neutral grey, not purple
        #expect(Array(pixels[4 ..< 7]) == [200, 100, 50])   // bright: untouched
        #expect(Array(pixels[8 ..< 11]) == [102, 0, 0])     // already at the floor: untouched
        #expect(pixels[3] == 255 && pixels[7] == 255)        // alpha untouched
    }

    @Test func averageLuminance() {
        #expect(NSImage.averageLuminance(rgba: [0, 0, 0, 255]) == 0)
        #expect(abs(NSImage.averageLuminance(rgba: [255, 255, 255, 255]) - 1) < 0.0001)
        #expect(NSImage.averageLuminance(rgba: []) == 0)
    }

    // MARK: Dark cover lift

    @Test func blackCoverIsDrawnAsDarkGrey() {
        // Pure black shows as ~28/255 on the iPhone, a lift of ~0.1.
        #expect(abs(NSImage.darkArtLift(averageLuminance: 0) - 0.1) < 0.001)
    }

    @Test func normalCoversAreNotChanged() {
        for luminance in stride(from: CGFloat(0.2), through: 1, by: 0.1) {
            #expect(NSImage.darkArtLift(averageLuminance: luminance) == 0)
        }
    }

    @Test func liftFadesOutAsCoversGetBrighter() {
        var previous = NSImage.darkArtLift(averageLuminance: 0)
        for luminance in stride(from: CGFloat(0.01), through: 0.3, by: 0.01) {
            let lift = NSImage.darkArtLift(averageLuminance: luminance)
            #expect(lift <= previous)
            previous = lift
        }
    }

    @Test func midToneCoverIsNotLifted() async {
        let (_, luminance) = await backdrop(of: cover(0.5, 0.5, 0.5))
        #expect(NSImage.darkArtLift(averageLuminance: luminance) == 0, "luminance \(luminance)")
    }
}

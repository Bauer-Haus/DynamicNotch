//
//  AlbumArtColourTests.swift
//  DynamicNotch
//
//  The blurred album art behind the visualizer bars, and the lift for dark covers.
//

import AppKit
import Testing
@testable import DynamicNotch

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

    private func backdrop(of image: NSImage) async -> NSImage? {
        await withCheckedContinuation { continuation in
            image.visualizerBackdrop { continuation.resume(returning: $0) }
        }
    }

    /// The centre pixel of the backdrop as stored (Display P3, 0...255).
    private func centre(of image: NSImage) throws -> (r: Int, g: Int, b: Int) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(cg.dataProvider?.data) as Data
        let i = (cg.height / 2) * cg.bytesPerRow + (cg.width / 2) * cg.bitsPerPixel / 8
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    // MARK: Brightness floor

    @Test func blackCoverGivesLightGreyBars() async throws {
        let image = await backdrop(of: cover(0, 0, 0))
        let pixel = try centre(of: try #require(image))
        // The iPhone shows about (99, 100, 106) for a black cover.
        let floor = Int(NSImage.minimumBarBrightness)
        #expect(abs(pixel.r - floor) <= 3 && abs(pixel.g - floor) <= 3 && abs(pixel.b - floor) <= 3, "\(pixel)")
    }

    @Test func colourfulCoverKeepsItsColour() async throws {
        // Orange, like the World a Music cover's shirt.
        let image = await backdrop(of: cover(0.85, 0.5, 0.15))
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

    // MARK: The iPhone's colouring

    /// One colour through the bar colouring, on a cover whose average colour is `cover`.
    private func barColour(_ colour: [Double], cover: [Double]) -> [Int] {
        let luma = IslandBarColour.coverLuma(averageP3: cover.map { $0 / 255 })
        return IslandBarColour.colour(p3: colour.map { $0 / 255 }, coverLuma: luma).map { Int(($0 * 255).rounded()) }
    }

    /// The same colours through the fitted model the numbers came from (Display P3, 0...255),
    /// so the app's arithmetic matches what was fitted to the iPhone screenshots.
    @Test(arguments: [
        ([137, 204, 4], [137, 204, 4], [101, 182, 53]),         // brat: darker lime
        ([250, 250, 250], [230, 230, 228], [122, 122, 122]),    // white on a white cover: mid-grey
        ([190, 120, 40], [110, 70, 40], [206, 116, 42]),        // orange on a dark cover: richer
        ([70, 140, 180], [90, 140, 170], [66, 148, 198]),       // sky blue: richer
        ([140, 120, 160], [100, 90, 130], [143, 117, 168]),     // lavender: stays purple
    ] as [([Double], [Double], [Int])])
    func matchesTheFittedModel(colour: [Double], cover: [Double], expected: [Int]) {
        let out = barColour(colour, cover: cover)
        for c in 0 ..< 3 {
            #expect(abs(out[c] - expected[c]) <= 1, "\(colour) -> \(out), expected \(expected)")
        }
    }

    @Test func brightCoversAreDimmed() {
        // The same white, on a white cover and on a mid-grey one: a bright cover is held down.
        let onWhite = barColour([250, 250, 250], cover: [245, 245, 245])
        let onGrey = barColour([250, 250, 250], cover: [128, 128, 128])
        #expect(onWhite[0] < onGrey[0] - 20, "\(onWhite) vs \(onGrey)")
        #expect(onWhite[0] == onWhite[1] && onWhite[1] == onWhite[2], "stays neutral")
    }

    @Test func whiteCoverGivesMidGreyBars() async throws {
        let image = await backdrop(of: cover(1, 1, 1))
        let pixel = try centre(of: try #require(image))
        // The iPhone shows ~123-147 on the White Album; an all-white cover is dimmed a bit more.
        #expect((100 ... 150).contains(pixel.r) && abs(pixel.r - pixel.b) <= 3, "\(pixel)")
    }

    @Test func limeCoverStaysLime() async throws {
        let image = await backdrop(of: cover(0.54, 0.8, 0.02))
        let pixel = try centre(of: try #require(image))
        #expect(pixel.g > pixel.r + 30 && pixel.r > pixel.b, "darker lime: \(pixel)")
    }

    // MARK: Black level of the cover itself

    /// One pixel through the black-level lift.
    private func lifted(_ r: UInt8, _ g: UInt8, _ b: UInt8, alpha: UInt8 = 255) -> [UInt8] {
        var p: [UInt8] = [r, g, b, alpha]
        AlbumArtLook.raiseBlackLevel(rgba: &p)
        return p
    }

    @Test func blackBecomesDarkGreyLikeTheIPhone() {
        #expect(lifted(0, 0, 0) == [20, 20, 20, 255])      // iPhone: ~20 for a pure black cover
    }

    @Test func nearBlackMatchesTheMeasuredCover() {
        #expect(lifted(8, 8, 8)[0] == 27)                  // The Business: ~8 showed as ~27
    }

    @Test func whiteAndHighlightsStayBright() {
        #expect(lifted(255, 255, 255) == [255, 255, 255, 255])
    }

    @Test func midTonesBarelyChange() {
        #expect(lifted(128, 128, 128)[0] == 138)           // 20 + 128 x 235/255
    }

    @Test func coloursKeepTheirHue() {
        let p = lifted(200, 100, 0)
        #expect(p[0] == 204 && p[1] == 112 && p[2] == 20)
    }

    @Test func transparentPixelsStayTransparent() {
        #expect(lifted(0, 0, 0, alpha: 0) == [0, 0, 0, 0])
        let half = lifted(0, 0, 0, alpha: 128)              // premultiplied: lift scales with alpha
        #expect(half[0] == 10 && half[3] == 128)
    }

    @Test func darkCoverImageIsLifted() throws {
        let image = cover(0, 0, 0).withRaisedBlackLevel()
        // Read back in sRGB, the space the lift works in (device RGB would shift the value).
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &pixels, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let i = (cg.height / 2 * cg.width + cg.width / 2) * 4
        #expect(Array(pixels[i ..< i + 4]) == [20, 20, 20, 255], "\(Array(pixels[i ..< i + 4]))")
    }
}

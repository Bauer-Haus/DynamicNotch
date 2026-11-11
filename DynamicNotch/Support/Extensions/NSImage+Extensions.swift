//
//  NSImage+Extensions.swift
//  DynamicNotch
//
//  Album art processing: the blurred colour layer behind the waveform, thumbnails, and the
//  raised black level.
//

import SwiftUI
import AppKit
import Cocoa
import Foundation
import CoreGraphics
import ImageIO

extension NSImage {

    /// The colour layer behind the visualizer bars, matching the iPhone Dynamic Island, so each
    /// bar takes the colour of the part of the cover behind it. Like the iPhone, the cover is
    /// reduced to a 3 x 3 grid of average colours, blended smoothly across the waveform (slightly
    /// zoomed in on the cover's middle), and each pixel then gets the iPhone's colouring
    /// (`IslandBarColour`). Made once per track off the main thread; the bars only mask it.
    func visualizerBackdrop(completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.cgImage(forProposedRect: nil, context: nil, hints: nil)
                .flatMap { IslandBarColour.backdrop(from: $0) }
                .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// The iPhone never lets a bar go darker than this (~40%): a black cover gives bars of
    /// about (99, 100, 106).
    static let minimumBarBrightness: UInt8 = 102

    /// Raises any pixel whose brightest channel is below `minimum` by adding the same amount
    /// to every channel. Near-black stays a neutral grey (scaling would turn tiny colour
    /// differences into strong tints); colourful pixels above the floor are untouched.
    static func liftToMinimumBrightness(rgba pixels: inout [UInt8], minimum: UInt8) {
        var i = 0
        while i + 3 < pixels.count {
            let brightest = max(pixels[i], pixels[i + 1], pixels[i + 2])
            if brightest < minimum {
                let add = minimum - brightest
                pixels[i] += add
                pixels[i + 1] += add
                pixels[i + 2] += add
            }
            i += 4
        }
    }

    /// Decodes image data straight to a copy no larger than `maxPixelSize` on its longest
    /// side, without ever decoding the full-size image (album art is often 3000 px square).
    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Album covers on the iPhone's Dynamic Island never show true black: their blacks are
/// raised to dark grey so a dark cover doesn't melt into the black island, while colours and
/// highlights stay as they are. Measured from screenshots of three dark covers: pure black
/// shows as ~20/255 and a near-black of ~8 as ~27, i.e. out = 20 + in x 235/255 on ordinary
/// (gamma-encoded) values. It applies to every cover; on a bright one only near-black changes.
/// (SwiftUI's screen blend works in linear light and gave 26 for black and 156 for mid-grey.)
enum AlbumArtLook {
    static let blackLevel: UInt8 = 20

    /// Raises the black level of premultiplied RGBA pixels, keeping alpha.
    static func raiseBlackLevel(rgba pixels: inout [UInt8], to level: UInt8 = blackLevel) {
        let scale = 255 - Int(level)
        var i = 0
        while i + 3 < pixels.count {
            let alpha = Int(pixels[i + 3])
            let lift = Int(level) * alpha / 255   // premultiplied: the lift scales with alpha
            for c in 0 ..< 3 {
                pixels[i + c] = UInt8(min(alpha, lift + (Int(pixels[i + c]) * scale + 127) / 255))
            }
            i += 4
        }
    }
}

extension NSImage {
    /// A copy with the album-art black level applied (see `AlbumArtLook`).
    func withRaisedBlackLevel() -> NSImage {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return self }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info) else { return self }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        AlbumArtLook.raiseBlackLevel(rgba: &pixels)
        guard let lifted = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
        else { return self }
        return NSImage(cgImage: lifted, size: size)
    }
}

/// How the iPhone Dynamic Island colours its waveform from the album cover. Fitted to iPhone
/// screenshots of eight covers (purple, orange, lime, blue, tan, grey, white and black): bars
/// come out within ~6/255 on average, the worst cover ~11. All colours are Display P3, as the
/// iPhone draws them.
///
/// 1. The cover is averaged into a 3 x 3 grid and blended smoothly across the waveform, zoomed
///    in 1.17x on the cover (and a touch below its middle).
/// 2. Colour is made richer: 1.31x away from grey, in linear light, within the sRGB range.
/// 3. Brightness (luma) becomes 0.047 + 0.90 x the cover's own, scaled down for a bright cover
///    (whole-cover luma over 0.63), so a white cover gives mid-grey bars and a lime one darker lime.
/// 4. Nothing goes darker than `NSImage.minimumBarBrightness` (a black cover gives grey bars).
enum IslandBarColour {
    static let grid = 3
    static let zoom = 1.1734
    static let offsetX = 0.0048
    static let offsetY = 0.0488
    static let saturation = 1.3120
    static let brightnessOffset = 0.0471
    static let brightnessScale = 0.8992
    /// Covers brighter than this (whole-cover luma) are dimmed by (this / theirs) ^ exponent.
    static let brightCover = 0.6279
    static let brightCoverExponent = 1.8241
    /// Side of the backdrop image; it is stretched over the waveform.
    static let side = 32

    // Display P3 <-> sRGB, both linear.
    private static let p3ToSRGB: [[Double]] = [[1.2249, -0.2247, 0], [-0.0420, 1.0419, 0], [-0.0197, -0.0786, 1.0979]]
    private static let sRGBToP3: [[Double]] = [[0.82248, 0.17738, 0], [0.03315, 0.96694, 0], [0.01713, 0.07241, 0.91083]]
    private static let rec709: [Double] = [0.2126, 0.7152, 0.0722]

    static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encoded(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
    private static func times(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0 ..< 3).map { i in m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] }
    }
    private static func luma(linearSRGB v: [Double]) -> Double {
        zip(rec709, v).reduce(0) { $0 + $1.0 * encoded($1.1) }
    }

    /// The whole cover's brightness, from its average Display P3 colour (0...1 channels).
    static func coverLuma(averageP3 p3: [Double]) -> Double {
        luma(linearSRGB: times(p3ToSRGB, p3.map(linear)))
    }

    /// One bar colour: a Display P3 colour from the cover (0...1) -> the bar's Display P3 colour.
    static func colour(p3: [Double], coverLuma: Double) -> [Double] {
        let source = times(p3ToSRGB, p3.map(linear))                      // linear sRGB
        let y = zip(rec709, source).reduce(0) { $0 + $1.0 * $1.1 }
        let richer = source.map { min(max(y + saturation * ($0 - y), 0), 1) }
        let dim = coverLuma > brightCover ? pow(brightCover / coverLuma, brightCoverExponent) : 1
        let target = (brightnessOffset + brightnessScale * luma(linearSRGB: source)) * dim
        // Scale the richer colour until its brightness is the target.
        var low = 0.0, high = 4.0
        for _ in 0 ..< 28 {
            let mid = (low + high) / 2
            if luma(linearSRGB: richer.map { min($0 * mid, 1) }) < target { low = mid } else { high = mid }
        }
        let scale = (low + high) / 2
        return times(sRGBToP3, richer.map { min($0 * scale, 1) }).map(encoded)
    }

    /// The backdrop for a cover: `side` x `side`, Display P3.
    static func backdrop(from art: CGImage) -> CGImage? {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        // The cover at 48 px (16 per grid cell), in Display P3, black level raised as shown.
        let sample = 48, cell = sample / grid
        var cover = [UInt8](repeating: 0, count: sample * sample * 4)
        guard let context = CGContext(data: &cover, width: sample, height: sample, bitsPerComponent: 8,
                                      bytesPerRow: sample * 4, space: p3, bitmapInfo: info) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sample, height: sample))
        context.interpolationQuality = .high
        context.draw(art, in: CGRect(x: 0, y: 0, width: sample, height: sample))
        AlbumArtLook.raiseBlackLevel(rgba: &cover)

        func pixel(_ x: Int, _ y: Int) -> [Double] {
            let i = (y * sample + x) * 4
            return [Double(cover[i]) / 255, Double(cover[i + 1]) / 255, Double(cover[i + 2]) / 255]
        }
        var cells = [[Double]](repeating: [0, 0, 0], count: grid * grid)
        for gy in 0 ..< grid {
            for gx in 0 ..< grid {
                var sum = [0.0, 0.0, 0.0]
                for y in gy * cell ..< (gy + 1) * cell {
                    for x in gx * cell ..< (gx + 1) * cell {
                        let p = pixel(x, y)
                        for c in 0 ..< 3 { sum[c] += p[c] }
                    }
                }
                cells[gy * grid + gx] = sum.map { $0 / Double(cell * cell) }
            }
        }
        // The whole cover's brightness, leaving out the edges (as measured).
        let inset = sample / 10
        var mean = [0.0, 0.0, 0.0]
        for y in inset ..< sample - inset {
            for x in inset ..< sample - inset {
                let p = pixel(x, y)
                for c in 0 ..< 3 { mean[c] += p[c] }
            }
        }
        let count = Double((sample - 2 * inset) * (sample - 2 * inset))
        let brightness = coverLuma(averageP3: mean.map { $0 / count })

        // Blend the grid over the waveform and colour each pixel.
        var out = [UInt8](repeating: 255, count: side * side * 4)
        let last = Double(grid - 1)
        for py in 0 ..< side {
            for px in 0 ..< side {
                let u = 0.5 + ((Double(px) + 0.5) / Double(side) - 0.5) / zoom + offsetX
                let v = 0.5 + ((Double(py) + 0.5) / Double(side) - 0.5) / zoom + offsetY
                let gx = min(max(u * Double(grid) - 0.5, 0), last)
                let gy = min(max(v * Double(grid) - 0.5, 0), last)
                let x0 = min(Int(gx), grid - 2), y0 = min(Int(gy), grid - 2)
                let fx = gx - Double(x0), fy = gy - Double(y0)
                var source = [0.0, 0.0, 0.0]
                for c in 0 ..< 3 {
                    let top = cells[y0 * grid + x0][c] * (1 - fx) + cells[y0 * grid + x0 + 1][c] * fx
                    let bottom = cells[(y0 + 1) * grid + x0][c] * (1 - fx) + cells[(y0 + 1) * grid + x0 + 1][c] * fx
                    source[c] = top * (1 - fy) + bottom * fy
                }
                let bar = colour(p3: source, coverLuma: brightness)
                let i = (py * side + px) * 4
                for c in 0 ..< 3 { out[i + c] = UInt8((bar[c] * 255).rounded()) }
            }
        }
        NSImage.liftToMinimumBrightness(rgba: &out, minimum: NSImage.minimumBarBrightness)
        return CGContext(data: &out, width: side, height: side, bitsPerComponent: 8,
                         bytesPerRow: side * 4, space: p3, bitmapInfo: info)?.makeImage()
    }
}

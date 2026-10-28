//
//  Image2Color.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import SwiftUI
import AppKit
import Cocoa
import Foundation
import CoreImage
import CoreGraphics
import CoreImage.CIFilterBuiltins
import ImageIO

extension NSImage {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The colour layer behind the visualizer bars, matching the iPhone Dynamic Island: the
    /// album art shrunk, heavily blurred, a little less saturated and darker, so each bar takes the
    /// colours of the part of the art behind it (measured: hue kept, saturation ~0.75x, brightness ~0.85x).
    /// Made once per track off the main thread; the bars only mask it.
    ///
    /// Dark colours are lifted to `minimumBarBrightness` so bars never vanish into the black
    /// notch (a black cover gives light grey bars on the iPhone).
    func visualizerBackdrop(completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let side: CGFloat = 32
            let input = CIImage(cgImage: cgImage)
            let scale = side / max(input.extent.width, input.extent.height)

            let resize = CIFilter.lanczosScaleTransform()
            resize.inputImage = input
            resize.scale = Float(scale)
            resize.aspectRatio = 1

            let blur = CIFilter.gaussianBlur()
            // Clamping first keeps the edges from fading to transparent.
            blur.inputImage = resize.outputImage?.clampedToExtent()
            blur.radius = 4

            let colour = CIFilter.colorControls()
            colour.inputImage = blur.outputImage
            colour.saturation = 0.75

            // The iPhone's bars sit ~15% darker than the blurred art (measured on the same song).
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = colour.outputImage
            exposure.ev = -0.5  // in linear light; about 0.85x on screen

            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let width = Int(side), height = Int(side)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let space = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let output = exposure.outputImage?.cropped(to: rect),
                  let blurred = Self.ciContext.createCGImage(output, from: rect),
                  let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space, bitmapInfo: info)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            context.draw(blurred, in: rect)
            Self.liftToMinimumBrightness(rgba: &pixels, minimum: Self.minimumBarBrightness)

            guard let lifted = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: space, bitmapInfo: info)?.makeImage()
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let image = NSImage(cgImage: lifted, size: NSSize(width: side, height: side))
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

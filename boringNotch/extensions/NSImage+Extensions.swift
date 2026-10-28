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

    func averageColor(completion: @escaping (NSColor?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            // A small thumbnail gives the same average as every pixel of a full-size image.
            let width = min(cgImage.width, 32)
            let height = min(cgImage.height, 32)
            let totalPixels = width * height
            
            guard let context = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            guard let data = context.data else {
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
            
            var totalRed: UInt64 = 0
            var totalGreen: UInt64 = 0
            var totalBlue: UInt64 = 0
            
            for i in 0..<totalPixels {
                let color = pointer[i]
                totalRed += UInt64(color & 0xFF)
                totalGreen += UInt64((color >> 8) & 0xFF)
                totalBlue += UInt64((color >> 16) & 0xFF)
            }
            
            let averageRed = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
            let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
            let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0
            
            let minBrightness: CGFloat = 0.5
            let isNearBlack = averageRed < 0.03 && averageGreen < 0.03 && averageBlue < 0.03
            
            var finalColor: NSColor
            
            if isNearBlack {
                // If it's near black, just return a gray color with the minimum brightness
                finalColor = NSColor(white: minBrightness, alpha: 1.0)
            } else {
                var color = NSColor(red: averageRed, green: averageGreen, blue: averageBlue, alpha: 1.0)
                
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                
                if brightness < minBrightness {
                    // Increase brightness while maintaining hue and reducing saturation
                    let saturationScale = brightness / minBrightness
                    color = NSColor(hue: hue,
                                    saturation: saturation * saturationScale,
                                    brightness: minBrightness,
                                    alpha: alpha)
                }
                
                finalColor = color
            }
            
            DispatchQueue.main.async {
                completion(finalColor)
            }
        }
        
    }
    
    func getBrightness() -> CGFloat {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        
        let inputImage = CIImage(cgImage: cgImage)
        
        let filter = CIFilter.areaAverage()
        filter.inputImage = inputImage
        filter.extent = inputImage.extent
        
        guard let outputImage = filter.outputImage else {
            return 0
        }
        
        let context = CIContext(options: nil)
        
        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(outputImage,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        
        let brightness = (0.2126 * CGFloat(bitmap[0]) + 0.7152 * CGFloat(bitmap[1]) + 0.0722 * CGFloat(bitmap[2])) / 255.0
        
        return brightness
    }
}

extension Color {
    func ensureMinimumBrightness(factor: CGFloat) -> Color {
        guard factor >= 0 && factor <= 1 else {
            return self // Return original color if factor is out of bounds
        }
        
        let nsColor = NSColor(self)
        
        // Convert to RGB color space
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return self // Return original color if conversion fails
        }
        
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        rgbColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        
        // Calculate perceived brightness using the formula: (0.299*R + 0.587*G + 0.114*B)
        let perceivedBrightness = (0.2126 * red + 0.7152 * green + 0.0722 * blue)
        
        let scale = factor / perceivedBrightness
        red = min(red * scale, 1.0)
        green = min(green * scale, 1.0)
        blue = min(blue * scale, 1.0)
        
        return Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
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

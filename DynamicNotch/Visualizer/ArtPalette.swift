//
//  ArtPalette.swift
//  DynamicNotch
//
//  The visualizer's colours, taken from the album art.
//

import AppKit
import simd

/// A dark backdrop and four accent colours picked from a cover (k-means on a 32 x 32 copy),
/// so every album gets its own look: the navy-and-gold Stardust cover gives a deep navy
/// field with gold light.
struct ArtPalette: Equatable {
    var background: SIMD3<Float>
    var accents: [SIMD3<Float>] // always 4

    static let fallback = ArtPalette(
        background: SIMD3(0.04, 0.03, 0.10),
        accents: [SIMD3(0.98, 0.33, 0.55), SIMD3(0.45, 0.35, 1.0), SIMD3(0.15, 0.75, 0.95), SIMD3(1.0, 0.68, 0.30)])

    static func make(from image: NSImage) -> ArtPalette {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .fallback }
        return make(from: cg)
    }

    static func make(from image: CGImage) -> ArtPalette {
        // Big enough that thin coloured lines (line art on white) survive the downscale.
        let side = 128
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .fallback }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(side * side)
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i + 3] > 128 {
            pixels.append(SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255)
        }
        guard pixels.count > 16 else { return .fallback }
        return make(pixels: pixels)
    }

    static func make(pixels: [SIMD3<Float>]) -> ArtPalette {
        let clusters = kMeans(pixels, k: 6)
        guard let largest = clusters.max(by: { $0.count < $1.count }) else { return .fallback }
        if let lineArt = lineArtPalette(pixels: pixels, largest: largest.colour) { return lineArt }

        // The backdrop: the cover's main colour, kept dark so the light reads.
        var bg = hsb(largest.colour)
        bg.y = min(bg.y, 0.85)
        bg.z = max(0.035, min(0.15, bg.z * 0.35))
        let background = rgb(bg)

        let maxSaturation = clusters.map { hsb($0.colour).y }.max() ?? 0
        let total = Float(pixels.count)
        // Accents: colourful, bright clusters that stand out from the backdrop first, weighted
        // by how much of the cover they cover (gold lettering on navy beats the navy).
        let scored = clusters.map { c -> (SIMD3<Float>, Float) in
            let h = hsb(c.colour)
            let share = sqrtf(Float(c.count) / total)
            let contrast = simd_distance(c.colour, largest.colour)
            return (c.colour, share * (0.25 + h.y * 1.5) * (0.35 + h.z) * (0.5 + contrast))
        }.sorted { $0.1 > $1.1 }

        var accents: [SIMD3<Float>] = []
        for (colour, _) in scored {
            var h = hsb(colour)
            if maxSaturation < 0.12 {
                h.y = 0 // a black-and-white cover stays black and white
            } else {
                h.y = min(1, max(h.y * 1.2, 0.35))
            }
            h.z = max(h.z, 0.6)
            let accent = rgb(h)
            if accents.allSatisfy({ simd_distance($0, accent) > 0.14 }) { accents.append(accent) }
            if accents.count == 4 { break }
        }
        if accents.isEmpty { return .fallback }
        // Too few distinct colours: neighbours of the first in hue (or brightness, if grey).
        let base = hsb(accents[0])
        var shift: Float = 1
        while accents.count < 4 {
            var h = base
            if maxSaturation < 0.12 {
                h.z = max(0.45, base.z - 0.18 * shift)
            } else {
                h.x = (base.x + 0.035 * shift + 1).truncatingRemainder(dividingBy: 1)
                h.z = min(1, base.z * (shift > 0 ? 1.1 : 0.85))
            }
            accents.append(rgb(h))
            shift = shift > 0 ? -shift : -shift + 1
        }
        return ArtPalette(background: background, accents: accents)
    }

    /// A mostly white, grey or black cover with a little strong colour in it (blue line art
    /// on white): averaging would turn it grey, so the colour leads instead. The backdrop is
    /// that colour in the dark, and a white cover's white comes back as a highlight.
    private static func lineArtPalette(pixels: [SIMD3<Float>], largest: SIMD3<Float>) -> ArtPalette? {
        let main = hsb(largest)
        guard main.y < 0.15 else { return nil }
        let colourful = pixels.filter { let h = hsb($0); return h.y > 0.22 && h.z > 0.2 }
        guard colourful.count >= max(12, pixels.count / 100) else { return nil }

        let colours = kMeans(colourful, k: 3).sorted { $0.count > $1.count }
        guard let lead = colours.first else { return nil }
        let leadHSB = hsb(lead.colour)
        let background = rgb(SIMD3(leadHSB.x, min(0.9, max(0.6, leadHSB.y)), 0.11))

        var accents: [SIMD3<Float>] = []
        for c in colours {
            var h = hsb(c.colour)
            // Line art blends into the white around it when scaled down: restore its strength.
            h.y = min(1, max(h.y * 1.4, 0.8))
            h.z = max(h.z, 0.75)
            let accent = rgb(h)
            if accents.allSatisfy({ simd_distance($0, accent) > 0.14 }) { accents.append(accent) }
        }
        // Slot 2 is the second broad light: a neighbour of the lead colour if there's no other.
        if accents.count < 2 {
            var h = hsb(accents[0])
            h.x = (h.x - 0.045 + 1).truncatingRemainder(dividingBy: 1)
            h.y *= 0.85
            accents.append(rgb(h))
        }
        // Slot 3 is the small highlights: the cover's own white, if it's a light cover.
        if main.z > 0.75 {
            accents.insert(SIMD3(repeating: 0.95), at: 2)
        }
        var shift: Float = -1
        while accents.count < 4 {
            var h = hsb(accents[0])
            h.x = (h.x + 0.035 * shift + 1).truncatingRemainder(dividingBy: 1)
            accents.append(rgb(h))
            shift = -shift
        }
        return ArtPalette(background: background, accents: Array(accents.prefix(4)))
    }

    // MARK: Helpers

    private struct Cluster { var colour: SIMD3<Float>; var count: Int }

    private static func kMeans(_ pixels: [SIMD3<Float>], k: Int) -> [Cluster] {
        // Deterministic seeds spread across brightness.
        let sorted = pixels.sorted { simd_reduce_add($0) < simd_reduce_add($1) }
        var centres = (0 ..< k).map { sorted[min(sorted.count - 1, (2 * $0 + 1) * sorted.count / (2 * k))] }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0 ..< 10 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for p in pixels {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for (i, c) in centres.enumerated() {
                    let d = simd_distance_squared(p, c)
                    if d < bestD { bestD = d; best = i }
                }
                sums[best] += p
                counts[best] += 1
            }
            for i in 0 ..< k where counts[i] > 0 { centres[i] = sums[i] / Float(counts[i]) }
        }
        return (0 ..< k).filter { counts[$0] > 0 }.map { Cluster(colour: centres[$0], count: counts[$0]) }
    }

    /// RGB to (hue, saturation, brightness), each 0...1.
    static func hsb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let maxC = c.max(), minC = c.min()
        let delta = maxC - minC
        var hue: Float = 0
        if delta > 1e-5 {
            if maxC == c.x { hue = ((c.y - c.z) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == c.y { hue = (c.z - c.x) / delta + 2 }
            else { hue = (c.x - c.y) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return SIMD3(hue, maxC > 0 ? delta / maxC : 0, maxC)
    }

    static func rgb(_ h: SIMD3<Float>) -> SIMD3<Float> {
        let k = SIMD3<Float>(5, 3, 1) + h.x * 6
        let kk = SIMD3<Float>(k.x.truncatingRemainder(dividingBy: 6), k.y.truncatingRemainder(dividingBy: 6), k.z.truncatingRemainder(dividingBy: 6))
        let t = simd_clamp(simd_min(kk, 4 - kk), SIMD3(repeating: 0), SIMD3(repeating: 1))
        return h.z - h.z * h.y * t
    }
}

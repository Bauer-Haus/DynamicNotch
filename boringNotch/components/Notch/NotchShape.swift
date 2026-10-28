//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        // Top corners are true quarter circles (cubic, k = 0.5523), like the hardware notch's
        // rounded corners; a quadratic curve only approximated one.
        let k: CGFloat = 0.5523
        path.addCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY + topCornerRadius
            ),
            control1: CGPoint(
                x: rect.minX + topCornerRadius * k,
                y: rect.minY
            ),
            control2: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY + topCornerRadius * (1 - k)
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius + bottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius - bottomCornerRadius,
                y: rect.maxY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius
            )
        )

        path.addCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control1: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius * (1 - k)
            ),
            control2: CGPoint(
                x: rect.maxX - topCornerRadius * k,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        return path
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}

/// The soft blur behind the open island, like the iPhone's: strongest at the island's edge,
/// fading out over `islandHaloMargin`. It fills the window, with the island at the top centre.
struct IslandBackdrop: NSViewRepresentable {
    var visible: Bool
    /// The open island's laid-out size, top corners included (as `NotchShape` is given it).
    var islandSize: CGSize

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow // the most neutral: darkens the least of the materials (measured)
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(for: islandSize)
        view.alphaValue = 0
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let mask = Self.mask(for: islandSize)
        if view.maskImage !== mask { view.maskImage = mask }
        let target: CGFloat = visible ? 1 : 0
        guard view.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = visible ? 0.25 : 0.3
            view.animator().alphaValue = target
        }
    }

    /// How much of the blur shows, by distance (pt) from the island's edge on the iPhone:
    /// one minus the share of background detail the iPhone keeps there, after taking out what
    /// its shadow's darkening accounts for.
    static let strengthByDistance: [(distance: CGFloat, strength: CGFloat)] = [
        (0, 0.7), (5, 0.5), (10, 0.25), (20, 0.17), (50, 0.15), (80, 0.12), (120, 0.05), (143, 0),
    ]

    /// Blur strength `distance` pt outside the island, on the Mac (scaled like the player).
    static func strength(atDistance distance: CGFloat) -> CGFloat {
        let d = distance / openPlayerScale
        let table = strengthByDistance
        guard d > table[0].distance else { return table[0].strength }
        for (a, b) in zip(table, table.dropFirst()) where d <= b.distance {
            let t = (d - a.distance) / (b.distance - a.distance)
            return a.strength + (b.strength - a.strength) * t
        }
        return 0
    }

    /// Distance (pt) from `point` to the visible island, zero inside it. `point` is measured
    /// from the window's top-left corner; the island hangs from the top centre. Its body is
    /// `islandSize` less the top corners, which curve outwards only in its top few points.
    static func distanceToIsland(_ point: CGPoint, islandSize: CGSize) -> CGFloat {
        let width = islandSize.width - 2 * cornerRadiusInsets.opened.top, height = islandSize.height
        let radius = cornerRadiusInsets.opened.bottom
        let center = CGPoint(x: windowSize.width / 2, y: height / 2)
        // Only the bottom corners are round; the top edge meets the screen edge.
        let r = point.y > center.y ? radius : 0
        let qx = abs(point.x - center.x) - (width / 2 - r)
        let qy = abs(point.y - center.y) - (height / 2 - r)
        let outside = hypot(max(qx, 0), max(qy, 0))
        return max(0, outside + min(max(qx, qy), 0) - r)
    }

    @MainActor private static var maskCache: (size: CGSize, image: NSImage)?

    /// The fade, as an alpha mask the size of the window. Made once per island size.
    @MainActor static func mask(for islandSize: CGSize) -> NSImage {
        if let cached = maskCache, cached.size == islandSize { return cached.image }
        let scale = 2
        let width = Int(windowSize.width) * scale, height = Int(windowSize.height) * scale
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(scale), y: (CGFloat(y) + 0.5) / CGFloat(scale))
                // Under the island it's hidden; the edge's strength carries on there so no seam shows.
                let value = strength(atDistance: distanceToIsland(point, islandSize: islandSize))
                alpha[y * width + x] = UInt8((value * 255).rounded())
            }
        }
        let cgImage = alpha.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )?.makeImage()
        }
        let image = cgImage.map { NSImage(cgImage: $0, size: windowSize) } ?? NSImage(size: windowSize)
        maskCache = (islandSize, image)
        return image
    }
}

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
    /// A bottom edge that moves on its own curve while the shape shrinks; nil follows the frame.
    private var bottomTravel: BottomTravel?
    /// Counts up by one per trip, animated.
    private var bottomProgress: CGFloat

    /// The bottom edge going from `from` to `to` pt below the top as `bottomProgress` goes from
    /// `start` to `start + 1`, then staying at `to` until the travel is cleared.
    struct BottomTravel: Equatable {
        var from: CGFloat
        var to: CGFloat
        var start: CGFloat
    }

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil,
        bottomTravel: BottomTravel? = nil,
        bottomProgress: CGFloat = 0
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
        self.bottomTravel = bottomTravel
        self.bottomProgress = bottomProgress
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            .init(.init(topCornerRadius, bottomCornerRadius), bottomProgress)
        }
        set {
            topCornerRadius = newValue.first.first
            bottomCornerRadius = newValue.first.second
            bottomProgress = newValue.second
        }
    }

    /// Where the bottom edge is drawn, or nil to follow the frame.
    static func bottomLimit(_ travel: BottomTravel?, progress: CGFloat) -> CGFloat? {
        guard let travel else { return nil }
        let fraction = min(max(progress - travel.start, 0), 1)
        return travel.from + (travel.to - travel.from) * fraction
    }

    func path(in rect: CGRect) -> Path {
        let limit = Self.bottomLimit(bottomTravel, progress: bottomProgress) ?? rect.height
        let rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, limit))
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


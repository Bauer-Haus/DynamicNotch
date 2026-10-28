//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect
    /// An exact icon size (the open notch's controls); otherwise `scale` picks the size.
    var pointSize: CGFloat? = nil

    init(icon: String, iconColor: Color = .primary, scale: Image.Scale = .medium,
         pointSize: CGFloat? = nil, contentTransition: ContentTransition = .symbolEffect,
         action: @escaping () -> Void) {
        self.icon = icon
        self.iconColor = iconColor
        self.scale = scale
        self.pointSize = pointSize
        self.contentTransition = contentTransition
        self.action = action
    }
    
    @State private var isHovering = false

    var body: some View {
        let size = pointSize.map { max(30, $0 * 1.1) } ?? CGFloat(scale == .large ? 40 : 30)

        Button(action: action) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: size, height: size)
                .overlay {
                    Capsule()
                        .fill(isHovering && pointSize == nil ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(pointSize.map { .system(size: $0) } ?? (scale == .large ? .largeTitle : .body))
                        }
                }
        }
        .buttonStyle(IslandPressStyle(enabled: pointSize != nil, hovering: isHovering))
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
    }
}

/// The press feedback of the iPhone's expanded Dynamic Island, measured from a 120 fps
/// recording: a dark grey circle (24/255, ~61 pt on the iPhone, ~80 pt at this island's
/// scale) appears under the button and the icon shrinks to ~0.7x; on release the circle
/// fades over 0.2 s, then the icon springs back with a small overshoot.
struct IslandPressStyle: ButtonStyle {
    var enabled: Bool
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        if enabled {
            IslandPressBody(configuration: configuration, hovering: hovering)
        } else {
            configuration.label
        }
    }

    static let circleDiameter: CGFloat = 80
    static let circleColor = Color(white: 24.0 / 255)
    static let pressedScale: CGFloat = 0.7
    static let fadeDuration: TimeInterval = 0.2
}

private struct IslandPressBody: View {
    let configuration: ButtonStyleConfiguration
    let hovering: Bool
    @State private var circle: Double = 0
    @State private var shrunk = false
    @State private var springBack: Task<Void, Never>?

    var body: some View {
        configuration.label
            .scaleEffect(shrunk ? IslandPressStyle.pressedScale : 1)
            .background {
                Circle()
                    .fill(IslandPressStyle.circleColor)
                    .frame(width: IslandPressStyle.circleDiameter, height: IslandPressStyle.circleDiameter)
                    // A faint circle on hover is the Mac's extra; pressing shows it in full.
                    .opacity(max(circle, hovering ? 0.45 : 0))
                    .allowsHitTesting(false)
            }
            .onChange(of: configuration.isPressed) { _, pressed in
                springBack?.cancel()
                if pressed {
                    circle = 1  // at once, like the iPhone
                    withAnimation(.easeOut(duration: 0.04)) { shrunk = true }
                } else {
                    withAnimation(.easeOut(duration: IslandPressStyle.fadeDuration)) { circle = 0 }
                    springBack = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(IslandPressStyle.fadeDuration))
                        guard !Task.isCancelled else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { shrunk = false }
                    }
                }
            }
    }
}

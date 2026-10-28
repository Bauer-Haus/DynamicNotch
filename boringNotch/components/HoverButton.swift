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
                        .fill(isHovering ? Color.gray.opacity(0.2) : .clear)
                        .frame(width: size, height: size)
                        .overlay {
                            Image(systemName: icon)
                                .foregroundColor(iconColor)
                                .contentTransition(contentTransition)
                                .font(pointSize.map { .system(size: $0) } ?? (scale == .large ? .largeTitle : .body))
                        }
                }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.3)) {
                isHovering = hovering
            }
        }
    }
}

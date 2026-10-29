//
//  SettingsComponents.swift
//  DynamicNotch
//
//  The building blocks of the Settings pages: coloured icon tiles and row labels.
//

import SwiftUI

/// A white symbol on a coloured rounded square, like the icons in System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

/// A settings row's label: icon, title and an optional line of explanation.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    let symbol: String
    let color: Color

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, symbol: String, color: Color) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A slider row with its label on the left and the current value on the right.
struct SettingsSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let label: SettingsLabel
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let format: (V) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .padding(.leading, 30)
        }
    }
}

//
//  ConditionalModifier.swift
//  DynamicNotch
//
//  Applies a view modifier only when a condition is true.
//

import SwiftUI

extension View {
    @ViewBuilder func conditionalModifier<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

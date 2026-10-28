//
//  WelcomeView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .padding(.bottom, 8)
            Text("DynamicNotch")
                .font(.system(.largeTitle, design: .default))
                .fontWeight(.semibold)
            Text("Welcome")
                .font(.title)
                .foregroundStyle(.secondary)
                .padding(.bottom, 30)
            Button {
                onGetStarted?()
            } label: {
                Text("Get started")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
            }
            .buttonStyle(BorderedProminentButtonStyle())
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
}

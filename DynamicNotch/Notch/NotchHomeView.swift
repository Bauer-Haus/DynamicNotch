//
//  NotchHomeView.swift
//  DynamicNotch
//
//  What the open notch shows: the music player.
//

import AVKit
import Combine
import Defaults
import SwiftUI

struct NotchHomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var coordinator = NotchCoordinator.shared
    let albumArtNamespace: Namespace.ID
    /// Opening, the player starts as blurred as a close leaves it and comes into focus.
    @State private var inFocus = false

    /// The blur a close goes to, and an open starts from.
    static let closedBlur: CGFloat = 30
    /// On the close's curve, so opening is the close played backwards.
    static let focusAnimation = Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.4)

    var body: some View {
        Group {
            if !coordinator.firstLaunch {
                mainContent
            }
        }
        // simplified: use a straightforward opacity transition
        .transition(.opacity)
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 15) {
            MusicPlayerView(albumArtNamespace: albumArtNamespace)
        }
        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
        .blur(radius: vm.notchState == .closed || !inFocus ? Self.closedBlur : 0)
        .onAppear {
            withAnimation(Self.focusAnimation) { inFocus = true }
        }
    }
}

//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Bauer Jardine on 10/28/2026.
//

import AVFoundation
import Combine
import Defaults
import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.enableGestures) var enableGestures
    @Default(.closeGestureEnabled) var closeGestureEnabled
    @Default(.mediaSwipeGestures) var mediaSwipeGestures
    /// One track change per swipe, however far it goes.
    @State private var mediaSwipeHandled = false

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    /// Width of the visualizer slot on the right of the closed notch: the album-art square.
    /// The bars are as tall as the art and, at Apple's proportions, ~0.94 of that wide.
    private var visualizerWidth: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (max(0, vm.effectiveClosedNotchHeight - 12) + visualizerWidth + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    // Open: the iPhone island's margins (28 pt at the sides, 24 pt below), scaled.
                    .padding(.horizontal, vm.notchState == .open ? 28 * openPlayerScale : 0)
                    .padding(.bottom, vm.notchState == .open ? 24 * openPlayerScale : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    // Top-aligned: content taller than this frame used to be centred, which pushed the
                    // open notch ~7 pt above the screen and hid its top corners.
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil, alignment: .top)
                    .conditionalModifier(true) { view in
                        // Same slight bounce as before, settling in ~0.25 s instead of ~0.33 s.
                        let openAnimation = Animation.spring(response: 0.32, dampingFraction: 0.8, blendDuration: 0)
                        // An eased curve, not a spring. Measured frame by frame on a recording: a
                        // no-bounce spring crawled over its last pixels (top corners ~55 ms late, a
                        // visible adjustment); a slightly bouncy one shrank 1 px too far and came back
                        // (a twitch). This never overshoots, every part lands within one frame of the
                        // others, and it settles in ~0.37 s.
                        let closeAnimation = Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.4)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(enableGestures) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(closeGestureEnabled && enableGestures) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(mediaSwipeGestures && enableGestures) { view in
                        view
                            .panGesture(direction: .left) { translation, phase in
                                handleMediaSwipe(translation: translation, phase: phase, next: true)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handleMediaSwipe(translation: translation, phase: phase, next: false)
                            }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        // No default 8 pt gap between the space under the camera and the player.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading) {
                if vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed {
                    MusicLiveActivity()
                        .frame(alignment: .center)
                } else if vm.notchState == .open {
                    // The open player starts below the menu bar (or the camera housing).
                    Color.clear
                        .frame(height: max(24, vm.effectiveClosedNotchHeight))
                } else {
                    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                }
            }
            .zIndex(2)
            if vm.notchState == .open {
                NotchHomeView(albumArtNamespace: albumArtNamespace)
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.25))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        HStack {
            Image(nsImage: musicManager.displayedAlbumArt)
                .resizable()
                .clipped()
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed)
                )
                .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + -cornerRadiusInsets.closed.top)

            HStack {
                // Like the iPhone: the bars are windows onto blurred album art.
                AlbumWaveform(width: visualizerWidth, height: max(0, vm.effectiveClosedNotchHeight - 12))
                    .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
            }
            .frame(
                width: max(
                    0,
                    visualizerWidth
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }
                    
                    if self.vm.notchState == .open {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    /// Swipe left for the next track, right for the previous one, while the notch is open.
    private func handleMediaSwipe(translation: CGFloat, phase: NSEvent.Phase, next: Bool) {
        guard vm.notchState == .open else { return }
        if phase == .ended {
            mediaSwipeHandled = false
            return
        }
        // Half the open/close distance: sideways swipes are shorter than vertical ones.
        guard !mediaSwipeHandled, translation > Defaults[.gestureSensitivity] / 2 else { return }
        mediaSwipeHandled = true
        if next {
            MusicManager.shared.nextTrack()
        } else {
            MusicManager.shared.previousTrack()
        }
        if Defaults[.enableHaptics] {
            haptics.toggle()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            gestureProgress = .zero
            vm.close()

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}



#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}

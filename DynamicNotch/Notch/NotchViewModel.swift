//
//  NotchViewModel.swift
//  DynamicNotch
//
//  One notch's state (open or closed, its size, which screen) and the open and close
//  actions.
//

import Combine
import Defaults
import SwiftUI

class NotchViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = NotchCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let animationLibrary: NotchAnimations = .init()
    let animation: Animation?

    @Published var contentType: ContentType = .normal
    @Published private(set) var notchState: NotchState = .closed

    var cancellables: Set<AnyCancellable> = []
    
    @Published var hideOnClosed: Bool = true

    /// Like the iPhone's Dynamic Island: a close shrinks the open notch all the way to the bare
    /// notch first, and only then does the closed player (cover and waveform) grow out of it.
    /// True while that shrink runs.
    @Published private(set) var closedPlayerHeld = false
    /// True while the closed player grows out after that. Its cover and waveform are unlinked
    /// from the open player's then: linked, they slid up from where the open ones had been.
    @Published private(set) var closedPlayerGrowing = false
    private var closeID = 0
    /// The close takes 0.4 s but is within a few points of the bare notch by ~0.28 s, so the
    /// player starts then: any later and the bare notch sits there for a beat.
    private static let closedPlayerDelay: TimeInterval = 0.28
    static let closedPlayerSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)

    @Published var edgeAutoOpenActive: Bool = false

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    
    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil) {
        animation = animationLibrary.animation

        super.init()
        
        self.screenUUID = screenUUID
        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize

        setupDetectorObserver()
    }
    
    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        // Combine all three: screen UUID, fullscreen status, and enabled setting
        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    /// A black strip under the closed notch down to the bottom of the menu bar, when the
    /// notch is shorter than the menu bar.
    var chinHeight: CGFloat {
        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        if notchState == .open { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    
    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2
            
            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }
        
        return false
    }

    func open() {
        closeID += 1
        closedPlayerHeld = false
        closedPlayerGrowing = false
        self.notchSize = openNotchSize
        self.notchState = .open
        
        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()
    }

    func close() {
        if notchState == .open {
            closeID += 1
            let id = closeID
            closedPlayerHeld = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closedPlayerDelay) { [weak self] in
                guard let self, self.closeID == id else { return }
                self.closedPlayerGrowing = true
                withAnimation(Self.closedPlayerSpring) { self.closedPlayerHeld = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.closeID == id else { return }
                    self.closedPlayerGrowing = false
                }
            }
        }
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.edgeAutoOpenActive = false
    }

}

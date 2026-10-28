//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    
    @Published var fullscreenStatus: [String: Bool] = [:]
    
    private var monitorTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Last full-screen spaces seen, so a setting or music-app change can be re-applied
    /// right away instead of waiting for the next space change.
    private var spaces: [FullScreenMonitor.SpaceInfo] = []
    
    private init() {
        startMonitoring()

        Defaults.publisher(.hideNotchOption, options: [])
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
            .store(in: &cancellables)
        MusicManager.shared.$bundleIdentifier
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.updateStatus() } }
            .store(in: &cancellables)
    }
    
    deinit {
        monitorTask?.cancel()
    }
    
    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                self.spaces = spaces
                updateStatus()
            }
        }
    }
    
    private func updateStatus() {
        let option = Defaults[.hideNotchOption]
        let musicSourceBundle = MusicManager.shared.bundleIdentifier
        var newStatus: [String: Bool] = [:]
        
        for space in spaces {
            guard let uuid = space.screenUUID else { continue }
            newStatus[uuid] = Self.shouldHide(option: option, fullscreenApps: space.runningApps, musicSource: musicSourceBundle)
        }
        
        if newStatus != fullscreenStatus {
            fullscreenStatus = newStatus
        }
    }

    /// Whether the closed notch hides on a screen showing these full-screen apps.
    nonisolated static func shouldHide(option: HideNotchOption, fullscreenApps: [String], musicSource: String?) -> Bool {
        switch option {
        case .always:
            return true
        case .nowPlayingOnly:
            // Only when the full-screen app is the one playing music.
            return musicSource.map { fullscreenApps.contains($0) } ?? false
        case .never:
            return false
        }
    }
}


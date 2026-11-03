//
//  TapHealth.swift
//  DynamicNotch
//
//  Decides whether the waveform's audio tap still works or must be rebuilt. Kept free of
//  Core Audio so every way a tap can fail is covered by unit tests.
//

import Foundation

enum TapHealth {
    /// Everything the check needs, as plain values. Times are CFAbsoluteTime seconds.
    struct State {
        var now: TimeInterval
        var isRunning: Bool
        var startedAt: TimeInterval
        /// Last time the tap delivered a buffer (0 if never).
        var lastCallback: TimeInterval
        /// Last time a buffer held real sound (0 if never).
        var lastSignal: TimeInterval
        /// Some tap has delivered real sound since launch, so capture is permitted.
        var captureConfirmed: Bool
        var silentRebuilds: Int
        /// Output device the tap is clocked by, and the current default output.
        var tappedDeviceUID: String?
        var currentDeviceUID: String?
        /// How long the current default output has been unchanged.
        var outputStableFor: TimeInterval
        /// The music app's audio processes the tap listens to (empty: tapping all output).
        var tappedProcesses: Set<UInt32>
        /// The music app's audio processes right now (empty if none or no target).
        var currentProcesses: Set<UInt32>
    }

    enum Reason: String, Equatable {
        /// No tap (never built, or building failed).
        case notRunning
        /// The default output is a different device than the tap is clocked by.
        case outputChanged
        /// The music app's audio now comes from different processes.
        case processesChanged
        /// Was tapping all output because the music app had no audio process; now it has.
        case betterTarget
        /// Delivered audio, then stopped delivering.
        case stalled
        /// Never delivered a single buffer.
        case neverDelivered
        /// Delivers buffers, but only silence, while music plays.
        case silent
    }

    /// Output must be unchanged this long before a tap is built for it: a Bluetooth device
    /// changes several times while it connects, and a tap built mid-switch may stay silent.
    static let outputSettleTime: TimeInterval = 0.5
    /// A tap that delivered and then went quiet this long is rebuilt.
    static let stallTime: TimeInterval = 1.5
    /// A new tap may take this long to deliver its first buffer. Before capture is known to
    /// work the system-audio permission dialog may be up; rebuilding then queues another
    /// request, so the dialog kept coming back after Allow.
    static let firstDeliveryTime: TimeInterval = 2
    static let permissionWaitTime: TimeInterval = 30
    /// How long a tap may deliver pure silence while music plays before it is rebuilt,
    /// growing with each try so a silent intro or a blocked permission doesn't rebuild it
    /// constantly. The first wait is short once capture is known to work: a tap that heard
    /// music and then only zeros has lost the music.
    static let silentWaits: [TimeInterval] = [3, 10, 30]
    static let confirmedSilentWaits: [TimeInterval] = [1.5, 3, 10, 30]

    /// What to do now: nil while the tap is healthy (or still starting up).
    static func check(_ s: State) -> Reason? {
        guard s.isRunning else { return .notRunning }

        if let current = s.currentDeviceUID, current != s.tappedDeviceUID,
           s.outputStableFor >= outputSettleTime {
            return .outputChanged
        }

        if !s.tappedProcesses.isEmpty, !s.currentProcesses.isEmpty, s.tappedProcesses != s.currentProcesses {
            return .processesChanged
        }
        if s.tappedProcesses.isEmpty, !s.currentProcesses.isEmpty {
            return .betterTarget
        }

        let delivered = s.lastCallback >= s.startedAt && s.lastCallback > 0
        if delivered {
            if s.now - s.lastCallback > stallTime { return .stalled }
        } else {
            let wait = s.captureConfirmed ? firstDeliveryTime : permissionWaitTime
            return s.now - s.startedAt > wait ? .neverDelivered : nil
        }

        let waits = s.captureConfirmed ? confirmedSilentWaits : silentWaits
        let wait = waits[min(s.silentRebuilds, waits.count - 1)]
        let soundSince = max(s.lastSignal, s.startedAt)
        if s.now - soundSince > wait { return .silent }
        return nil
    }
}

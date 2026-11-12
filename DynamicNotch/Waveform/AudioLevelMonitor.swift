//
//  AudioLevelMonitor.swift
//  DynamicNotch
//
//  Listens to the now-playing app's audio (a Core Audio process tap) and feeds it to the
//  spectrum analyzer.
//

import AppKit
import Foundation
import os

/// Time for the monitor: real in the app, simulated in tests.
protocol MonitorClock: AnyObject {
    func now() -> TimeInterval
    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void)
}

/// Raw audio (mono, left and right) and its sample rate.
typealias AudioSampleSink = (AudioSamples, Double) -> Void

final class SystemMonitorClock: MonitorClock {
    func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }
    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: block)
    }
}

/// Taps the output audio of the now-playing app and publishes band levels (0...1).
///
/// The analysis (SpectrumAnalyzer) reproduces the iPhone Dynamic Island waveform, fitted
/// to iPhone screen recordings. A 2048-sample window fits them better than 1024 or 4096; it
/// is analysed every 512 samples (~11 ms, so every 60 Hz frame has a fresh result) and shown
/// directly.
///
/// Threads: setup and teardown run on `queue`, audio arrives on `audioQueue`. They must stay
/// separate: stopping a tap waits for the audio callback in flight, so with both on one
/// queue a teardown during playback deadlocked the monitor until the app was restarted.
///
/// The tap listens to the music app directly and isn't tied to an output device, so
/// switching between speakers, AirPods and the iPhone needs nothing. It is kept working two
/// ways: a watchdog checks it twice a second while the bars are shown (TapHealth) and
/// rebuilds it if it stalls, goes silent or loses the music app; and if the setup queue ever
/// stops responding, the app restarts itself (the manual fix that always worked).
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor(system: CoreAudioTapSystem(), clock: SystemMonitorClock())

    static let bandCount = SpectrumAnalyzer.bandCount

    /// `log stream --predicate 'subsystem == "io.bauerhaus.boringnotch" && category == "waveform"'`
    static let log = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "waveform")

    static let watchdogInterval: TimeInterval = 0.5
    static let releaseGrace: TimeInterval = 0.5
    /// The setup queue not answering for this long means it is stuck.
    static let stuckTime: TimeInterval = 5

    private let system: AudioTapSystem
    private let clock: MonitorClock
    private let onStuck: () -> Void
    private let queue = DispatchQueue(label: "DynamicNotch.audioLevelMonitor", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "DynamicNotch.audioLevelMonitor.audio", qos: .userInteractive)

    // Touched only on `queue`.
    private var users = 0
    private var targetBundleID: String?
    private var tap: AudioTapHandle?
    private var startedAt: TimeInterval = 0
    /// The music app's processes the current tap listens to, to notice when they change.
    private var tappedProcesses: Set<UInt32> = []
    /// Rebuilds of a tap that delivered only silence, for TapHealth's back-off.
    private var silentRebuilds = 0
    private var observingOutput = false
    /// Bumped on every release, so a delayed teardown can tell it has been superseded.
    private var releaseGeneration = 0
    private var watchdogGeneration = 0
    private var watchdogRunning = false
    /// Last start failure logged, so a device that keeps refusing isn't logged every tick.
    private var lastFailure: AudioTapError?

    // Shared between queues, under `lock`.
    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastCallback: TimeInterval = 0
    private var _lastSignal: TimeInterval = 0
    private var _heardSignal = false
    /// Samples of real audio since the first sound, up to one analysis window. The tap
    /// starts with silence, and until a whole window of music has arrived the levels are
    /// computed partly from that silence (too low, or a jump on some bars).
    private var _signalSamples = 0
    /// Some tap has delivered real audio since launch, so audio capture is allowed and a
    /// tap that delivers nothing is broken rather than waiting on the permission dialog.
    private var _captureConfirmed = false
    /// Identifies the current tap; audio from an older one is ignored.
    private var _tapGeneration = 0
    /// When `ensureRunning` last asked the setup queue for an answer that hasn't come.
    private var _pingSentAt: TimeInterval?
    private var _stuckHandled = false
    /// Also gets every buffer of raw audio (the full-screen visualizer), on `audioQueue`.
    private var _sampleSink: AudioSampleSink?

    init(system: AudioTapSystem, clock: MonitorClock,
         onStuck: @escaping () -> Void = AudioLevelMonitor.restartApp) {
        self.system = system
        self.clock = clock
        self.onStuck = onStuck
    }

    /// Latest band levels, plus whether they are real (tap delivering actual audio).
    /// Shown as soon as they are computed: delaying them by the output device's reported
    /// latency (e.g. AirPods) made the bars trail the sound.
    func snapshot() -> (levels: [Float], isLive: Bool) {
        let now = clock.now()
        lock.lock(); defer { lock.unlock() }
        // A denied permission still delivers buffers, but they are all zeros. Until a full
        // analysis window of real audio has arrived, report not-live so the view waits.
        let fresh = now - _lastCallback < 0.5
        return (_levels, fresh && _heardSignal && _signalSamples >= SpectrumAnalyzer.fftSize)
    }

    /// Wakes Core Audio on the monitor's queue without capturing anything (no recording
    /// indicator). The first call into it takes ~70-80 ms; done at launch, that overlaps the
    /// wait for the player's first report, so a tap started moments later sets up in ~20 ms
    /// instead of ~90.
    func prepare() {
        queue.async { [system] in system.prepare() }
    }

    /// A view wants live levels. Balanced with `release()`.
    func retain() {
        queue.async { [weak self] in
            guard let self else { return }
            self.users += 1
            self.observeOutput()
            self.startLocked()
            self.startWatchdog()
        }
    }

    func release() {
        queue.async { [weak self] in
            guard let self else { return }
            self.users = max(0, self.users - 1)
            guard self.users == 0 else { return }
            // Opening the notch swaps the closed waveform for the open player's: one view
            // releases just before the other retains. Keep the tap briefly so the bars carry
            // on instead of restarting from dots.
            self.releaseGeneration += 1
            let generation = self.releaseGeneration
            self.clock.after(Self.releaseGrace, on: self.queue) { [weak self] in
                guard let self, self.users == 0, generation == self.releaseGeneration else { return }
                self.watchdogRunning = false
                self.teardown()
            }
        }
    }

    /// Sends every buffer of the tap's audio (mono, left and right), with its sample rate, to `sink` (on the
    /// audio queue) until replaced or cleared. Doesn't start the tap: pair with `retain()`.
    func setSampleSink(_ sink: AudioSampleSink?) {
        lock.lock()
        _sampleSink = sink
        lock.unlock()
    }

    /// The app whose audio should drive the bars (MusicManager's now-playing bundle id).
    func setTarget(bundleID: String?) {
        queue.async { [weak self] in
            guard let self, self.targetBundleID != bundleID else { return }
            self.targetBundleID = bundleID
            if self.users > 0 { self.rebuild("target changed to \(bundleID ?? "none")") }
        }
    }

    /// The bars aren't live: check the tap now rather than at the next watchdog tick, and
    /// notice if the setup queue has stopped answering.
    func ensureRunning() {
        let now = clock.now()
        lock.lock()
        if let sent = _pingSentAt {
            let stuck = now - sent > Self.stuckTime && !_stuckHandled
            if stuck { _stuckHandled = true }
            lock.unlock()
            if stuck {
                Self.log.fault("Waveform setup queue stuck for \(Int(now - sent)) s; restarting")
                onStuck()
            }
            return
        }
        _pingSentAt = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self._pingSentAt = nil
            self.lock.unlock()
            self.checkHealth()
        }
    }

    /// Waits until everything queued so far has run (tests).
    func sync() {
        queue.sync {}
    }

    static func restartApp() {
        DispatchQueue.main.async { ApplicationRelauncher.restart() }
    }

    // MARK: Keeping the tap alive (runs on `queue`)

    private func startWatchdog() {
        guard !watchdogRunning else { return }
        watchdogRunning = true
        watchdogGeneration += 1
        scheduleWatchdog(watchdogGeneration)
    }

    private func scheduleWatchdog(_ generation: Int) {
        clock.after(Self.watchdogInterval, on: queue) { [weak self] in
            guard let self, self.watchdogRunning, generation == self.watchdogGeneration else { return }
            self.checkHealth()
            self.scheduleWatchdog(generation)
        }
    }

    private func checkHealth() {
        guard users > 0 else { return }
        let now = clock.now()
        lock.lock()
        let lastCallback = _lastCallback
        let lastSignal = _lastSignal
        let captureConfirmed = _captureConfirmed
        lock.unlock()
        if lastSignal > 0, lastSignal >= startedAt { silentRebuilds = 0 }
        let state = TapHealth.State(
            now: now,
            isRunning: tap != nil,
            startedAt: startedAt,
            lastCallback: lastCallback,
            lastSignal: lastSignal,
            captureConfirmed: captureConfirmed,
            silentRebuilds: silentRebuilds,
            tappedProcesses: tappedProcesses,
            currentProcesses: Set(targetBundleID.map { system.processObjects(forBundleID: $0) } ?? []))
        guard let reason = TapHealth.check(state) else { return }
        if reason == .silent { silentRebuilds += 1 }
        // A failed start is retried every tick; startLocked logs the failure once.
        rebuild(reason.rawValue, quiet: reason == .notRunning)
    }

    private func rebuild(_ why: String, quiet: Bool = false) {
        if !quiet { Self.log.notice("Rebuilding tap: \(why, privacy: .public)") }
        teardown()
        startLocked()
    }

    private func observeOutput() {
        guard !observingOutput else { return }
        observingOutput = true
        system.observeOutput(on: queue) { [weak self] event in
            guard let self else { return }
            switch event {
            case .defaultDeviceChanged:
                Self.log.notice("Default output changed to \(self.system.defaultOutputName() ?? "none", privacy: .public)")
            }
            // The tap doesn't depend on the output, so nothing to rebuild. But if the switch
            // does upset it, react at the shortest silence wait rather than a backed-off one.
            self.silentRebuilds = 0
        }
    }

    // MARK: Setup (runs on `queue`)

    private func startLocked() {
        guard tap == nil, users > 0 else { return }

        // Prefer the now-playing app; otherwise listen to everything we output except ourselves.
        let processes = targetBundleID.map { system.processObjects(forBundleID: $0) } ?? []

        lock.lock()
        _tapGeneration += 1
        let generation = _tapGeneration
        lock.unlock()

        let result = system.startTap(processes: processes, deliveryQueue: audioQueue) { sampleRate in
            let analyzer = SpectrumAnalyzer(sampleRate: sampleRate)
            return { [weak self] samples in
                guard let analyzer else { return }
                self?.receive(samples, analyzer: analyzer, generation: generation)
            }
        }
        switch result {
        case .failure(let error):
            if error != lastFailure {
                lastFailure = error
                Self.log.error("Tap not started: \(error.description, privacy: .public)")
            }
        case .success(let handle):
            tap = handle
            tappedProcesses = Set(processes)
            startedAt = clock.now()
            lastFailure = nil
            Self.log.notice("""
                Tap started: \(processes.isEmpty ? "all output" : "\(processes.count) process(es) of \(self.targetBundleID ?? "?")", privacy: .public) \
                at \(handle.sampleRate, privacy: .public) Hz (output: \(self.system.defaultOutputName() ?? "none", privacy: .public))
                """)
        }
    }

    private func teardown() {
        if let tap { system.stopTap(tap) }
        tap = nil
        tappedProcesses = []
        lock.lock()
        _tapGeneration += 1
        _levels = [Float](repeating: 0, count: Self.bandCount)
        _lastCallback = 0
        _lastSignal = 0
        _heardSignal = false
        _signalSamples = 0
        lock.unlock()
    }

    // MARK: Audio (runs on `audioQueue`)

    private func receive(_ block: AudioSamples, analyzer: SpectrumAnalyzer, generation: Int) {
        let samples = block.mono
        var peak: Float = 0
        var analysed = false
        for v in samples {
            peak = max(peak, abs(v))
            if analyzer.push(v) { analysed = true }
        }
        let now = clock.now()
        let hasSignal = peak > 1e-6

        lock.lock()
        guard generation == _tapGeneration else {
            lock.unlock()
            return
        }
        _lastCallback = now
        let firstConfirmation = hasSignal && !_captureConfirmed
        if hasSignal {
            _heardSignal = true
            _lastSignal = now
            _captureConfirmed = true
        }
        if _heardSignal && _signalSamples < SpectrumAnalyzer.fftSize { _signalSamples += samples.count }
        if analysed { _levels = analyzer.levels }
        let sink = _sampleSink
        lock.unlock()

        sink?(block, analyzer.sampleRate)

        if firstConfirmation { Self.log.notice("Audio capture confirmed") }
    }
}

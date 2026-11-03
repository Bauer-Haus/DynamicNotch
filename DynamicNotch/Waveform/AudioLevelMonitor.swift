//
//  AudioLevelMonitor.swift
//  DynamicNotch
//
//  Listens to the now-playing app's audio (a Core Audio process tap) and feeds it to the
//  spectrum analyzer.
//

import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import os
import SwiftUI

/// Taps the output audio of the now-playing app and publishes band levels (0...1).
///
/// The analysis (SpectrumAnalyzer) reproduces the iPhone Dynamic Island waveform, fitted
/// to iPhone screen recordings. A 2048-sample window fits them better than 1024 or 4096; it is analysed every 512 samples (~11 ms, so every 60 Hz frame has a fresh
/// result) and shown directly.
///
/// The tap is kept working by two independent paths: Core Audio notifications (output
/// device or its sample rate changed) rebuild it straight away, and a watchdog checks it
/// twice a second while the bars are shown (see TapHealth) in case a notification is missed
/// or a rebuilt tap comes up dead or silent.
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor()

    static let bandCount = SpectrumAnalyzer.bandCount

    /// `log stream --predicate 'subsystem == "io.bauerhaus.boringnotch" && category == "waveform"'`
    static let log = os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "DynamicNotch", category: "waveform")

    private let queue = DispatchQueue(label: "DynamicNotch.audioLevelMonitor", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// Created per tap (it depends on the sample rate); used only on `queue`.
    private var analyzer: SpectrumAnalyzer?
    private var sampleRate: Double = 48000
    private var startedAt: CFAbsoluteTime = 0

    // Touched only on `queue`.
    private var users = 0
    private var targetBundleID: String?
    private var isRunning = false
    /// What the current tap was built for, to notice when either changes.
    private var tappedDeviceUID: String?
    private var tappedProcesses: Set<AudioObjectID> = []
    /// Rebuilds of a tap that delivered only silence, for TapHealth's back-off.
    private var silentRebuilds = 0
    /// Some tap has delivered real audio since launch, so audio capture is allowed and a
    /// tap that delivers nothing is broken rather than waiting on the permission dialog.
    private var captureConfirmed = false
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    /// Watches the output device's sample rate: AirPods change it while they connect.
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var sampleRateDevice = AudioObjectID(kAudioObjectUnknown)
    /// When the default output (or its sample rate) last changed.
    private var outputChangedAt: CFAbsoluteTime = 0
    /// Bumped on every output change, so only the last of a burst rebuilds the tap.
    private var outputChangeGeneration = 0
    private var watchdog: DispatchSourceTimer?
    static let watchdogInterval: TimeInterval = 0.5
    /// Last start failure logged, so a device that keeps refusing isn't logged every tick.
    private var lastFailure: String?

    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastCallback: CFAbsoluteTime = 0
    private var _lastSignal: CFAbsoluteTime = 0
    private var _heardSignal = false
    /// Bumped on every release, so a delayed teardown can tell it has been superseded.
    private var releaseGeneration = 0
    static let releaseGrace: TimeInterval = 0.5
    /// Samples of real audio since the first sound, up to one analysis window. The tap
    /// starts with silence, and until a whole window of music has arrived the levels are
    /// computed partly from that silence (too low, or a jump on some bars).
    private var _signalSamples = 0

    /// Latest band levels, plus whether they are real (tap delivering actual audio).
    /// Shown as soon as they are computed: delaying them by the output device's reported
    /// latency (e.g. AirPods) made the bars trail the sound.
    func snapshot() -> (levels: [Float], isLive: Bool) {
        lock.lock(); defer { lock.unlock() }
        // A denied permission still delivers buffers, but they are all zeros. Until a full
        // analysis window of real audio has arrived, report not-live so the view waits.
        let fresh = CFAbsoluteTimeGetCurrent() - _lastCallback < 0.5
        return (_levels, fresh && _heardSignal && _signalSamples >= SpectrumAnalyzer.fftSize)
    }

    /// Wakes Core Audio on the monitor's queue without capturing anything (no recording
    /// indicator). The first call into it takes ~70-80 ms; done at launch, that overlaps the
    /// wait for the player's first report, so a tap started moments later sets up in ~20 ms
    /// instead of ~90.
    func prepare() {
        queue.async {
            _ = Self.defaultOutputDeviceUID()
            _ = Self.ownProcessObject()
        }
    }

    /// A view wants live levels. Balanced with `release()`.
    func retain() {
        queue.async { [weak self] in
            guard let self else { return }
            self.users += 1
            self.startLocked()
            self.observeOutputDevice()
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
            self.queue.asyncAfter(deadline: .now() + Self.releaseGrace) { [weak self] in
                guard let self, self.users == 0, generation == self.releaseGeneration else { return }
                self.stopWatchdog()
                self.teardown()
            }
        }
    }

    /// The app whose audio should drive the bars (MusicManager's now-playing bundle id).
    func setTarget(bundleID: String?) {
        queue.async { [weak self] in
            guard let self, self.targetBundleID != bundleID else { return }
            self.targetBundleID = bundleID
            if self.users > 0 { self.rebuild("target changed to \(bundleID ?? "none")") }
        }
    }

    /// The bars aren't live: check the tap now rather than at the next watchdog tick.
    func ensureRunning() {
        queue.async { [weak self] in self?.checkHealth() }
    }

    // MARK: Keeping the tap alive (runs on `queue`)

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval,
                       leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func checkHealth() {
        guard users > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let lastCallback = _lastCallback
        let lastSignal = _lastSignal
        lock.unlock()
        let state = TapHealth.State(
            now: now,
            isRunning: isRunning,
            startedAt: startedAt,
            lastCallback: lastCallback,
            lastSignal: lastSignal,
            captureConfirmed: captureConfirmed,
            silentRebuilds: silentRebuilds,
            tappedDeviceUID: tappedDeviceUID,
            currentDeviceUID: Self.defaultOutputDeviceUID(),
            outputStableFor: now - outputChangedAt,
            tappedProcesses: tappedProcesses,
            currentProcesses: Set(targetBundleID.map { Self.processObjects(forBundleID: $0) } ?? []))
        guard let reason = TapHealth.check(state) else { return }
        if reason == .silent { silentRebuilds += 1 }
        // A failed start is retried every tick; log it once (startLocked logs the failure).
        rebuild(reason.rawValue, quiet: reason == .notRunning)
    }

    private func rebuild(_ why: String, quiet: Bool = false) {
        if !quiet { Self.log.notice("Rebuilding tap: \(why, privacy: .public)") }
        teardown()
        startLocked()
    }

    /// Switching output (e.g. to AirPods) changes the device the aggregate is clocked by,
    /// so rebuild the tap.
    private func observeOutputDevice() {
        observeOutputSampleRate()
        guard outputDeviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Self.log.notice("Default output changed to \(Self.defaultOutputDeviceName() ?? "none", privacy: .public)")
            self.observeOutputSampleRate()
            self.outputDidChange()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener) == noErr {
            outputDeviceListener = listener
        }
    }

    /// Moves the sample-rate listener to the current output device.
    private func observeOutputSampleRate() {
        let device = Self.defaultOutputDevice() ?? AudioObjectID(kAudioObjectUnknown)
        guard device != sampleRateDevice else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if let sampleRateListener, sampleRateDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(sampleRateDevice, &addr, queue, sampleRateListener)
        }
        sampleRateListener = nil
        sampleRateDevice = device
        guard device != kAudioObjectUnknown else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Self.log.notice("Output sample rate changed")
            self?.outputDidChange()
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener) == noErr {
            sampleRateListener = listener
        }
    }

    /// Rebuilds the tap once the output has stopped changing.
    private func outputDidChange() {
        outputChangedAt = CFAbsoluteTimeGetCurrent()
        silentRebuilds = 0
        outputChangeGeneration += 1
        let generation = outputChangeGeneration
        queue.asyncAfter(deadline: .now() + TapHealth.outputSettleTime) { [weak self] in
            guard let self, generation == self.outputChangeGeneration, self.users > 0 else { return }
            self.rebuild("output changed")
        }
    }

    // MARK: Setup

    private func startLocked() {
        guard !isRunning, users > 0 else { return }

        // Prefer the now-playing app; otherwise listen to everything we output except ourselves.
        let processes = targetBundleID.map { Self.processObjects(forBundleID: $0) } ?? []
        let desc: CATapDescription
        if processes.isEmpty {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        let outputUID = Self.defaultOutputDeviceUID()
        tappedProcesses = Set(processes)
        tappedDeviceUID = outputUID
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr else {
            failed("creating the tap", tapStatus)
            return
        }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        // The aggregate is clocked by the real output device, with the tap as its input.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicNotch-visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outputUID {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard aggStatus == noErr else {
            failed("creating the aggregate device", aggStatus)
            teardown()
            return
        }
        aggregateID = agg

        guard let analyzer = SpectrumAnalyzer(sampleRate: sampleRate) else {
            teardown()
            return
        }
        self.analyzer = analyzer

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, queue) { [weak self] _, inData, _, _, _ in
            self?.process(inData)
        }
        guard status == noErr, let procID else {
            failed("creating the IO proc", status)
            teardown()
            return
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(agg, procID)
        guard startStatus == noErr else {
            failed("starting the aggregate device", startStatus)
            teardown()
            return
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        isRunning = true
        lastFailure = nil
        Self.log.notice("""
            Tap started: \(processes.isEmpty ? "all output" : "\(processes.count) process(es) of \(self.targetBundleID ?? "?")", privacy: .public) \
            on \(Self.defaultOutputDeviceName() ?? "no output", privacy: .public) at \(self.sampleRate, privacy: .public) Hz
            """)
    }

    private func failed(_ step: String, _ status: OSStatus) {
        let message = "\(step) failed (\(status))"
        guard message != lastFailure else { return }
        lastFailure = message
        Self.log.error("Tap not started: \(message, privacy: .public)")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        analyzer = nil
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
        tappedDeviceUID = nil
        isRunning = false
        lock.lock()
        _levels = [Float](repeating: 0, count: Self.bandCount)
        _lastCallback = 0
        _lastSignal = 0
        _heardSignal = false
        _signalSamples = 0
        lock.unlock()
    }

    // MARK: Audio processing (runs on `queue`)

    private func process(_ inData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self),
              let analyzer else { return }

        // Mono-mix whatever layout we got (interleaved or one buffer per channel).
        var peak: Float = 0
        var analysed = false
        if buffers.count > 1 {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            for f in 0 ..< frames {
                var sum: Float = 0
                var n: Float = 0
                for b in buffers {
                    if let p = b.mData?.assumingMemoryBound(to: Float.self) { sum += p[f]; n += 1 }
                }
                let v = n > 0 ? sum / n : 0
                peak = max(peak, abs(v))
                if analyzer.push(v) { analysed = true }
            }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += base[f * channels + c] }
                let v = sum / Float(channels)
                peak = max(peak, abs(v))
                if analyzer.push(v) { analysed = true }
            }
        }

        let channelsPerBuffer = buffers.count > 1 ? 1 : max(1, Int(first.mNumberChannels))
        let framesThisCallback = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channelsPerBuffer

        let now = CFAbsoluteTimeGetCurrent()
        if peak > 1e-6 {
            silentRebuilds = 0
            if !captureConfirmed { Self.log.notice("Audio capture confirmed") }
            captureConfirmed = true
        }
        lock.lock()
        _lastCallback = now
        if peak > 1e-6 {
            _heardSignal = true
            _lastSignal = now
        }
        if _heardSignal && _signalSamples < SpectrumAnalyzer.fftSize { _signalSamples += framesThisCallback }
        if analysed { _levels = analyzer.levels }
        lock.unlock()
    }



    // MARK: Process / device lookup

    /// Audio process objects for an app, including its helpers (e.g. com.spotify.client.helper).
    private static func processObjects(forBundleID target: String) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.filter { id in
            guard let bundleID = stringProperty(id, kAudioProcessPropertyBundleID) else { return false }
            return bundleID == target || bundleID.hasPrefix(target + ".")
        }
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// The device music plays through.
    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func defaultOutputDeviceName() -> String? {
        defaultOutputDevice().flatMap { stringProperty($0, kAudioObjectPropertyName) }
    }

    private static func defaultOutputDeviceUID() -> String? {
        defaultOutputDevice().flatMap { stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

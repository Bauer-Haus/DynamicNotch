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
import SwiftUI

/// Taps the output audio of the now-playing app and publishes band levels (0...1).
///
/// The analysis (SpectrumAnalyzer) reproduces the iPhone Dynamic Island waveform, fitted
/// to iPhone screen recordings. A 2048-sample window fits them better than 1024 or 4096; it is analysed every 512 samples (~11 ms, so every 60 Hz frame has a fresh
/// result) and shown directly.
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor()

    static let bandCount = SpectrumAnalyzer.bandCount

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
    private var tappedBundleID: String?
    private var isRunning = false
    /// Rebuilds of a tap that only ever delivered silence, for the back-off below.
    private var silentRebuilds = 0
    /// How long a tap may deliver nothing but silence while music plays before it is rebuilt,
    /// growing with each try so a quiet intro or a blocked permission doesn't rebuild it
    /// constantly.
    static let silentRebuildWaits: [TimeInterval] = [3, 10, 30]
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastCallback: CFAbsoluteTime = 0
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
        }
    }

    /// Switching output (e.g. to AirPods) changes the device the aggregate is clocked by,
    /// so rebuild the tap.
    private func observeOutputDevice() {
        guard outputDeviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.users > 0 else { return }
            self.teardown()
            self.startLocked()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener) == noErr {
            outputDeviceListener = listener
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
                self.teardown()
            }
        }
    }

    /// The app whose audio should drive the bars (MusicManager's now-playing bundle id).
    func setTarget(bundleID: String?) {
        queue.async { [weak self] in
            guard let self, self.targetBundleID != bundleID else { return }
            self.targetBundleID = bundleID
            if self.users > 0 {
                self.teardown()
                self.startLocked()
            }
        }
    }

    /// Re-attach if the tap is missing or stalled (player relaunched, device changed),
    /// or if the target app has started producing audio since we fell back to all output.
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self, self.users > 0 else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.lock.lock()
            let lastCallback = self._lastCallback
            let heardSignal = self._heardSignal
            self.lock.unlock()
            // A tap that delivered audio and then stopped is reconnected quickly. One that
            // hasn't delivered yet is usually waiting on the system-audio permission dialog:
            // rebuilding it would queue another request, so the dialog kept coming back after
            // Allow. Give that case 30 s.
            let delivered = lastCallback >= self.startedAt
            let stalled = self.isRunning
                && (delivered ? now - lastCallback > 2 : now - self.startedAt > 30)
            let betterTarget = self.isRunning && self.tappedBundleID == nil && self.targetBundleID != nil
                && !Self.processObjects(forBundleID: self.targetBundleID!).isEmpty
            // Delivering, but only silence while the music plays (this is only called while
            // it plays and the bars aren't live). Seen after a Bluetooth speaker connected: the
            // tap rebuilt for it mid-switch passed on nothing but silence until a restart.
            let wait = Self.silentRebuildWaits[min(self.silentRebuilds, Self.silentRebuildWaits.count - 1)]
            let silent = self.isRunning && delivered && !heardSignal && now - self.startedAt > wait
            if silent { self.silentRebuilds += 1 }
            if stalled || betterTarget || silent { self.teardown() }
            self.startLocked()
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
            tappedBundleID = nil
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processes)
            tappedBundleID = targetBundleID
        }
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }
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
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg) == noErr else {
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
            teardown()
            return
        }
        ioProcID = procID

        guard AudioDeviceStart(agg, procID) == noErr else {
            teardown()
            return
        }
        startedAt = CFAbsoluteTimeGetCurrent()
        isRunning = true
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
        tappedBundleID = nil
        isRunning = false
        lock.lock()
        _levels = [Float](repeating: 0, count: Self.bandCount)
        _lastCallback = 0
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

        if peak > 1e-6 { silentRebuilds = 0 }
        lock.lock()
        _lastCallback = CFAbsoluteTimeGetCurrent()
        if peak > 1e-6 { _heardSignal = true }
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

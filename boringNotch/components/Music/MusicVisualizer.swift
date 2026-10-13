//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
//  The bars follow the real audio of the now-playing app (via a Core Audio
//  process tap + FFT). If that app's audio can't be found the tap listens to all
//  system output instead. If no audio arrives at all (permission denied, macOS
//  older than 14.2) the original random animation is used as a fallback.
//
import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import SwiftUI

// MARK: - Live audio levels

/// Taps the output audio of the now-playing app and publishes band levels (0...1).
///
/// The analysis reproduces the iPhone Dynamic Island waveform, fitted to 120 fps captures
/// of test tones, tone volume steps and pink noise: a 2048-sample Hann FFT, each bar summing the FFT magnitudes in its band (lightly normalised
/// by band width), mapped through a power curve. Nothing above ~10 kHz moves it, and a tone needs to be near full scale to
/// fill a bar. A 2048-sample window fits the iPhone captures better than 4096 and halves
/// the lag; it is analysed every 512 samples (~11 ms, so every 60 Hz frame has a fresh
/// result) and shown directly.
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor()

    static let bandCount = 6
    /// Band edges in Hz (bandCount + 1 values).
    private static let bandEdges: [Float] = [33.5, 93.75, 189.4, 553.3, 1828, 4945, 9997]
    /// Per-bar gain in dB applied to the band sum.
    private static let bandGainDB: [Float] = [3.67, -5.51, 1.31, -0.33, 1.07, -0.21]
    /// level = clamp(curveScale * (gain * sum / bins^widthExponent)^curveExponent - curveFloor, 0, 1)
    private static let curveScale: Float = 0.0330293
    private static let curveExponent: Float = 0.56783
    private static let curveFloor: Float = 0.08208
    /// The band sum is divided by (bin count)^widthExponent.
    private static let widthExponent: Float = 0.12749

    private let fftSize = 2048
    private let log2n: vDSP_Length = 11
    private let hopSize = 512
    private let queue = DispatchQueue(label: "boringNotch.audioLevelMonitor", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var fftSetup: FFTSetup?
    // Analysis buffers, allocated once per tap so the audio thread never allocates.
    private var window: [Float] = []
    private var ring: [Float] = []           // last fftSize mono samples, circular
    private var ringWrite = 0
    private var ringFilled = 0
    private var samplesSinceAnalysis = 0
    private var windowed: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitude: [Float] = []
    private var bandRanges: [Range<Int>] = []
    private var bandScale: [Float] = []
    private var bandLevels: [Float] = []
    private var sampleRate: Double = 48000
    private var startedAt: CFAbsoluteTime = 0

    // Touched only on `queue`.
    private var users = 0
    private var targetBundleID: String?
    private var tappedBundleID: String?
    private var isRunning = false
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastCallback: CFAbsoluteTime = 0
    private var _heardSignal = false

    /// Latest band levels, plus whether they are real (tap delivering actual audio).
    /// Shown as soon as they are computed: delaying them by the output device's reported
    /// latency (e.g. AirPods) made the bars trail the sound.
    func snapshot() -> (levels: [Float], isLive: Bool) {
        lock.lock(); defer { lock.unlock() }
        // A denied permission still delivers buffers, but they are all zeros. Until any
        // non-silent audio has arrived, report not-live so the view keeps animating.
        let fresh = CFAbsoluteTimeGetCurrent() - _lastCallback < 0.5
        return (_levels, fresh && _heardSignal)
    }

    /// A view wants live levels. Balanced with `release()`.
    func retain() {
        queue.async { [weak self] in
            guard let self else { return }
            self.users += 1
            self.observeOutputDevice()
            self.startLocked()
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
            if self.users == 0 { self.teardown() }
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
            self.lock.unlock()
            let stalled = self.isRunning && now - max(lastCallback, self.startedAt) > 2
            let betterTarget = self.isRunning && self.tappedBundleID == nil && self.targetBundleID != nil
                && !Self.processObjects(forBundleID: self.targetBundleID!).isEmpty
            if stalled || betterTarget { self.teardown() }
            self.startLocked()
        }
    }

    // MARK: Setup

    private func startLocked() {
        guard !isRunning, users > 0 else { return }
        // Process taps need macOS 14.2+; older systems keep the random animation.
        guard #available(macOS 14.2, *) else { return }

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
            kAudioAggregateDeviceNameKey: "boringNotch-visualizer",
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

        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        // Symmetric Hann, unnormalised (the curve constants were fitted with this window).
        for n in 0 ..< fftSize {
            window[n] = 0.5 - 0.5 * cosf(2 * .pi * Float(n) / Float(fftSize - 1))
        }
        let half = fftSize / 2
        ring = [Float](repeating: 0, count: fftSize)
        ringWrite = 0
        ringFilled = 0
        samplesSinceAnalysis = 0
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: half)
        imag = [Float](repeating: 0, count: half)
        magnitude = [Float](repeating: 0, count: half)
        bandLevels = [Float](repeating: 0, count: Self.bandCount)
        // Bins whose centre frequency is in [lo, hi) for each band, and the band's fixed
        // scale (gain and width normalisation).
        let binHz = Float(sampleRate) / Float(fftSize)
        bandRanges = (0 ..< Self.bandCount).map { b in
            let lo = max(1, Int(ceilf(Self.bandEdges[b] / binHz)))
            let hi = min(half, Int(ceilf(Self.bandEdges[b + 1] / binHz)))
            return lo ..< max(lo, hi)
        }
        bandScale = (0 ..< Self.bandCount).map { b in
            powf(10, Self.bandGainDB[b] / 20) / powf(Float(max(1, bandRanges[b].count)), Self.widthExponent)
        }

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
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
        fftSetup = nil
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedBundleID = nil
        isRunning = false
        lock.lock()
        _levels = [Float](repeating: 0, count: Self.bandCount)
        _lastCallback = 0
        _heardSignal = false
        lock.unlock()
    }

    // MARK: Audio processing (runs on `queue`)

    private func process(_ inData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self),
              !ring.isEmpty else { return }

        // Mono-mix whatever layout we got (interleaved or one buffer per channel).
        var peak: Float = 0
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
                push(v)
            }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += base[f * channels + c] }
                let v = sum / Float(channels)
                peak = max(peak, abs(v))
                push(v)
            }
        }

        lock.lock()
        _lastCallback = CFAbsoluteTimeGetCurrent()
        if peak > 1e-6 { _heardSignal = true }
        lock.unlock()
    }

    /// Adds one sample to the ring and analyses the latest fftSize samples every hopSize.
    @inline(__always)
    private func push(_ sample: Float) {
        ring[ringWrite] = sample
        ringWrite = ringWrite + 1 == fftSize ? 0 : ringWrite + 1
        if ringFilled < fftSize { ringFilled += 1 }
        samplesSinceAnalysis += 1
        if ringFilled == fftSize && samplesSinceAnalysis >= hopSize {
            samplesSinceAnalysis = 0
            analyse()
        }
    }

    private func analyse() {
        guard let fftSetup else { return }
        let half = fftSize / 2

        // Unroll the ring (oldest sample at ringWrite) and apply the window in one pass each.
        let tail = fftSize - ringWrite
        ring.withUnsafeBufferPointer { r in
            window.withUnsafeBufferPointer { w in
                windowed.withUnsafeMutableBufferPointer { out in
                    vDSP_vmul(r.baseAddress! + ringWrite, 1, w.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(tail))
                    if ringWrite > 0 {
                        vDSP_vmul(r.baseAddress!, 1, w.baseAddress! + tail, 1, out.baseAddress! + tail, 1, vDSP_Length(ringWrite))
                    }
                }
            }
        }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                magnitude.withUnsafeMutableBufferPointer { mp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        magnitude.withUnsafeBufferPointer { m in
            for b in 0 ..< Self.bandCount {
                let range = bandRanges[b]
                var sum: Float = 0
                if !range.isEmpty {
                    vDSP_sve(m.baseAddress! + range.lowerBound, 1, &sum, vDSP_Length(range.count))
                }
                // vDSP's real FFT is scaled by 2 relative to the plain DFT.
                sum *= 0.5 * bandScale[b]
                bandLevels[b] = max(0, min(1, Self.curveScale * powf(sum, Self.curveExponent) - Self.curveFloor))
            }
        }

        lock.lock()
        _levels = bandLevels
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

// MARK: - Bars view

class AudioSpectrum: NSView {
    private var barLayers: [CALayer] = []
    /// Level of each bar, 0 (a dot) ... 1 (full height).
    private var levels: [CGFloat] = []
    private var targets: [CGFloat] = []
    private var isPlaying: Bool = false
    private var animationTimer: Timer?
    private var lastRandomTick: CFAbsoluteTime = 0
    private var lastRetry: CFAbsoluteTime = 0
    private var lastTick: CFAbsoluteTime = 0
    private var holdsMonitor = false

    // Proportions and timing measured from the iPhone Dynamic Island (120 fps capture):
    // bars are 0.106 of the max height wide on a 0.167 pitch, rest as round dots and
    // redraw at 30 Hz. We redraw at 60 Hz for less lag.
    private static let widthRatio: CGFloat = 0.106
    private static let pitchRatio: CGFloat = 0.167
    private static let updateInterval: TimeInterval = 1.0 / 60.0
    /// Glide speed for the random fallback animation (fraction of range per update).
    private static let maxStep: CGFloat = 0.105
    private static let randomInterval: TimeInterval = 0.3
    /// Smoothing time constants for live levels. Compared frame by frame with the iPhone
    /// Dynamic Island on a synthetic music track: even 40 ms scores 0.089 / corr 0.91 on
    /// held-back audio, near the best fit (80/50 ms, 0.085) with less delay (50 vs 83 ms).
    private static let riseTime: Double = 0.040
    private static let fallTime: Double = 0.040

    var bundleID: String? {
        didSet {
            if bundleID != oldValue { AudioLevelMonitor.shared.setTarget(bundleID: bundleID) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    deinit {
        animationTimer?.invalidate()
        if holdsMonitor { AudioLevelMonitor.shared.release() }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    private var occlusionObserver: Any?

    /// Only animate (and keep the audio tap running) while the notch is actually on screen:
    /// not while the display sleeps, the screen is locked or another space covers it.
    private var isVisible: Bool {
        window?.occlusionState.contains(.visible) ?? false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        updateRunning()
    }

    private func updateRunning() {
        if isPlaying && isVisible {
            startAnimating()
        } else if animationTimer != nil || holdsMonitor {
            stopAnimating()
        }
    }

    private func setupBars() {
        for _ in 0 ..< AudioLevelMonitor.bandCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            barLayers.append(bar)
            levels.append(0)
            targets.append(0)
            layer?.addSublayer(bar)
        }
    }

    override func layout() {
        super.layout()
        applyLevels()
    }

    /// Bars are centred and grow up and down from the middle, keeping their rounded
    /// ends (bounds change, not a scale transform). Size follows the view height.
    private func applyLevels() {
        let maxHeight = bounds.height
        let barWidth = max(1, maxHeight * Self.widthRatio)
        let pitch = maxHeight * Self.pitchRatio
        let count = CGFloat(barLayers.count)
        let totalWidth = (count - 1) * pitch + barWidth
        let originX = (bounds.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let h = barWidth + (maxHeight - barWidth) * levels[i]
            bar.cornerRadius = barWidth / 2
            bar.frame = CGRect(
                x: originX + CGFloat(i) * pitch,
                y: (maxHeight - h) / 2,
                width: barWidth,
                height: h)
        }
        CATransaction.commit()
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        if !holdsMonitor {
            holdsMonitor = true
            AudioLevelMonitor.shared.retain()
        }
        let timer = Timer(timeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        if holdsMonitor {
            holdsMonitor = false
            AudioLevelMonitor.shared.release()
        }
        for i in levels.indices {
            levels[i] = 0
            targets[i] = 0
        }
        applyLevels()
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let (live, isLive) = AudioLevelMonitor.shared.snapshot()

        if isLive {
            // Exponential smoothing, the same up and down: bars glide like the iPhone's
            // instead of twitching between analyses (~50 ms to half height on a hit).
            let dt = min(0.1, max(0, now - lastTick))
            let rise = 1 - CGFloat(exp(-dt / Self.riseTime))
            let fall = 1 - CGFloat(exp(-dt / Self.fallTime))
            for i in levels.indices where i < live.count {
                let target = CGFloat(live[i])
                levels[i] += (target - levels[i]) * (target > levels[i] ? rise : fall)
                targets[i] = levels[i]
            }
            lastTick = now
            applyLevels()
            return
        } else {
            // No real audio (yet): the original random animation.
            if now - lastRandomTick >= Self.randomInterval {
                lastRandomTick = now
                for i in targets.indices { targets[i] = .random(in: 0.2 ... 1) }
            }
            if now - lastRetry >= 1 {
                lastRetry = now
                AudioLevelMonitor.shared.ensureRunning()
            }
        }

        for i in levels.indices {
            levels[i] += max(-Self.maxStep, min(Self.maxStep, targets[i] - levels[i]))
        }
        applyLevels()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateRunning()
    }
}

struct AudioSpectrumView: NSViewRepresentable {
    @Binding var isPlaying: Bool
    var bundleID: String? = nil

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.bundleID = bundleID
        spectrum.setPlaying(isPlaying)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.bundleID = bundleID
        nsView.setPlaying(isPlaying)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 22, height: 20)
        .padding()
}

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

/// Taps the output audio of the now-playing app and publishes smoothed band levels (0...1).
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor()

    static let bandCount = 6
    /// Band edges in Hz (bandCount + 1 values), measured from the iPhone Dynamic Island
    /// with test tones: nothing above ~10 kHz moves it.
    private static let bandEdges: [Float] = [30, 100, 190, 570, 1850, 5000, 10000]
    /// Where a band sits when it is at its own recent average (0...1).
    private static let restLevel: Float = 0.4
    /// dB above a band's recent average needed to reach the top.
    private static let peakDB: Float = 12
    /// Per-analysis-frame smoothing (~94 frames/s) for each band's running average (~1.5 s).
    private static let averageRate: Float = 0.007

    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private let queue = DispatchQueue(label: "boringNotch.audioLevelMonitor", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var ring: [Float] = []
    private var sampleRate: Double = 48000
    private var referenceDB: Float = -40
    private var bandAverageDB = [Float](repeating: -120, count: bandCount)
    private var startedAt: CFAbsoluteTime = 0

    // Touched only on `queue`.
    private var users = 0
    private var targetBundleID: String?
    private var tappedBundleID: String?
    private var isRunning = false

    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastCallback: CFAbsoluteTime = 0
    private var _heardSignal = false

    /// Latest band levels, plus whether they are real (tap delivering actual audio).
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
            self.startLocked()
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
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring.removeAll(keepingCapacity: true)
        referenceDB = -40
        bandAverageDB = [Float](repeating: -120, count: Self.bandCount)

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
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }

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
                ring.append(v)
            }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += base[f * channels + c] }
                let v = sum / Float(channels)
                peak = max(peak, abs(v))
                ring.append(v)
            }
        }

        lock.lock()
        _lastCallback = CFAbsoluteTimeGetCurrent()
        if peak > 1e-6 { _heardSignal = true }
        lock.unlock()

        while ring.count >= fftSize {
            analyse(Array(ring.prefix(fftSize)))
            ring.removeFirst(fftSize / 2) // 50% overlap
        }
    }

    private func analyse(_ samples: [Float]) {
        guard let fftSetup else { return }
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }

        let edges = Self.bandEdges
        let binHz = Float(sampleRate) / Float(fftSize)

        // Band loudness in dB. Music has much more energy in the bass, so tilt the
        // spectrum (+3 dB/octave around 1 kHz) to let the treble bars move too.
        var bandDB = [Float](repeating: -120, count: Self.bandCount)
        for b in 0 ..< Self.bandCount {
            let lo = max(1, Int(edges[b] / binHz))
            let hi = min(half - 1, max(lo + 1, Int(edges[b + 1] / binHz)))
            var mean: Float = 0
            power.withUnsafeBufferPointer { p in
                vDSP_meanv(p.baseAddress! + lo, 1, &mean, vDSP_Length(hi - lo + 1))
            }
            let center = sqrtf(edges[b] * edges[b + 1])
            let tilt = 10 * log10f(center / 1000)
            bandDB[b] = 10 * log10f(mean + 1e-12) + tilt
        }

        // Each bar shows movement around its band's own recent average, so a dense, loud
        // mix rests mid-height and only hits (kick, snare, vocal swells) reach the top.
        // A slow overall reference pulls every bar down in quiet passages and fades.
        let loudest = bandDB.max() ?? -120
        referenceDB = loudest > referenceDB ? referenceDB + (loudest - referenceDB) * 0.05 : max(loudest, referenceDB - 0.03)
        let gate = max(0, min(1, (loudest - (referenceDB - 30)) / 18))

        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0 ..< Self.bandCount {
            if bandAverageDB[b] < -100 { bandAverageDB[b] = bandDB[b] }
            bandAverageDB[b] += (bandDB[b] - bandAverageDB[b]) * Self.averageRate
            let above = bandDB[b] - bandAverageDB[b]
            let level = Self.restLevel + (1 - Self.restLevel) * above / Self.peakDB
            out[b] = max(0, min(1, level)) * gate
        }

        lock.lock()
        _levels = out
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

    private static func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
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
    private var holdsMonitor = false

    // Proportions and timing measured from the iPhone Dynamic Island (120 fps capture):
    // bars are 0.106 of the max height wide on a 0.167 pitch, rest as round dots,
    // update at 30 Hz and move ~0.2 of their range per update in either direction.
    private static let widthRatio: CGFloat = 0.106
    private static let pitchRatio: CGFloat = 0.167
    private static let updateInterval: TimeInterval = 1.0 / 30.0
    private static let maxStep: CGFloat = 0.21
    private static let randomInterval: TimeInterval = 0.3

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
            for i in targets.indices where i < live.count {
                targets[i] = CGFloat(live[i])
            }
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

        // Constant-speed slew, the same up and down (a full swing takes ~5 updates).
        for i in levels.indices {
            levels[i] += max(-Self.maxStep, min(Self.maxStep, targets[i] - levels[i]))
        }
        applyLevels()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if isPlaying {
            startAnimating()
        } else {
            stopAnimating()
        }
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

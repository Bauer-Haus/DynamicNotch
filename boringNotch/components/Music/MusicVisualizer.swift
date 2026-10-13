//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
//  The 6 bars follow the real audio of Apple Music / Spotify (via a Core Audio
//  process tap + FFT). If the tap is unavailable (permission denied, player not
//  running, other source) the original random animation is used as a fallback.
//
import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import SwiftUI

// MARK: - Live audio levels

/// Taps the output audio of the music apps and publishes 4 smoothed band levels (0...1).
final class AudioLevelMonitor {
    static let shared = AudioLevelMonitor()

    static let bandCount = 6
    /// Bundle id prefixes of the apps whose output is analysed.
    private static let bundlePrefixes = ["com.apple.Music", "com.spotify.client"]

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
    private var bandPeaks = [Float](repeating: 0.001, count: bandCount)
    private var smoothed = [Float](repeating: 0, count: bandCount)

    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: bandCount)
    private var _lastUpdate: CFAbsoluteTime = 0
    private(set) var isRunning = false

    /// Latest band levels, plus whether they are fresh (audio actually flowing).
    func snapshot() -> (levels: [Float], isLive: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_levels, CFAbsoluteTimeGetCurrent() - _lastUpdate < 0.5)
    }

    private var users = 0 // touched only on `queue`

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
            if self.users == 0 { self.stopLocked() }
        }
    }

    /// Retry attaching (e.g. the player launched after we started). No-op if already running.
    func ensureRunning() {
        queue.async { [weak self] in
            guard let self, self.users > 0 else { return }
            self.startLocked()
        }
    }

    // MARK: Setup

    private func startLocked() {
        guard !isRunning else { return }
        // Process taps need macOS 14.2+; older systems keep the random animation.
        guard #available(macOS 14.2, *) else { return }

        let processes = Self.processObjects(matching: Self.bundlePrefixes)
        guard !processes.isEmpty else { return } // player not running; caller falls back

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }
        tapID = tap

        // Read the tap's stream format to get the sample rate.
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "boringNotch-visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
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
        isRunning = true
    }

    private func stopLocked() {
        guard isRunning || tapID != kAudioObjectUnknown else { return }
        teardown()
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
        isRunning = false
        smoothed = [Float](repeating: 0, count: Self.bandCount)
        lock.lock()
        _levels = smoothed
        _lastUpdate = 0
        lock.unlock()
    }

    // MARK: Audio processing (runs on `queue`)

    private func process(_ inData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else { return }

        // Mono-mix whatever layout we got (interleaved or one buffer per channel).
        if buffers.count > 1 {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            for f in 0 ..< frames {
                var sum: Float = 0
                var n: Float = 0
                for b in buffers {
                    if let p = b.mData?.assumingMemoryBound(to: Float.self) { sum += p[f]; n += 1 }
                }
                ring.append(n > 0 ? sum / n : 0)
            }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            for f in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += base[f * channels + c] }
                ring.append(sum / Float(channels))
            }
        }

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

        // Band edges in Hz (bandCount + 1 values), roughly log-spaced from bass to treble.
        let edges: [Float] = [40, 150, 400, 1000, 2500, 6000, 14000]
        let binHz = Float(sampleRate) / Float(fftSize)

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for b in 0 ..< Self.bandCount {
            let lo = max(1, Int(edges[b] / binHz))
            let hi = min(half - 1, max(lo + 1, Int(edges[b + 1] / binHz)))
            var mean: Float = 0
            vDSP_meanv(Array(power[lo ... hi]), 1, &mean, vDSP_Length(hi - lo + 1))
            bands[b] = sqrt(mean) // amplitude
        }

        // Per-band adaptive normalisation so the bars use their full range at any volume.
        var out = [Float](repeating: 0, count: Self.bandCount)
        for b in 0 ..< Self.bandCount {
            bandPeaks[b] = max(bandPeaks[b] * 0.995, bands[b], 0.001)
            let norm = min(1, bands[b] / bandPeaks[b])
            let shaped = powf(norm, 0.8)
            // Fast attack, slower release.
            let coeff: Float = shaped > smoothed[b] ? 0.6 : 0.15
            smoothed[b] += (shaped - smoothed[b]) * coeff
            out[b] = smoothed[b]
        }

        lock.lock()
        _levels = out
        _lastUpdate = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    // MARK: Process lookup

    private static func processObjects(matching prefixes: [String]) -> [AudioObjectID] {
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
            var bidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var cf: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &s, &cf) == noErr,
                  let bundleID = cf?.takeRetainedValue() as String? else { return false }
            return prefixes.contains { bundleID.hasPrefix($0) }
        }
    }
}

// MARK: - Bars view

class AudioSpectrum: NSView {
    private var barLayers: [CAShapeLayer] = []
    private var barScales: [CGFloat] = []
    private var isPlaying: Bool = true
    private var animationTimer: Timer?
    private var lastLiveTick: CFAbsoluteTime = 0

    private let minScale: CGFloat = 0.35
    private let fallbackInterval: TimeInterval = 0.3
    private let liveInterval: TimeInterval = 1.0 / 30.0

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

    private var holdsMonitor = false

    deinit {
        animationTimer?.invalidate()
        if holdsMonitor { AudioLevelMonitor.shared.release() }
    }

    private func setupBars() {
        // Original bar size (2pt wide, 2pt gap). With 6 bars the view is 24pt wide;
        // ContentView widens the notch and the mask to match (see `visualizerWidth`).
        let barWidth: CGFloat = 2
        let barCount = AudioLevelMonitor.bandCount
        let spacing: CGFloat = barWidth
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        let totalHeight: CGFloat = 14
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPosition = CGFloat(i) * (barWidth + spacing)
            let barLayer = CAShapeLayer()
            barLayer.frame = CGRect(x: xPosition, y: 0, width: barWidth, height: totalHeight)
            barLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            barLayer.position = CGPoint(x: xPosition + barWidth / 2, y: totalHeight / 2)
            barLayer.fillColor = NSColor.white.cgColor
            barLayer.backgroundColor = NSColor.white.cgColor
            barLayer.allowsGroupOpacity = false
            barLayer.masksToBounds = true
            let path = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            barLayer.path = path.cgPath
            barLayers.append(barLayer)
            barScales.append(minScale)
            layer?.addSublayer(barLayer)
        }
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        if !holdsMonitor {
            holdsMonitor = true
            AudioLevelMonitor.shared.retain()
        }
        // One 30 Hz timer; it drives live levels, or falls back to the random animation.
        animationTimer = Timer.scheduledTimer(withTimeInterval: liveInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        if holdsMonitor {
            holdsMonitor = false
            AudioLevelMonitor.shared.release()
        }
        resetBars()
    }

    private func tick() {
        let (levels, isLive) = AudioLevelMonitor.shared.snapshot()
        if isLive {
            applyLive(levels)
        } else {
            // Not tapped (permission denied / other player / no audio yet): old behaviour.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastLiveTick >= fallbackInterval else { return }
            lastLiveTick = now
            updateBarsRandom()
            // If the player started after we did, try to attach again.
            AudioLevelMonitor.shared.ensureRunning()
        }
    }

    private func applyLive(_ levels: [Float]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, barLayer) in barLayers.enumerated() where i < levels.count {
            barLayer.removeAnimation(forKey: "scaleY")
            let scale = minScale + (1 - minScale) * CGFloat(max(0, min(1, levels[i])))
            barScales[i] = scale
            barLayer.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    private func updateBarsRandom() {
        for (i, barLayer) in barLayers.enumerated() {
            let currentScale = barScales[i]
            let targetScale = CGFloat.random(in: minScale ... 1.0)
            barScales[i] = targetScale
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = currentScale
            animation.toValue = targetScale
            animation.duration = fallbackInterval
            animation.autoreverses = true
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            if #available(macOS 13.0, *) {
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 24, preferred: 24)
            }
            barLayer.add(animation, forKey: "scaleY")
        }
    }

    private func resetBars() {
        for (i, barLayer) in barLayers.enumerated() {
            barLayer.removeAllAnimations()
            barLayer.transform = CATransform3DMakeScale(1, minScale, 1)
            barScales[i] = minScale
        }
    }

    func setPlaying(_ playing: Bool) {
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

    func makeNSView(context: Context) -> AudioSpectrum {
        let spectrum = AudioSpectrum()
        spectrum.setPlaying(isPlaying)
        return spectrum
    }

    func updateNSView(_ nsView: AudioSpectrum, context: Context) {
        nsView.setPlaying(isPlaying)
    }
}

#Preview {
    AudioSpectrumView(isPlaying: .constant(true))
        .frame(width: 16, height: 20)
        .padding()
}

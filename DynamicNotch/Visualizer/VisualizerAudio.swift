//
//  VisualizerAudio.swift
//  DynamicNotch
//
//  Feeds the now-playing app's audio (from the waveform's tap) to the visualizer's
//  analysis, and hands the latest frame to the renderer.
//

import Foundation

/// Shares the waveform's audio tap: while the visualizer is open it holds the tap and
/// receives every buffer, analysed on the audio queue. The renderer reads the latest frame.
final class VisualizerAudio {
    static let shared = VisualizerAudio()

    private let lock = NSLock()
    // Audio queue only.
    private var analyzer: VisualizerAnalyzer?
    // Under `lock`.
    private var latest = VisualizerFrame()
    private var lastFrameTime: CFAbsoluteTime = 0
    private var running = false

    private init() {}

    func start(bundleID: String?) {
        lock.lock()
        let wasRunning = running
        running = true
        lock.unlock()
        guard !wasRunning else { return }
        let monitor = AudioLevelMonitor.shared
        monitor.setTarget(bundleID: bundleID)
        monitor.setSampleSink { [weak self] samples, rate in self?.consume(samples, sampleRate: rate) }
        monitor.retain()
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        latest = VisualizerFrame()
        lastFrameTime = 0
        lock.unlock()
        guard wasRunning else { return }
        AudioLevelMonitor.shared.setSampleSink(nil)
        AudioLevelMonitor.shared.release()
    }

    /// Copies the latest frame into `frame`; returns its age in seconds (infinite if none).
    func read(into frame: inout VisualizerFrame) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard lastFrameTime > 0 else { return .infinity }
        Self.copy(latest, into: &frame)
        return CFAbsoluteTimeGetCurrent() - lastFrameTime
    }

    private func consume(_ samples: AudioSamples, sampleRate: Double) {
        if analyzer?.sampleRate != sampleRate { analyzer = VisualizerAnalyzer(sampleRate: sampleRate) }
        guard let analyzer, analyzer.push(left: samples.left, right: samples.right) else { return }
        lock.lock()
        Self.copy(analyzer.frame, into: &latest)
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Element-wise, so neither side's arrays are reallocated.
    private static func copy(_ source: VisualizerFrame, into target: inout VisualizerFrame) {
        target.bands.withUnsafeMutableBufferPointer { t in
            source.bands.withUnsafeBufferPointer { s in t.baseAddress!.update(from: s.baseAddress!, count: min(t.count, s.count)) }
        }
        target.bass = source.bass
        target.mid = source.mid
        target.treble = source.treble
        target.loudness = source.loudness
        target.beatCount = source.beatCount
        target.beatStrength = source.beatStrength
        target.speakers = source.speakers
    }
}

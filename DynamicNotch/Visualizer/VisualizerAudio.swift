//
//  VisualizerAudio.swift
//  DynamicNotch
//
//  Feeds the now-playing app's audio (from the waveform's tap) to the visualizer's
//  analysis, and hands the latest frame to the renderer.
//

import Foundation

/// Shares the waveform's audio tap: while the visualizer is open it holds the tap and
/// receives every buffer, analysed on the audio queue. The renderer reads the latest frame,
/// or with `delay` set (AirPods), the one from that long ago, so the light matches what you
/// hear rather than what the app has just played.
final class VisualizerAudio {
    static let shared = VisualizerAudio()

    /// Frames kept for the delay: one per 512-sample hop, so ~680 ms at 48 kHz.
    static let historyCount = 64
    /// The longest delay offered (the history must cover it at 96 kHz too).
    static let maxDelay: TimeInterval = 0.3

    private let lock = NSLock()
    // Audio queue only.
    private var analyzer: VisualizerAnalyzer?
    // Under `lock`: a ring of recent frames, newest at `newest`.
    private var history = [VisualizerFrame](repeating: VisualizerFrame(), count: historyCount)
    private var historyTimes = [CFAbsoluteTime](repeating: 0, count: historyCount)
    private var newest = -1
    private var _delay: TimeInterval = 0
    private var running = false

    /// How far behind the tap the visualizer runs (0...maxDelay seconds).
    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = min(max(newValue, 0), Self.maxDelay); lock.unlock() }
    }

    /// The app uses `shared`; tests make their own.
    init() {}

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
        newest = -1
        for i in historyTimes.indices { historyTimes[i] = 0 }
        lock.unlock()
        guard wasRunning else { return }
        AudioLevelMonitor.shared.setSampleSink(nil)
        AudioLevelMonitor.shared.release()
    }

    /// Copies the frame to show now (the latest, or the one `delay` ago) into `frame`;
    /// returns how stale it is in seconds beyond the delay (infinite if none).
    func read(into frame: inout VisualizerFrame, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard newest >= 0 else { return .infinity }
        let due = now - _delay
        // Newest first, back to the first frame made by `due`.
        for back in 0 ..< Self.historyCount {
            let i = (newest - back + Self.historyCount) % Self.historyCount
            let t = historyTimes[i]
            guard t > 0 else { break }
            if t <= due {
                Self.copy(history[i], into: &frame)
                return due - t
            }
        }
        // Nothing that old yet (the delay just started): nothing to show.
        return .infinity
    }

    /// Stores a frame as if analysed at `time` (tests).
    func record(_ frame: VisualizerFrame, at time: CFAbsoluteTime) {
        lock.lock(); defer { lock.unlock() }
        store(frame, at: time)
    }

    private func store(_ frame: VisualizerFrame, at time: CFAbsoluteTime) {
        newest = (newest + 1) % Self.historyCount
        Self.copy(frame, into: &history[newest])
        historyTimes[newest] = time
    }

    private func consume(_ samples: AudioSamples, sampleRate: Double) {
        if analyzer?.sampleRate != sampleRate { analyzer = VisualizerAnalyzer(sampleRate: sampleRate) }
        guard let analyzer, analyzer.push(left: samples.left, right: samples.right) else { return }
        lock.lock()
        store(analyzer.frame, at: CFAbsoluteTimeGetCurrent())
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

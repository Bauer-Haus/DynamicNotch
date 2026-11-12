//
//  VisualizerAnalyzer.swift
//  DynamicNotch
//
//  The full-screen visualizer's analysis: a 64-band log spectrum that adapts to the
//  track's loudness, bass / mid / treble energy and beat onsets.
//

import Accelerate
import Foundation

/// One analysis of the latest audio. Every value is 0...1.
struct VisualizerFrame {
    static let bandCount = 64

    var bands = [Float](repeating: 0, count: bandCount)
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Overall loudness relative to the track's recent peak.
    var loudness: Float = 0
    /// Bumped on every detected beat; `beatStrength` is that beat's size.
    var beatCount = 0
    var beatStrength: Float = 0
}

/// Turns mono samples into `VisualizerFrame`s. Unlike `SpectrumAnalyzer` (which copies the
/// iPhone's island exactly), this one is made to look good full screen: log-spaced bands
/// from 32 Hz to 16 kHz, a +3 dB/octave tilt so treble is as lively as bass, and an
/// automatic gain that follows the track, so quiet and loud masters both fill the screen.
/// Not thread-safe; `push` never allocates.
final class VisualizerAnalyzer {
    static let fftSize = 2048
    static let hopSize = 512
    private static let log2n: vDSP_Length = 11

    static let lowHz: Float = 32
    static let highHz: Float = 16000
    /// Dynamic range shown, below the track's recent peak.
    static let rangeDB: Float = 50
    /// The gain never boosts quieter than this, so near-silence stays dark.
    static let quietestPeakDB: Float = -48
    /// How fast the reference peak falls after a loud passage (dB per second).
    static let peakFallDBPerSecond: Float = 4
    /// Shortest gap between beats (s): ~270 BPM.
    static let minBeatGap: Double = 0.22

    let sampleRate: Double
    private(set) var frame = VisualizerFrame()

    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: fftSize)
    private var ring = [Float](repeating: 0, count: fftSize)
    private var ringWrite = 0
    private var ringFilled = 0
    private var sinceAnalysis = 0
    private var hopSumSquares: Float = 0
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var unrolled = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var magnitude = [Float](repeating: 0, count: fftSize / 2)

    /// Fractional FFT bin of each band's lower edge, centre and upper edge.
    private let bandLow: [Float]
    private let bandCentre: [Float]
    private let bandHigh: [Float]
    /// +3 dB/octave around 1 kHz.
    private let tiltDB: [Float]
    private var bandDB = [Float](repeating: -120, count: VisualizerFrame.bandCount)
    private var previousLevels = [Float](repeating: 0, count: VisualizerFrame.bandCount)

    private var peakDB: Float = quietestPeakDB
    private var loudPeakDB: Float = -30

    // Onset detection: spectral flux against its own recent mean and spread.
    private static let fluxHistoryCount = 96 // ~1 s of analyses at 48 kHz
    private var fluxHistory = [Float](repeating: 0, count: fluxHistoryCount)
    private var fluxWrite = 0
    private var analyses = 0
    private var lastBeatAnalysis = -1000

    init?(sampleRate: Double) {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        fftSetup = setup
        let binHz = Float(sampleRate) / Float(Self.fftSize)
        let n = VisualizerFrame.bandCount
        let ratio = Self.highHz / Self.lowHz
        func edge(_ i: Float) -> Float { Self.lowHz * powf(ratio, i / Float(n)) }
        bandLow = (0 ..< n).map { edge(Float($0)) / binHz }
        bandHigh = (0 ..< n).map { edge(Float($0 + 1)) / binHz }
        bandCentre = (0 ..< n).map { edge(Float($0) + 0.5) / binHz }
        tiltDB = (0 ..< n).map { 3 * log2f(edge(Float($0) + 0.5) / 1000) }
        for i in 0 ..< Self.fftSize {
            window[i] = 0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(Self.fftSize - 1))
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Adds samples; returns true if at least one new frame was produced.
    @discardableResult
    func push(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        var produced = false
        for s in samples {
            ring[ringWrite] = s
            ringWrite = ringWrite + 1 == Self.fftSize ? 0 : ringWrite + 1
            if ringFilled < Self.fftSize { ringFilled += 1 }
            hopSumSquares += s * s
            sinceAnalysis += 1
            if ringFilled == Self.fftSize && sinceAnalysis >= Self.hopSize {
                analyse(hopRMS: sqrtf(hopSumSquares / Float(sinceAnalysis)))
                sinceAnalysis = 0
                hopSumSquares = 0
                produced = true
            }
        }
        return produced
    }

    private func analyse(hopRMS: Float) {
        let size = Self.fftSize
        let half = size / 2
        let tail = size - ringWrite

        // Oldest sample first.
        ring.withUnsafeBufferPointer { r in
            unrolled.withUnsafeMutableBufferPointer { u in
                u.baseAddress!.update(from: r.baseAddress! + ringWrite, count: tail)
                if ringWrite > 0 { (u.baseAddress! + tail).update(from: r.baseAddress!, count: ringWrite) }
            }
        }
        vDSP_vmul(unrolled, 1, window, 1, &windowed, 1, vDSP_Length(size))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                magnitude.withUnsafeMutableBufferPointer { mp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        // A full-scale sine reads ~1.0 (zrip doubles, the Hann window halves).
        var scale = 1 / Float(half)
        vDSP_vsmul(magnitude, 1, &scale, &magnitude, 1, vDSP_Length(half))

        // Bands: the strongest bin inside, or the interpolated value where a band is
        // narrower than a bin (the lowest octaves).
        var loudestBand: Float = -120
        magnitude.withUnsafeBufferPointer { m in
            for b in 0 ..< VisualizerFrame.bandCount {
                let lo = Int(ceilf(bandLow[b]))
                let hi = min(half - 1, Int(floorf(bandHigh[b])))
                var value: Float = 0
                if hi >= lo {
                    for k in lo ... hi { value = max(value, m[k]) }
                } else {
                    let c = min(Float(half - 2), bandCentre[b])
                    let k = Int(c)
                    let f = c - Float(k)
                    value = m[k] * (1 - f) + m[k + 1] * f
                }
                let db = 20 * log10f(value + 1e-7) + tiltDB[b]
                bandDB[b] = db
                loudestBand = max(loudestBand, db)
            }
        }

        // Automatic gain: jump up to a new peak, ease down slowly after it.
        let hopSeconds = Float(Self.hopSize) / Float(sampleRate)
        peakDB = max(loudestBand, peakDB - Self.peakFallDBPerSecond * hopSeconds, Self.quietestPeakDB)
        let floorDB = peakDB - Self.rangeDB

        var bass: Float = 0, mid: Float = 0, treble: Float = 0
        var bassN: Float = 0, midN: Float = 0, trebleN: Float = 0
        var flux: Float = 0
        let binHz = Float(sampleRate) / Float(Self.fftSize)
        for b in 0 ..< VisualizerFrame.bandCount {
            let x = max(0, min(1, (bandDB[b] - floorDB) / Self.rangeDB))
            // Ease so the floor stays calm and the peaks stand out.
            let level = x * x * (1.6 - 0.6 * x)
            frame.bands[b] = level
            let hz = bandCentre[b] * binHz
            // Onsets count low and mid more: that's where the beat lives.
            let rise = max(0, level - previousLevels[b])
            flux += rise * (hz < 200 ? 2.2 : hz < 2500 ? 1.0 : 0.6)
            previousLevels[b] = level
            if hz < 180 { bass += level; bassN += 1 } else if hz < 2200 { mid += level; midN += 1 } else { treble += level; trebleN += 1 }
        }
        frame.bass = bassN > 0 ? bass / bassN : 0
        frame.mid = midN > 0 ? mid / midN : 0
        frame.treble = trebleN > 0 ? treble / trebleN : 0

        let rmsDB = 20 * log10f(hopRMS + 1e-7)
        loudPeakDB = max(rmsDB, loudPeakDB - Self.peakFallDBPerSecond * hopSeconds, -40)
        frame.loudness = max(0, min(1, (rmsDB - (loudPeakDB - 30)) / 30))

        detectBeat(flux: flux / Float(VisualizerFrame.bandCount))
        analyses += 1
    }

    private func detectBeat(flux: Float) {
        var mean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(fluxHistory, 1, &mean, vDSP_Length(Self.fluxHistoryCount))
        vDSP_measqv(fluxHistory, 1, &meanSquare, vDSP_Length(Self.fluxHistoryCount))
        let spread = sqrtf(max(0, meanSquare - mean * mean))
        fluxHistory[fluxWrite] = flux
        fluxWrite = (fluxWrite + 1) % Self.fluxHistoryCount

        let hopSeconds = Double(Self.hopSize) / sampleRate
        let gapOK = Double(analyses - lastBeatAnalysis) * hopSeconds >= Self.minBeatGap
        let threshold = mean + 1.6 * spread + 0.004
        guard analyses > Self.fluxHistoryCount / 4, gapOK, flux > threshold, frame.loudness > 0.15 else { return }
        lastBeatAnalysis = analyses
        frame.beatCount &+= 1
        frame.beatStrength = max(0.25, min(1, (flux - mean) / max(4 * spread, 0.01)))
    }
}

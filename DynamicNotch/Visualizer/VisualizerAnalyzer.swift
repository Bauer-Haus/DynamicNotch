//
//  VisualizerAnalyzer.swift
//  DynamicNotch
//
//  The full-screen visualizer's analysis: a 64-band log spectrum that adapts to the
//  track's loudness, bass / mid / treble energy, beat onsets, and the level each speaker
//  of a 2.0, 2.1 or 5.1 system would play.
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
    var speakers = SpeakerLevels()
}

/// How loud each speaker would be, 0...1, from the full-resolution left and right channels
/// (music apps send stereo). The sound is split between the speakers by frequency, like the
/// crossover in a speaker system, so each frequency drives one speaker:
/// - 2.0: left and right, full range, each from its own channel.
/// - 2.1: the sub takes the lows (below 120 Hz); left and right everything above.
/// - 5.1: the sub takes the lows, front left and right the mids (120 Hz - 3.5 kHz) of their
///   own side, the centre the highs (above 3.5 kHz). The surrounds take the ambience: sound
///   that differs between the two sides (reverb, room, wide effects), which is what rear
///   speakers carry when a receiver upmixes stereo. A mono recording leaves them dark.
/// Each speaker is measured against its own recent peak (highs are naturally ~20 dB quieter
/// than mids, so a shared scale would leave the centre dark), but never boosted by more than
/// a set amount relative to the track, so a speaker with nothing to play stays dark.
struct SpeakerLevels {
    /// 2.0.
    var left: Float = 0
    var right: Float = 0
    /// 2.1: left and right above the sub.
    var leftMain: Float = 0
    var rightMain: Float = 0
    /// 5.1: fronts are mids, centre highs, surrounds ambience.
    var frontLeft: Float = 0
    var frontRight: Float = 0
    var centre: Float = 0
    var surroundLeft: Float = 0
    var surroundRight: Float = 0
    /// The .1: the lows.
    var sub: Float = 0
}

/// Turns stereo samples into `VisualizerFrame`s. Unlike `SpectrumAnalyzer` (which copies the
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
    /// Speaker levels cover this many dB below the recent loudest speaker.
    static let speakerRangeDB: Float = 30
    /// Crossover points: the sub plays below `subUpToHz`, the 5.1 fronts up to `midsUpToHz`
    /// and the centre above it.
    static let subUpToHz: Float = 120
    static let midsUpToHz: Float = 3500
    /// How far (dB) each group of speakers may be boosted above the track's loudness to fill
    /// its pulse: 2.0, 2.1 mains, 5.1 fronts (mids), centre (highs), surrounds, sub.
    static let speakerBoostDB: [Float] = [0, 6, 10, 24, 15, 20]
    /// Those groups' speakers, as indices into `speakerDB`.
    private static let speakerGroups: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 6), (7, 8), (9, 9)]

    let sampleRate: Double
    private(set) var frame = VisualizerFrame()

    private let fftSetup: FFTSetup
    private var window = [Float](repeating: 0, count: fftSize)
    private var ringL = [Float](repeating: 0, count: fftSize)
    private var ringR = [Float](repeating: 0, count: fftSize)
    private var ringWrite = 0
    private var ringFilled = 0
    private var sinceAnalysis = 0
    private var hopSumSquares: Float = 0
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var unrolled = [Float](repeating: 0, count: fftSize)
    private var realL = [Float](repeating: 0, count: fftSize / 2)
    private var imagL = [Float](repeating: 0, count: fftSize / 2)
    private var realR = [Float](repeating: 0, count: fftSize / 2)
    private var imagR = [Float](repeating: 0, count: fftSize / 2)
    private var magnitude = [Float](repeating: 0, count: fftSize / 2)
    private var trackPeakDB: Float = -60
    private var groupPeakDB = [Float](repeating: -60, count: 6)
    private var speakerDB = [Float](repeating: -120, count: 10)

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

    /// Adds mono samples (both sides the same); returns true if a new frame was produced.
    @discardableResult
    func push(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        push(left: samples, right: samples)
    }

    /// Adds stereo samples; returns true if at least one new frame was produced.
    @discardableResult
    func push(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) -> Bool {
        var produced = false
        for i in 0 ..< min(left.count, right.count) {
            let l = left[i], r = right[i]
            ringL[ringWrite] = l
            ringR[ringWrite] = r
            ringWrite = ringWrite + 1 == Self.fftSize ? 0 : ringWrite + 1
            if ringFilled < Self.fftSize { ringFilled += 1 }
            let m = 0.5 * (l + r)
            hopSumSquares += m * m
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

    /// Windowed FFT of one ring, oldest sample first, scaled so a full-scale sine reads ~1.0
    /// (zrip doubles, the Hann window halves).
    private func spectrum(of ring: [Float], real: inout [Float], imag: inout [Float]) {
        let size = Self.fftSize
        let half = size / 2
        let tail = size - ringWrite
        ring.withUnsafeBufferPointer { r in
            unrolled.withUnsafeMutableBufferPointer { u in
                u.baseAddress!.update(from: r.baseAddress! + ringWrite, count: tail)
                if ringWrite > 0 { (u.baseAddress! + tail).update(from: r.baseAddress!, count: ringWrite) }
            }
        }
        vDSP_vmul(unrolled, 1, window, 1, &windowed, 1, vDSP_Length(size))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        var scale = 1 / Float(half)
        vDSP_vsmul(real, 1, &scale, &real, 1, vDSP_Length(half))
        vDSP_vsmul(imag, 1, &scale, &imag, 1, vDSP_Length(half))
    }

    private func analyse(hopRMS: Float) {
        let half = Self.fftSize / 2
        spectrum(of: ringL, real: &realL, imag: &imagL)
        spectrum(of: ringR, real: &realR, imag: &imagR)
        // The mono mix's spectrum is the average of the two sides'.
        for k in 0 ..< half {
            let re = 0.5 * (realL[k] + realR[k])
            let im = 0.5 * (imagL[k] + imagR[k])
            magnitude[k] = sqrtf(re * re + im * im)
        }
        magnitude[0] = 0 // bin 0 holds DC and Nyquist packed together
        analyseSpeakers()

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

    /// Each speaker's energy, from the two sides' spectra bin by bin (see `SpeakerLevels`).
    private func analyseSpeakers() {
        let half = Self.fftSize / 2
        let binHz = Float(sampleRate) / Float(Self.fftSize)
        var left: Float = 0, right: Float = 0, leftMain: Float = 0, rightMain: Float = 0
        var fl: Float = 0, fr: Float = 0, c: Float = 0, sl: Float = 0, sr: Float = 0, sub: Float = 0
        let firstBin = max(1, Int(20 / binHz))
        for k in firstBin ..< half {
            let hz = Float(k) * binHz
            let lr = realL[k], li = imagL[k], rr = realR[k], ri = imagR[k]
            let a2 = lr * lr + li * li
            let b2 = rr * rr + ri * ri
            left += a2
            right += b2
            if hz < Self.subUpToHz {
                let mr = 0.5 * (lr + rr), mi = 0.5 * (li + ri)
                sub += mr * mr + mi * mi
                continue
            }
            leftMain += a2
            rightMain += b2
            // How alike the two sides are here: 1 = the same sound in both, 0 = unrelated,
            // -1 = opposite. Unrelated and opposite sound is ambience (surrounds), but only
            // when both sides play it: a sound panned hard to one side stays in front.
            let a = sqrtf(a2), b = sqrtf(b2)
            let coherence = max(-1, min(1, (lr * rr + li * ri) / (a * b + 1e-12)))
            let balance = 2 * min(a, b) / (a + b + 1e-12)
            let toSurround = 0.5 * (1 - coherence) * balance
            sl += a2 * toSurround
            sr += b2 * toSurround
            if hz < Self.midsUpToHz {
                fl += a2 * (1 - toSurround)
                fr += b2 * (1 - toSurround)
            } else {
                c += 0.5 * (a2 + b2) * (1 - toSurround)
            }
        }
        func db(_ energy: Float) -> Float { 10 * log10f(energy + 1e-12) }
        speakerDB[0] = db(left); speakerDB[1] = db(right)
        speakerDB[2] = db(leftMain); speakerDB[3] = db(rightMain)
        speakerDB[4] = db(fl); speakerDB[5] = db(fr); speakerDB[6] = db(c)
        speakerDB[7] = db(sl); speakerDB[8] = db(sr); speakerDB[9] = db(sub)

        let fall = Self.peakFallDBPerSecond * Float(Self.hopSize) / Float(sampleRate)
        trackPeakDB = max(speakerDB[0], speakerDB[1], trackPeakDB - fall, -60)
        for (g, (i, j)) in Self.speakerGroups.enumerated() {
            groupPeakDB[g] = max(speakerDB[i], speakerDB[j], groupPeakDB[g] - fall,
                                 trackPeakDB - Self.speakerBoostDB[g])
        }
        func level(_ index: Int, group: Int) -> Float {
            let peak = groupPeakDB[group]
            let x = max(0, min(1, (speakerDB[index] - (peak - Self.speakerRangeDB)) / Self.speakerRangeDB))
            return x * x * (1.5 - 0.5 * x)
        }
        frame.speakers = SpeakerLevels(
            left: level(0, group: 0), right: level(1, group: 0),
            leftMain: level(2, group: 1), rightMain: level(3, group: 1),
            frontLeft: level(4, group: 2), frontRight: level(5, group: 2),
            centre: level(6, group: 3),
            surroundLeft: level(7, group: 4), surroundRight: level(8, group: 4),
            sub: level(9, group: 5))
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

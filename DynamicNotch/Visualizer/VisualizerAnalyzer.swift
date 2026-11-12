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
/// (music apps send stereo), split the way a home theatre receiver upmixes stereo music,
/// with its crossovers set for this system:
/// - 2.0: left and right, full range, each from its own channel.
/// - 2.1: left and right from 40 Hz up (the fronts' crossover), the sub below 50 Hz.
/// - 5.1: each sound goes where a receiver would put it. What's the same in both channels
///   (vocals, kick, snare: the middle of the mix) to the centre, from 60 Hz up. What's
///   only or mostly on one side to that side's front, from 40 Hz up. Sound that differs
///   between the sides (reverb, room, wide effects) to the surrounds, from 70 Hz up. A mono
///   recording leaves the fronts and surrounds dark, as it would on a receiver.
/// - The sub: everything below its 50 Hz low-pass.
/// Crossovers are 4th-order Linkwitz-Riley (24 dB/octave), as receivers use. Each speaker is
/// measured against its own recent peak, but never boosted by more than a set amount
/// relative to the track, so a speaker with nothing to play stays dark.
struct SpeakerLevels {
    /// 2.0.
    var left: Float = 0
    var right: Float = 0
    /// 2.1: left and right above the sub.
    var leftMain: Float = 0
    var rightMain: Float = 0
    /// 5.1: fronts are each side's own sound, centre what both share, surrounds ambience.
    var frontLeft: Float = 0
    var frontRight: Float = 0
    var centre: Float = 0
    var surroundLeft: Float = 0
    var surroundRight: Float = 0
    /// The .1: below 50 Hz.
    var sub: Float = 0
    /// Hits (a sharp rise: a drum, a pluck, a consonant), per speaker in `Speaker` order:
    /// each is bumped on a hit, with that hit's size 0...1.
    var hitCount = SIMD16<Int32>(repeating: 0)
    var hitStrength = SIMD16<Float>(repeating: 0)

    /// Indices into `hitCount` / `hitStrength`.
    enum Speaker {
        static let left = 0, right = 1, leftMain = 2, rightMain = 3, frontLeft = 4, frontRight = 5
        static let centre = 6, surroundLeft = 7, surroundRight = 8, sub = 9
    }
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
    /// The quietest a speaker has been recently is the bottom of its pulse, so a loud master
    /// that only varies by 6-8 dB still swings from dim to bright. It creeps up this fast
    /// (dB/s) while the music stays loud, and the range never shrinks below `minRangeDB`.
    static let floorRiseDBPerSecond: Float = 10
    static let minRangeDB: Float = 9
    /// A hit: the level rising this much within ~21 ms (two analyses)...
    static let hitRise: Float = 0.18
    /// ...at least this many analyses (~75 ms) after the last one.
    static let hitGap = 7
    /// Crossovers, set like the receiver of this system: fronts (rated 30 Hz - 20 kHz) cross
    /// over at 40 Hz, the centre (45 Hz - 25 kHz) at 60 Hz, the surrounds (50 Hz - 20 kHz) at
    /// 60-80 Hz, so 70; the sub (20-200 Hz) is low-passed at 40-60 Hz, so 50.
    static let frontsFromHz: Float = 40
    static let centreFromHz: Float = 60
    static let surroundsFromHz: Float = 70
    static let subUpToHz: Float = 50
    /// How far (dB) each group of speakers may be boosted above the track's loudness to fill
    /// its pulse: 2.0, 2.1 mains, 5.1 fronts, centre, surrounds, sub.
    /// The sub's is small: bass carries most of a mix's energy, so a sub with little to
    /// play (an acoustic track) stays dim.
    static let speakerBoostDB: [Float] = [0, 6, 10, 10, 15, 10]
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
    /// The crossovers run on the samples: the FFT's ~23 Hz bins are far too coarse to tell
    /// 40 Hz from 60. The sub's low-pass runs on the mono mix; the fronts' high-pass on each
    /// side, whose spectra (`realFL`...) the 2.1 and 5.1 speakers are measured from.
    private var subFilter: LinkwitzRiley
    private var frontFilterL: LinkwitzRiley
    private var frontFilterR: LinkwitzRiley
    private var ringFL = [Float](repeating: 0, count: fftSize)
    private var ringFR = [Float](repeating: 0, count: fftSize)
    /// The centre's and surrounds' higher crossovers, on top of the fronts' (power, per bin).
    private let centreWeight: [Float]
    private let surroundWeight: [Float]
    private var subHopSquares: Float = 0
    /// The last four hops' sub energy: one analysis window (~43 ms), long enough to hold a
    /// whole cycle of the lowest notes.
    private var subHops = [Float](repeating: 0, count: 4)
    private var subHopWrite = 0
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var unrolled = [Float](repeating: 0, count: fftSize)
    private var realL = [Float](repeating: 0, count: fftSize / 2)
    private var imagL = [Float](repeating: 0, count: fftSize / 2)
    private var realR = [Float](repeating: 0, count: fftSize / 2)
    private var imagR = [Float](repeating: 0, count: fftSize / 2)
    private var realFL = [Float](repeating: 0, count: fftSize / 2)
    private var imagFL = [Float](repeating: 0, count: fftSize / 2)
    private var realFR = [Float](repeating: 0, count: fftSize / 2)
    private var imagFR = [Float](repeating: 0, count: fftSize / 2)
    private var magnitude = [Float](repeating: 0, count: fftSize / 2)
    private var trackPeakDB: Float = -60
    private var groupPeakDB = [Float](repeating: -60, count: 6)
    private var groupFloorDB = [Float](repeating: -90, count: 6)
    private var speakerLevel = [Float](repeating: 0, count: 10)
    private var levelOneAgo = [Float](repeating: 0, count: 10)
    private var levelTwoAgo = [Float](repeating: 0, count: 10)
    private var lastHit = [Int](repeating: -1000, count: 10)
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
        subFilter = LinkwitzRiley(lowPassAt: Self.subUpToHz, sampleRate: Float(sampleRate))
        frontFilterL = LinkwitzRiley(highPassAt: Self.frontsFromHz, sampleRate: Float(sampleRate))
        frontFilterR = frontFilterL
        // A Linkwitz-Riley high-pass passes x^4 / (1 + x^4) of the amplitude, x = f / fc.
        func highPassPower(_ hz: Float, _ fc: Float) -> Float {
            let x4 = powf(hz / fc, 4)
            let h = x4 / (1 + x4)
            return h * h
        }
        let bins = (0 ..< Self.fftSize / 2).map { Float($0) * binHz }
        centreWeight = bins.map { min(1, highPassPower($0, Self.centreFromHz) / max(highPassPower($0, Self.frontsFromHz), 1e-9)) }
        surroundWeight = bins.map { min(1, highPassPower($0, Self.surroundsFromHz) / max(highPassPower($0, Self.frontsFromHz), 1e-9)) }
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
            ringFL[ringWrite] = frontFilterL.process(l)
            ringFR[ringWrite] = frontFilterR.process(r)
            ringWrite = ringWrite + 1 == Self.fftSize ? 0 : ringWrite + 1
            if ringFilled < Self.fftSize { ringFilled += 1 }
            let m = 0.5 * (l + r)
            hopSumSquares += m * m
            let lows = subFilter.process(m)
            subHopSquares += lows * lows
            sinceAnalysis += 1
            if ringFilled == Self.fftSize && sinceAnalysis >= Self.hopSize {
                analyse(hopRMS: sqrtf(hopSumSquares / Float(sinceAnalysis)))
                sinceAnalysis = 0
                hopSumSquares = 0
                subHopSquares = 0
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
        spectrum(of: ringFL, real: &realFL, imag: &imagFL)
        spectrum(of: ringFR, real: &realFR, imag: &imagFR)
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
            left += realL[k] * realL[k] + imagL[k] * imagL[k]
            right += realR[k] * realR[k] + imagR[k] * imagR[k]
            // Above the fronts' crossover.
            let lr = realFL[k], li = imagFL[k], rr = realFR[k], ri = imagFR[k]
            let a2 = lr * lr + li * li
            let b2 = rr * rr + ri * ri
            leftMain += a2
            rightMain += b2
            // How alike the two sides are here: 1 = the same sound in both, 0 = unrelated,
            // -1 = opposite; and how evenly they play it. The same sound evenly in both is
            // the middle of the mix (centre); unrelated or opposite sound in both is ambience
            // (surrounds); the rest, a sound panned to one side, stays in that side's front.
            let a = sqrtf(a2), b = sqrtf(b2)
            let coherence = max(-1, min(1, (lr * rr + li * ri) / (a * b + 1e-12)))
            let balance = 2 * min(a, b) / (a + b + 1e-12)
            let toCentre = max(0, coherence) * balance
            let toSurround = 0.5 * (1 - coherence) * balance
            let toFront = max(0, 1 - toCentre - toSurround)
            fl += a2 * toFront
            fr += b2 * toFront
            c += 0.5 * (a2 + b2) * toCentre * centreWeight[k]
            sl += a2 * toSurround * surroundWeight[k]
            sr += b2 * toSurround * surroundWeight[k]
        }
        // The sub's energy over the window, scaled to match the FFT sums (a sine's energy
        // there is ~3x its mean square: the Hann window spreads it over three bins).
        subHops[subHopWrite] = subHopSquares / Float(Self.hopSize)
        subHopWrite = (subHopWrite + 1) % subHops.count
        sub = 3 * (subHops[0] + subHops[1] + subHops[2] + subHops[3]) / 4
        func db(_ energy: Float) -> Float { 10 * log10f(energy + 1e-12) }
        speakerDB[0] = db(left); speakerDB[1] = db(right)
        speakerDB[2] = db(leftMain); speakerDB[3] = db(rightMain)
        speakerDB[4] = db(fl); speakerDB[5] = db(fr); speakerDB[6] = db(c)
        speakerDB[7] = db(sl); speakerDB[8] = db(sr); speakerDB[9] = db(sub)

        let fall = Self.peakFallDBPerSecond * Float(Self.hopSize) / Float(sampleRate)
        trackPeakDB = max(speakerDB[0], speakerDB[1], trackPeakDB - fall, -60)
        let floorRise = Self.floorRiseDBPerSecond * Float(Self.hopSize) / Float(sampleRate)
        for (g, (i, j)) in Self.speakerGroups.enumerated() {
            let peak = max(speakerDB[i], speakerDB[j], groupPeakDB[g] - fall, trackPeakDB - Self.speakerBoostDB[g])
            groupPeakDB[g] = peak
            // Down at once to a new quiet, slowly back up while it stays loud.
            let quietest = min(speakerDB[i], speakerDB[j])
            let floor = quietest < groupFloorDB[g] ? quietest : groupFloorDB[g] + floorRise
            groupFloorDB[g] = max(peak - Self.speakerRangeDB, min(peak - Self.minRangeDB, floor))
            let bottom = groupFloorDB[g]
            for k in i ... j {
                let x = max(0, min(1, (speakerDB[k] - bottom) / (peak - bottom)))
                speakerLevel[k] = x * x * (1.5 - 0.5 * x)
            }
        }
        var speakers = SpeakerLevels(
            left: speakerLevel[0], right: speakerLevel[1],
            leftMain: speakerLevel[2], rightMain: speakerLevel[3],
            frontLeft: speakerLevel[4], frontRight: speakerLevel[5],
            centre: speakerLevel[6],
            surroundLeft: speakerLevel[7], surroundRight: speakerLevel[8],
            sub: speakerLevel[9])
        speakers.hitCount = frame.speakers.hitCount
        speakers.hitStrength = frame.speakers.hitStrength
        for k in 0 ..< 10 {
            let rise = speakerLevel[k] - levelTwoAgo[k]
            if rise > Self.hitRise, speakerLevel[k] > 0.3, analyses - lastHit[k] >= Self.hitGap {
                lastHit[k] = analyses
                speakers.hitCount[k] &+= 1
                speakers.hitStrength[k] = min(1, 0.3 + 1.6 * rise)
            }
            levelTwoAgo[k] = levelOneAgo[k]
            levelOneAgo[k] = speakerLevel[k]
        }
        frame.speakers = speakers
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

/// A 4th-order Linkwitz-Riley crossover filter (two 2nd-order Butterworth stages, RBJ
/// biquads with Q = 1/sqrt(2)): 24 dB/octave, -6 dB at the crossover, as receivers use.
struct LinkwitzRiley {
    private let b0, b1, b2, a1, a2: Float
    // x1, x2, y1, y2 of each stage.
    private var s0: (Float, Float, Float, Float) = (0, 0, 0, 0)
    private var s1: (Float, Float, Float, Float) = (0, 0, 0, 0)

    init(lowPassAt hz: Float, sampleRate: Float) { self.init(hz, sampleRate, highPass: false) }
    init(highPassAt hz: Float, sampleRate: Float) { self.init(hz, sampleRate, highPass: true) }

    private init(_ hz: Float, _ sampleRate: Float, highPass: Bool) {
        let w0 = 2 * Float.pi * hz / sampleRate
        let alpha = sinf(w0) / (2 * Float(0.5).squareRoot())
        let a0 = 1 + alpha
        let cosw = cosf(w0)
        let k: Float = highPass ? (1 + cosw) / 2 : (1 - cosw) / 2
        b0 = k / a0
        b1 = (highPass ? -2 * k : 2 * k) / a0
        b2 = k / a0
        a1 = -2 * cosw / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y0 = b0 * x + b1 * s0.0 + b2 * s0.1 - a1 * s0.2 - a2 * s0.3
        s0 = (x, s0.0, y0, s0.2)
        let y1 = b0 * y0 + b1 * s1.0 + b2 * s1.1 - a1 * s1.2 - a2 * s1.3
        s1 = (y0, s1.0, y1, s1.2)
        return y1
    }
}

//
//  SpectrumAnalyzerTests.swift
//  boringNotchTests
//
//  The visualizer's analysis, fed with synthetic audio instead of a Core Audio tap.
//

import Foundation
import Testing
@testable import Boring_Notch

@Suite("Spectrum analysis")
struct SpectrumAnalyzerTests {
    static let sampleRate = 48_000.0
    /// A frequency inside each band (edges 33.5, 93.75, 189.4, 553.3, 1828, 4945, 9997 Hz).
    static let bandCentres: [Double] = [60, 130, 330, 1000, 3000, 7000]

    /// Feeds `seconds` of a sine wave and returns the last levels.
    private func levels(tone frequency: Double, amplitude: Float, seconds: Double = 0.2,
                        sampleRate: Double = sampleRate) throws -> [Float] {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: sampleRate))
        for n in 0 ..< Int(seconds * sampleRate) {
            analyzer.push(amplitude * Float(sin(2 * .pi * frequency * Double(n) / sampleRate)))
        }
        return analyzer.levels
    }

    @Test func rejectsInvalidSampleRate() {
        #expect(SpectrumAnalyzer(sampleRate: 0) == nil)
        #expect(SpectrumAnalyzer(sampleRate: -44_100) == nil)
    }

    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func bandsAreOrderedAndDisjoint(sampleRate: Double) {
        let ranges = SpectrumAnalyzer.bandRanges(sampleRate: sampleRate)
        #expect(ranges.count == SpectrumAnalyzer.bandCount)
        for (i, range) in ranges.enumerated() {
            #expect(!range.isEmpty, "band \(i) has no FFT bins")
            #expect(range.lowerBound >= 1, "band \(i) includes the DC bin")
            #expect(range.upperBound <= SpectrumAnalyzer.fftSize / 2)
            if i > 0 { #expect(ranges[i - 1].upperBound <= range.lowerBound, "bands \(i - 1) and \(i) overlap") }
        }
    }

    @Test func silenceLeavesEveryBarAtRest() throws {
        let result = try levels(tone: 1000, amplitude: 0)
        #expect(result == [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
    }

    @Test(arguments: Array(bandCentres.enumerated()))
    func toneLightsItsOwnBar(band: Int, frequency: Double) throws {
        let result = try levels(tone: frequency, amplitude: 0.5)
        let loudest = try #require(result.indices.max { result[$0] < result[$1] })
        #expect(loudest == band, "\(Int(frequency)) Hz should light bar \(band), got \(result)")
        #expect(result[band] > 0.1)
    }

    @Test func nothingAboveTenKilohertzMovesTheBars() throws {
        let result = try levels(tone: 15_000, amplitude: 0.8)
        #expect(result.allSatisfy { $0 < 0.05 }, "\(result)")
    }

    @Test func louderIsTaller() throws {
        let quiet = try levels(tone: 1000, amplitude: 0.05)[3]
        let medium = try levels(tone: 1000, amplitude: 0.2)[3]
        let loud = try levels(tone: 1000, amplitude: 0.8)[3]
        #expect(quiet < medium && medium < loud, "\(quiet) \(medium) \(loud)")
    }

    @Test func fullScaleNoiseStaysInRange() throws {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: Self.sampleRate))
        var rng = SystemRandomNumberGenerator()
        for _ in 0 ..< 48_000 {
            analyzer.push(Float.random(in: -1 ... 1, using: &rng))
            #expect(analyzer.levels.allSatisfy { (0 ... 1).contains($0) })
        }
    }

    @Test func analysesEveryHopOnceTheWindowIsFull() throws {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: Self.sampleRate))
        var analyses = 0
        let samples = SpectrumAnalyzer.fftSize + 10 * SpectrumAnalyzer.hopSize
        for _ in 0 ..< samples where analyzer.push(0.1) { analyses += 1 }
        // The first analysis needs a full window, then one per hop.
        #expect(analyses == 1 + 10)
    }

    @Test func loudnessCurveIsClampedAndRising() {
        #expect(SpectrumAnalyzer.level(forBandSum: 0) == 0)
        #expect(SpectrumAnalyzer.level(forBandSum: -5) == 0)
        #expect(SpectrumAnalyzer.level(forBandSum: 1e9) == 1)
        var previous: Float = 0
        for sum in stride(from: Float(1), through: 100_000, by: 997) {
            let level = SpectrumAnalyzer.level(forBandSum: sum)
            #expect(level >= previous)
            previous = level
        }
    }
}

@Suite("Bar smoothing")
struct BarSmoothingTests {
    @Test func reachesAboutTwoThirdsAfterOneTimeConstant() {
        let level = AudioSpectrum.smoothed(0, toward: 1, dt: AudioSpectrum.riseTime)
        #expect(abs(level - (1 - exp(-1))) < 0.001)
    }

    @Test func fallsTheSameWay() {
        let level = AudioSpectrum.smoothed(1, toward: 0, dt: AudioSpectrum.fallTime)
        #expect(abs(level - exp(-1)) < 0.001)
    }

    @Test func neverOvershootsAndStandsStillWithoutTime() {
        #expect(AudioSpectrum.smoothed(0.3, toward: 0.8, dt: 0) == 0.3)
        for dt in [0.001, 0.016, 0.033, 0.1, 1.0] {
            let up = AudioSpectrum.smoothed(0.2, toward: 0.9, dt: dt)
            #expect(up > 0.2 && up <= 0.9)
            let down = AudioSpectrum.smoothed(0.9, toward: 0.2, dt: dt)
            #expect(down < 0.9 && down >= 0.2)
        }
    }

    @Test func sameSpeedAtThirtyAndSixtyFPS() {
        // Two 60 Hz frames land where one 30 Hz frame does.
        let sixty = AudioSpectrum.smoothed(AudioSpectrum.smoothed(0, toward: 1, dt: 1.0 / 60), toward: 1, dt: 1.0 / 60)
        let thirty = AudioSpectrum.smoothed(0, toward: 1, dt: 1.0 / 30)
        #expect(abs(sixty - thirty) < 0.0001)
    }

    @Test func restsAsDotsWhileAudioStarts() {
        #expect(AudioSpectrum.restsAsDots(heardLive: false, waitingFor: 0))
        #expect(AudioSpectrum.restsAsDots(heardLive: false, waitingFor: AudioSpectrum.randomFallbackDelay - 0.1))
        // No audio at all for a while: permission denied, use the random animation.
        #expect(!AudioSpectrum.restsAsDots(heardLive: false, waitingFor: AudioSpectrum.randomFallbackDelay + 0.1))
        // Once real audio has played, gaps stay as dots.
        #expect(AudioSpectrum.restsAsDots(heardLive: true, waitingFor: 60))
    }
}

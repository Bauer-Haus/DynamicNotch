//
//  MusicVisualizer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//
//  The bars follow the real audio of the now-playing app (via a Core Audio
//  process tap + FFT). If that app's audio can't be found the tap listens to all
//  system output instead. If no audio arrives at all (permission denied) the
//  original random animation is used as a fallback.
//
import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import SwiftUI

// MARK: - Spectrum analysis

/// The iPhone-matched analysis, kept apart from Core Audio so it can be tested with
/// synthetic audio. Fitted to 120 fps captures of the Dynamic Island playing test tones,
/// tone volume steps and pink noise: a 2048-sample Hann FFT, each bar summing the FFT
/// magnitudes in its band (lightly normalised by band width), mapped through a power
/// curve. Nothing above ~10 kHz moves it, and a tone needs to be near full scale to fill
/// a bar. Not thread-safe; buffers are allocated once so `push` never allocates.
final class SpectrumAnalyzer {
    static let bandCount = 6
    /// Band edges in Hz (bandCount + 1 values).
    static let bandEdges: [Float] = [33.5, 93.75, 189.4, 553.3, 1828, 4945, 9997]
    /// Per-bar gain in dB applied to the band sum.
    static let bandGainDB: [Float] = [3.67, -5.51, 1.31, -0.33, 1.07, -0.21]
    /// level = clamp(curveScale * (gain * sum / bins^widthExponent)^curveExponent - curveFloor, 0, 1)
    static let curveScale: Float = 0.0330293
    static let curveExponent: Float = 0.56783
    static let curveFloor: Float = 0.08208
    /// The band sum is divided by (bin count)^widthExponent.
    static let widthExponent: Float = 0.12749

    static let fftSize = 2048
    /// A new analysis every 512 samples (~11 ms at 48 kHz).
    static let hopSize = 512
    private static let log2n: vDSP_Length = 11

    let sampleRate: Double
    /// FFT bins whose centre frequency falls in each band.
    let bandRanges: [Range<Int>]
    /// Latest level of each bar, 0...1.
    private(set) var levels = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)

    private let fftSetup: FFTSetup
    private let bandScale: [Float]
    private var window = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var ring = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize) // circular
    private var ringWrite = 0
    private var ringFilled = 0
    private var samplesSinceAnalysis = 0
    private var windowed = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
    private var magnitude = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)

    init?(sampleRate: Double) {
        guard sampleRate > 0, let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.sampleRate = sampleRate
        fftSetup = setup
        let ranges = Self.bandRanges(sampleRate: sampleRate)
        bandRanges = ranges
        bandScale = (0 ..< Self.bandCount).map { b in
            powf(10, Self.bandGainDB[b] / 20) / powf(Float(max(1, ranges[b].count)), Self.widthExponent)
        }
        // Symmetric Hann, unnormalised (the curve constants were fitted with this window).
        for n in 0 ..< Self.fftSize {
            window[n] = 0.5 - 0.5 * cosf(2 * .pi * Float(n) / Float(Self.fftSize - 1))
        }
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    static func bandRanges(sampleRate: Double) -> [Range<Int>] {
        let half = fftSize / 2
        let binHz = Float(sampleRate) / Float(fftSize)
        return (0 ..< bandCount).map { b in
            let lo = max(1, Int(ceilf(bandEdges[b] / binHz)))
            let hi = min(half, Int(ceilf(bandEdges[b + 1] / binHz)))
            return lo ..< max(lo, hi)
        }
    }

    /// The fitted loudness curve: scaled band sum to bar height.
    static func level(forBandSum sum: Float) -> Float {
        max(0, min(1, curveScale * powf(max(0, sum), curveExponent) - curveFloor))
    }

    /// Adds one mono sample. Returns true when it completed a new analysis of the latest
    /// fftSize samples (every hopSize samples once the ring is full).
    @inline(__always)
    @discardableResult
    func push(_ sample: Float) -> Bool {
        ring[ringWrite] = sample
        ringWrite = ringWrite + 1 == Self.fftSize ? 0 : ringWrite + 1
        if ringFilled < Self.fftSize { ringFilled += 1 }
        samplesSinceAnalysis += 1
        guard ringFilled == Self.fftSize && samplesSinceAnalysis >= Self.hopSize else { return false }
        samplesSinceAnalysis = 0
        analyse()
        return true
    }

    private func analyse() {
        let half = Self.fftSize / 2

        // Unroll the ring (oldest sample at ringWrite) and apply the window in one pass each.
        let tail = Self.fftSize - ringWrite
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
                    vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(kFFTDirection_Forward))
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
                levels[b] = Self.level(forBandSum: sum)
            }
        }
    }
}

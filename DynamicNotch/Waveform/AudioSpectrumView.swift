//
import Accelerate
import AppKit
import AudioToolbox
import Cocoa
import CoreAudio
import SwiftUI

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
    /// When the bars started waiting for live audio, and whether any has arrived since.
    private var waitingSince: CFAbsoluteTime = 0
    private var heardLive = false

    // Proportions and timing measured from the iPhone Dynamic Island (120 fps capture):
    // bars are 0.106 of the max height wide on a 0.167 pitch, rest as round dots and
    // redraw at 30 Hz, and so do we.
    private static let widthRatio: CGFloat = 0.106
    private static let pitchRatio: CGFloat = 0.167
    private static let updateInterval: TimeInterval = 1.0 / 30.0
    /// Glide speed for the random fallback animation (fraction of range per update),
    /// tuned at 60 Hz and scaled so it moves at the same speed at any frame rate.
    private static let maxStep: CGFloat = 0.105 * CGFloat(updateInterval * 60)
    private static let randomInterval: TimeInterval = 0.3
    /// Starting the tap (and waking Bluetooth output) takes a moment, longest for the first
    /// song of the day. Rest as dots meanwhile; only fall back to the random animation if no
    /// audio has arrived by then (permission denied).
    static let randomFallbackDelay: TimeInterval = 3
    /// Smoothing time constants for live levels. Compared frame by frame with the iPhone
    /// Dynamic Island on a synthetic music track: even 40 ms scores 0.089 / corr 0.91 on
    /// held-back audio, near the best fit (80/50 ms, 0.085) with less delay (50 vs 83 ms).
    static let riseTime: Double = 0.040
    static let fallTime: Double = 0.040

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
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private var occlusionObserver: Any?
    private var screenObserver: Any?

    /// Only animate (and keep the audio tap running) while the notch is actually on screen:
    /// not while the display sleeps, another user is logged in or another space covers it.
    /// When the notch is open or hidden for full screen, SwiftUI removes this view from the
    /// window, which stops it the same way.
    private var isVisible: Bool {
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return ScreenActivity.shared.isActive && !isHiddenOrHasHiddenAncestor
            && bounds.width > 0 && bounds.height > 0
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
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: ScreenActivity.didChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            }
        }
        updateRunning()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRunning()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
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
        // Collapsing to zero size (notch shrinking away) stops it; growing back restarts it.
        updateRunning()
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
        waitingSince = CFAbsoluteTimeGetCurrent()
        heardLive = false
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
            // The first live frame after starting puts the bars straight at their measured
            // heights (they were resting as dots); after that they glide as usual.
            let snap = !heardLive
            heardLive = true
            // Exponential smoothing, the same up and down: bars glide like the iPhone's
            // instead of twitching between analyses (~50 ms to half height on a hit).
            let dt = min(0.1, max(0, now - lastTick))
            for i in levels.indices where i < live.count {
                levels[i] = snap ? CGFloat(live[i]) : Self.smoothed(levels[i], toward: CGFloat(live[i]), dt: dt)
                targets[i] = levels[i]
            }
            lastTick = now
            applyLevels()
            return
        } else {
            if Self.restsAsDots(heardLive: heardLive, waitingFor: now - waitingSince) {
                // Starting up, or a brief gap (track change, tap reconnecting): rest as dots.
                for i in targets.indices { targets[i] = 0 }
            } else if now - lastRandomTick >= Self.randomInterval {
                // No audio at all (permission denied): the original random animation.
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

    /// One frame of exponential smoothing towards `target` after `dt` seconds.
    static func smoothed(_ level: CGFloat, toward target: CGFloat, dt: Double) -> CGFloat {
        let time = target > level ? riseTime : fallTime
        return level + (target - level) * (1 - CGFloat(exp(-dt / time)))
    }

    /// While live audio is starting (or after it has been heard) the bars rest as dots;
    /// the random animation is only for audio that never arrives (permission denied).
    static func restsAsDots(heardLive: Bool, waitingFor elapsed: TimeInterval) -> Bool {
        heardLive || elapsed < randomFallbackDelay
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

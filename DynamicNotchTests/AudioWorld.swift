//
//  AudioWorld.swift
//  DynamicNotch
//
//  A simulated Mac audio system for testing AudioLevelMonitor: output devices that connect
//  and disconnect (AirPods moving between the Mac and an iPhone), a music app that follows
//  the default output, notification sounds, and taps that behave like Core Audio's,
//  including stopTap waiting for an audio callback in flight.
//

import Foundation
import Testing
@testable import DynamicNotch

/// Simulated time. Delayed blocks run on their queue when the test advances past them.
final class FakeClock: MonitorClock {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private var pending: [(due: TimeInterval, order: Int, queue: DispatchQueue, block: () -> Void)] = []
    private var order = 0

    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return time
    }

    func after(_ delay: TimeInterval, on queue: DispatchQueue, _ block: @escaping () -> Void) {
        lock.lock()
        order += 1
        pending.append((time + delay, order, queue, block))
        lock.unlock()
    }

    func setTime(_ t: TimeInterval) {
        lock.lock(); time = t; lock.unlock()
    }

    /// Removes and returns the earliest block due by now.
    func nextDue() -> (queue: DispatchQueue, block: () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard let i = pending.indices.filter({ pending[$0].due <= time })
            .min(by: { (pending[$0].due, pending[$0].order) < (pending[$1].due, pending[$1].order) })
        else { return nil }
        let item = pending.remove(at: i)
        return (item.queue, item.block)
    }
}

/// Runs `block` on `queue` and waits, but gives up (reporting a deadlock) after `timeout`.
@discardableResult
func runOn(_ queue: DispatchQueue, timeout: TimeInterval = 3, _ block: @escaping () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        queue.sync(execute: block)
        done.signal()
    }
    return done.wait(timeout: .now() + timeout) == .success
}

final class AudioWorld: AudioTapSystem {
    static let speakers = "BuiltInSpeakerDevice"
    static let airPods = "AirPods-Max:output"
    static let music = "com.apple.Music"

    enum Content { case music, silence }

    /// How a newly built tap behaves (Core Audio quirks seen around Bluetooth switches).
    enum Quirk { case normal, silent, dead }

    final class Tap {
        let id: Int
        let processes: [UInt32]
        let queue: DispatchQueue
        let handler: AudioSamplesHandler
        var quirk: Quirk
        /// Callbacks being delivered right now (stopTap waits for these, like Core Audio).
        var inFlight = 0
        var stopped = false
        init(id: Int, processes: [UInt32], queue: DispatchQueue,
             handler: @escaping AudioSamplesHandler, quirk: Quirk) {
            self.id = id; self.processes = processes
            self.queue = queue; self.handler = handler; self.quirk = quirk
        }
    }

    private let lock = NSCondition()
    private(set) var connected: Set<String> = [speakers]
    private(set) var defaultOutput: String? = speakers
    var musicPlaying = true
    var musicProcesses: [UInt32] = [7]
    /// The music app goes quiet for this long when the output switches (measured: ~0.5 s).
    var switchSilence: TimeInterval = 0.5
    /// What an output switch does to running taps (Core Audio glitches), and to new ones.
    var switchBreaksTaps: Quirk = .normal
    var quirkForNewTap: () -> Quirk = { .normal }
    var failStart: () -> AudioTapError? = { nil }
    /// Simulated time, for the switch silence.
    var now: () -> TimeInterval = { 0 }
    private var silentUntil: TimeInterval = 0
    /// Makes stopTap hang forever (a Core Audio call that never returns).
    var stopHangs = false

    private var taps: [Int: Tap] = [:]
    private var nextID = 1
    private(set) var tapsStarted = 0
    private var outputQueue: DispatchQueue?
    private var outputHandler: ((AudioOutputEvent) -> Void)?

    // MARK: AudioTapSystem

    func defaultOutputUID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return defaultOutput
    }

    func defaultOutputName() -> String? { defaultOutputUID() }

    func processObjects(forBundleID bundleID: String) -> [UInt32] {
        lock.lock(); defer { lock.unlock() }
        return bundleID == Self.music ? musicProcesses : []
    }

    func startTap(processes: [UInt32], deliveryQueue: DispatchQueue,
                  samples makeHandler: AudioSamplesHandlerFactory) -> Result<AudioTapHandle, AudioTapError> {
        lock.lock()
        if let error = failStart() {
            lock.unlock()
            return .failure(error)
        }
        let id = nextID
        nextID += 1
        tapsStarted += 1
        let quirk = quirkForNewTap()
        lock.unlock()
        let tap = Tap(id: id, processes: processes, queue: deliveryQueue,
                      handler: makeHandler(48000), quirk: quirk)
        lock.lock()
        taps[id] = tap
        lock.unlock()
        return .success(AudioTapHandle(id: id, sampleRate: 48000))
    }

    func stopTap(_ handle: AudioTapHandle) {
        lock.lock()
        if stopHangs {
            while true { lock.wait() }
        }
        guard let tap = taps.removeValue(forKey: handle.id) else {
            lock.unlock()
            return
        }
        tap.stopped = true
        while tap.inFlight > 0 { lock.wait() }
        lock.unlock()
    }

    func observeOutput(on queue: DispatchQueue, _ handler: @escaping (AudioOutputEvent) -> Void) {
        lock.lock()
        outputQueue = queue
        outputHandler = handler
        lock.unlock()
    }

    // MARK: Things that happen to the Mac

    var liveTaps: Int {
        lock.lock(); defer { lock.unlock() }
        return taps.count
    }

    func connect(_ device: String, makeDefault: Bool = true) {
        lock.lock()
        connected.insert(device)
        lock.unlock()
        if makeDefault { setDefault(device) }
    }

    /// The device leaves the Mac (AirPods taken by the iPhone). Output falls back to the speakers.
    func disconnect(_ device: String) {
        lock.lock()
        connected.remove(device)
        let wasDefault = defaultOutput == device
        let fallback = connected.contains(Self.speakers) ? Self.speakers : nil
        lock.unlock()
        if wasDefault { setDefault(fallback) }
    }

    func setDefault(_ device: String?) {
        lock.lock()
        defaultOutput = device
        silentUntil = now() + switchSilence
        if switchBreaksTaps != .normal { for tap in taps.values { tap.quirk = switchBreaksTaps } }
        lock.unlock()
        post(.defaultDeviceChanged)
    }

    func post(_ event: AudioOutputEvent) {
        lock.lock()
        let queue = outputQueue, handler = outputHandler
        lock.unlock()
        queue?.async { handler?(event) }
    }

    func setMusicPlaying(_ playing: Bool) {
        lock.lock(); musicPlaying = playing; lock.unlock()
    }

    /// The music app quits and relaunches with new process objects.
    func relaunchMusicApp(processes: [UInt32]) {
        lock.lock(); musicProcesses = processes; lock.unlock()
    }

    // MARK: Audio

    /// One IO cycle: every running tap gets a buffer, delivered synchronously on its queue
    /// (as Core Audio does). Taps aren't tied to an output device, so they keep running
    /// through switches; the music is silent briefly after one, and while there's no output.
    /// Returns false on deadlock.
    @discardableResult
    func ioCycle(samples: Int = 1024) -> Bool {
        lock.lock()
        var deliveries: [(Tap, Content)] = []
        let musicAudible = musicPlaying && defaultOutput != nil && now() >= silentUntil
        for tap in taps.values where !tap.stopped && tap.quirk != .dead {
            let hearsMusic = musicAudible
                && (tap.processes.isEmpty || !Set(tap.processes).isDisjoint(with: musicProcesses))
                && tap.quirk == .normal
            tap.inFlight += 1
            deliveries.append((tap, hearsMusic ? .music : .silence))
        }
        lock.unlock()

        var ok = true
        for (tap, content) in deliveries {
            let buffer = Self.buffer(content, count: samples)
            let delivered = runOn(tap.queue) {
                buffer.withUnsafeBufferPointer { tap.handler($0) }
            }
            if !delivered { ok = false }
            lock.lock()
            tap.inFlight -= 1
            lock.broadcast()
            lock.unlock()
        }
        return ok
    }

    private static var phase: Float = 0

    static func buffer(_ content: Content, count: Int) -> [Float] {
        guard content == .music else { return [Float](repeating: 0, count: count) }
        // A loud 440 Hz tone with some bass: plenty of signal in several bands.
        return (0 ..< count).map { i in
            let t = Float(i) / 48000
            return 0.4 * sinf(2 * .pi * 440 * t) + 0.3 * sinf(2 * .pi * 90 * t)
        }
    }
}

/// Drives an AudioLevelMonitor through simulated time the way the app does: the view polls
/// it 30 times a second and calls ensureRunning once a second while the bars aren't live.
final class WaveformHarness {
    let world = AudioWorld()
    let clock = FakeClock()
    private(set) var monitor: AudioLevelMonitor!
    private(set) var stuckReported = false
    private(set) var deadlocked = false
    private var lastEnsure: TimeInterval = 0
    /// Simulated seconds during which the bars were live / not live while music played.
    private(set) var liveTime: TimeInterval = 0
    private(set) var deadTime: TimeInterval = 0

    init(target: String? = AudioWorld.music) {
        world.now = { [clock] in clock.now() }
        monitor = AudioLevelMonitor(system: world, clock: clock, onStuck: { [weak self] in self?.stuckReported = true })
        monitor.setTarget(bundleID: target)
        monitor.retain()
        monitor.sync()
    }

    var isLive: Bool { monitor.snapshot().isLive }

    /// Advances simulated time in 20 ms steps: due timers run, audio flows, the view polls.
    func advance(_ seconds: TimeInterval, step: TimeInterval = 0.02) {
        let end = clock.now() + seconds
        while clock.now() < end - 1e-9, !deadlocked {
            clock.setTime(clock.now() + step)
            while let due = clock.nextDue() {
                if !runOn(due.queue, due.block) { deadlocked = true; return }
            }
            if !world.ioCycle(samples: Int(48000 * step)) { deadlocked = true; return }
            let live = isLive
            if world.musicPlaying { if live { liveTime += step } else { deadTime += step } }
            if !live, clock.now() - lastEnsure >= 1 {
                lastEnsure = clock.now()
                monitor.ensureRunning()
            }
            if !runOn(DispatchQueue.global(), { [monitor] in monitor!.sync() }) { deadlocked = true; return }
        }
    }

    /// Advances until the bars are live, returning how long it took (nil if they never were).
    func secondsUntilLive(within limit: TimeInterval) -> TimeInterval? {
        let start = clock.now()
        while clock.now() - start < limit, !deadlocked {
            if isLive { return clock.now() - start }
            advance(0.02)
        }
        return isLive ? clock.now() - start : nil
    }

    func resetCounters() {
        liveTime = 0
        deadTime = 0
    }

    /// The view going away (notch opened, music paused) and coming back.
    func viewReleases() { monitor.release(); monitor.sync() }
    func viewRetains() { monitor.retain(); monitor.sync() }
}

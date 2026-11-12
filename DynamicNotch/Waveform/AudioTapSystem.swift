//
//  AudioTapSystem.swift
//  DynamicNotch
//
//  The Core Audio side of the waveform: finding the music app, creating and destroying
//  process taps, and reporting output changes. Behind a protocol so AudioLevelMonitor can be
//  tested against a simulated audio system (device switches, AirPods handoff, notifications).
//

import AudioToolbox
import CoreAudio
import Foundation

/// A running tap, as seen by the monitor.
struct AudioTapHandle {
    let id: Int
    let sampleRate: Double
}

enum AudioOutputEvent {
    case defaultDeviceChanged
}

/// One buffer of the tap's audio: mixed to mono, and its left and right channels (both the
/// same as `mono` for a mono source).
struct AudioSamples {
    let mono: UnsafeBufferPointer<Float>
    let left: UnsafeBufferPointer<Float>
    let right: UnsafeBufferPointer<Float>

    /// A mono buffer (tests, simulated taps).
    init(mono: UnsafeBufferPointer<Float>) {
        self.mono = mono
        left = mono
        right = mono
    }

    init(mono: UnsafeBufferPointer<Float>, left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        self.mono = mono
        self.left = left
        self.right = right
    }
}

/// Called on the queue the monitor passes to `startTap`, with each buffer of the tap's audio.
typealias AudioSamplesHandler = (AudioSamples) -> Void
/// Makes the handler for a tap once its sample rate is known.
typealias AudioSamplesHandlerFactory = (_ sampleRate: Double) -> AudioSamplesHandler

protocol AudioTapSystem: AnyObject {
    func defaultOutputUID() -> String?
    func defaultOutputName() -> String?
    /// Audio process objects of an app, including its helpers.
    func processObjects(forBundleID bundleID: String) -> [UInt32]
    /// Taps `processes` (or, if empty, everything except this app). The tap is not tied to any
    /// output device, so switching speakers/AirPods/iPhone doesn't affect it.
    /// `samples` must run on `deliveryQueue`, never the caller's queue: stopping a tap waits
    /// for an in-flight delivery, so delivering on the stopping queue deadlocks.
    func startTap(processes: [UInt32], deliveryQueue: DispatchQueue,
                  samples: AudioSamplesHandlerFactory) -> Result<AudioTapHandle, AudioTapError>
    /// Stops and destroys the tap. When this returns no more samples are delivered.
    func stopTap(_ tap: AudioTapHandle)
    /// Reports output changes on `queue` (for logging and quicker checks). Called once.
    func observeOutput(on queue: DispatchQueue, _ handler: @escaping (AudioOutputEvent) -> Void)
    /// Wakes the audio system ahead of the first tap (optional).
    func prepare()
}

extension AudioTapSystem {
    func prepare() {}
}

struct AudioTapError: Error, Equatable, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

/// The real thing.
final class CoreAudioTapSystem: AudioTapSystem {
    private struct Running {
        let tap: AudioObjectID
        let aggregate: AudioObjectID
        let ioProc: AudioDeviceIOProcID
    }

    private var running: [Int: Running] = [:]
    private var nextID = 1
    private let lock = NSLock()

    func defaultOutputUID() -> String? {
        Self.defaultOutputDevice().flatMap { Self.stringProperty($0, kAudioDevicePropertyDeviceUID) }
    }

    func defaultOutputName() -> String? {
        Self.defaultOutputDevice().flatMap { Self.stringProperty($0, kAudioObjectPropertyName) }
    }

    func processObjects(forBundleID target: String) -> [UInt32] {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            guard let bundleID = Self.stringProperty(id, kAudioProcessPropertyBundleID) else { return false }
            return bundleID == target || bundleID.hasPrefix(target + ".")
        }
    }

    func startTap(processes: [UInt32], deliveryQueue: DispatchQueue,
                  samples makeHandler: AudioSamplesHandlerFactory) -> Result<AudioTapHandle, AudioTapError> {
        let desc = processes.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
            : CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr else { return .failure(AudioTapError(step: "creating the tap", status: tapStatus)) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = Self.address(kAudioTapPropertyFormat)
        var sampleRate = 48000.0
        if AudioObjectGetPropertyData(tap, &formatAddr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        // The aggregate holds only the tap, with no output device: it used to be clocked by
        // the output, so every switch to AirPods, the iPhone or back needed a rebuild, and a
        // tap rebuilt while Bluetooth was busy could stay dead for 20 s. On its own the tap
        // keeps delivering straight through any output switch (tested with 24 rapid switches).
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicNotch-visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return .failure(AudioTapError(step: "creating the aggregate device", status: aggStatus))
        }

        let samples = makeHandler(sampleRate)
        var mono = [Float]()
        var left = [Float]()
        var right = [Float]()
        var ioProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, deliveryQueue) { _, inData, _, _, _ in
            Self.split(inData, mono: &mono, left: &left, right: &right)
            mono.withUnsafeBufferPointer { m in
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { r in samples(AudioSamples(mono: m, left: l, right: r)) }
                }
            }
        }
        guard procStatus == noErr, let ioProc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return .failure(AudioTapError(step: "creating the IO proc", status: procStatus))
        }

        let startStatus = AudioDeviceStart(aggregate, ioProc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return .failure(AudioTapError(step: "starting the aggregate device", status: startStatus))
        }

        lock.lock()
        let id = nextID
        nextID += 1
        running[id] = Running(tap: tap, aggregate: aggregate, ioProc: ioProc)
        lock.unlock()
        return .success(AudioTapHandle(id: id, sampleRate: sampleRate))
    }

    func stopTap(_ handle: AudioTapHandle) {
        lock.lock()
        let tap = running.removeValue(forKey: handle.id)
        lock.unlock()
        guard let tap else { return }
        AudioDeviceStop(tap.aggregate, tap.ioProc)
        AudioDeviceDestroyIOProcID(tap.aggregate, tap.ioProc)
        AudioHardwareDestroyAggregateDevice(tap.aggregate)
        AudioHardwareDestroyProcessTap(tap.tap)
    }

    /// Only the system-wide default output is watched. The tap doesn't depend on the output
    /// device, and listening on the device itself (its sample rate) logged Core Audio errors
    /// whenever AirPods left: the listener was removed from a device that no longer existed.
    func observeOutput(on queue: DispatchQueue, _ handler: @escaping (AudioOutputEvent) -> Void) {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { _, _ in
            handler(.defaultDeviceChanged)
        }
    }

    /// Wakes Core Audio without capturing anything; the first call into it is slow.
    func prepare() {
        _ = defaultOutputUID()
        _ = Self.ownProcessObject()
    }

    // MARK: Helpers

    /// Mono-mixes whatever layout arrived (interleaved, or one buffer per channel), and keeps
    /// the first two channels as left and right (both the mono mix for a one-channel tap).
    private static func split(_ inData: UnsafePointer<AudioBufferList>,
                              mono: inout [Float], left: inout [Float], right: inout [Float]) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = buffers.first, let base = first.mData?.assumingMemoryBound(to: Float.self) else {
            mono.removeAll(keepingCapacity: true)
            left.removeAll(keepingCapacity: true)
            right.removeAll(keepingCapacity: true)
            return
        }
        if buffers.count > 1 {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            resize(&mono, frames)
            resize(&left, frames)
            resize(&right, frames)
            var n: Float = 0
            var hasRight = false
            for (index, b) in buffers.enumerated() {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                n += 1
                let count = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0 ..< count { mono[f] += p[f] }
                if index == 0 { for f in 0 ..< count { left[f] = p[f] } }
                if index == 1 { for f in 0 ..< count { right[f] = p[f] }; hasRight = true }
            }
            if n > 1 { for f in 0 ..< frames { mono[f] /= n } }
            if !hasRight { for f in 0 ..< frames { right[f] = left[f] } }
        } else {
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            resize(&mono, frames)
            resize(&left, frames)
            resize(&right, frames)
            for f in 0 ..< frames {
                var sum: Float = 0
                for c in 0 ..< channels { sum += base[f * channels + c] }
                mono[f] = sum / Float(channels)
                left[f] = base[f * channels]
                right[f] = base[f * channels + min(1, channels - 1)]
            }
        }
    }

    /// Zeroed buffer of `count` samples, reusing the allocation between callbacks.
    private static func resize(_ buffer: inout [Float], _ count: Int) {
        if buffer.count == count {
            buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        } else {
            buffer = [Float](repeating: 0, count: count)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

import AudioToolbox
import CoreAudio
import Foundation

/// System-audio capture permission (`NSAudioCaptureUsageDescription`). There is no public status API;
/// TCC's preflight is looked up at runtime and treated as unknown when missing.
public enum SystemAudioPermission {
    public enum Status: Sendable { case granted, denied, unknown }

    public static var status: Status {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Starting a tap is what shows the system prompt; run one briefly.
    public static func request() async {
        let capture = SystemAudioCapture()
        try? capture.start()
        try? await Task.sleep(for: .milliseconds(300))
        capture.stop()
    }
}

/// System audio through a Core Audio process tap (global mono, excluding Meety) on a private
/// aggregate device, like `core_audio.rs`. The IOProc only copies into the ring (D7). The tap is
/// rebuilt when the default output device changes.
public final class SystemAudioCapture: @unchecked Sendable { // start/stop/drain are called from one consumer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var ring = RingBuffer(capacity: 1 << 18)
    private var resampler: Resampler?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Between start and stop, even while a rebuild after an output change has failed (the next change retries).
    private var running = false
    private var retiredDrops = 0
    /// Called on the capture queue when the tap can't be rebuilt after an output-device change.
    public var onRebuildFailure: (@Sendable (Error) -> Void)?
    private let queue = DispatchQueue(label: "meety.system-audio", qos: .userInteractive)

    public init() {}

    public var droppedSamples: Int { queue.sync { retiredDrops + ring.droppedSamples } }
    public var isRunning: Bool { procID != nil }

    public func start() throws {
        stop()
        try buildTap()
        queue.sync { running = true }
        var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Output device changed (headphones, AirPods): the tap follows the new device.
            guard let self, self.running else { return }
            let pending = self.ring.drain()
            self.retiredDrops += self.ring.droppedSamples
            self.teardownTap()
            do { try self.buildTap(carrying: pending) } catch {
                self.teardownTap() // a half-built tap
                self.onRebuildFailure?(error)
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = listener
    }

    private func buildTap(carrying pending: [Float] = []) throws {
        let own = ownProcessObject()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own == kAudioObjectUnknown ? [] : [own])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), "create process tap")
        tapID = tap

        guard let format: AudioStreamBasicDescription = HAL.value(tap, kAudioTapPropertyFormat), format.mSampleRate > 0 else {
            teardownTap()
            throw AudioError.noDevice
        }
        guard let output = AudioDevices.defaultOutput() else { teardownTap(); throw AudioError.noDevice }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meety System Audio",
            kAudioAggregateDeviceUIDKey: "\(AudioDevices.tapAggregatePrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice), "create aggregate device")
        aggregateID = aggregateDevice

        let ring = RingBuffer(capacity: 1 << 18)
        pending.withUnsafeBufferPointer { if let base = $0.baseAddress { ring.write(base, count: pending.count) } }
        let channels = Int(max(format.mChannelsPerFrame, 1))
        var proc: AudioDeviceIOProcID?
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            if channels == 1 {
                ring.write(data, count: frames)
            } else {
                ring.write(count: frames) { i in
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[i * channels + c] }
                    return sum / Float(channels)
                }
            }
        }, "create IOProc")
        procID = proc
        self.ring = ring
        resampler = try Resampler(from: format.mSampleRate, to: MicrophoneCapture.sampleRate)
        try HAL.check(AudioDeviceStart(aggregateDevice, proc), "start aggregate device")
    }

    /// Everything captured since the last call, as 48 kHz mono.
    public func drain() -> [Float] {
        queue.sync {
            let raw = ring.drain()
            return resampler?.process(raw) ?? raw
        }
    }

    public func stop() {
        if let listener = outputListener {
            var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            outputListener = nil
        }
        queue.sync {
            running = false
            teardownTap()
        }
    }

    private func teardownTap() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func ownProcessObject() -> AudioObjectID {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return object
    }

    deinit { stop() }
}

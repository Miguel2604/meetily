import CoreAudio
import Foundation

public struct AudioDevice: Sendable, Hashable, Identifiable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int

    public init(id: AudioObjectID, uid: String, name: String, inputChannels: Int, outputChannels: Int) {
        self.id = id; self.uid = uid; self.name = name
        self.inputChannels = inputChannels; self.outputChannels = outputChannels
    }
}

public enum DeviceEvent: Sendable, Equatable {
    case listChanged
    case defaultInputChanged
    case defaultOutputChanged
}

/// Core Audio HAL device queries.
public enum AudioDevices {
    public static func all() -> [AudioDevice] {
        let ids: [AudioObjectID] = HAL.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap(device)
    }

    public static func inputs() -> [AudioDevice] { all().filter { $0.inputChannels > 0 && !isTapAggregate($0) } }
    public static func outputs() -> [AudioDevice] { all().filter { $0.outputChannels > 0 && !isTapAggregate($0) } }

    public static func defaultInput() -> AudioDevice? {
        HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice).flatMap(device)
    }

    public static func defaultOutput() -> AudioDevice? {
        HAL.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice).flatMap(device)
    }

    public static func device(_ id: AudioObjectID) -> AudioDevice? {
        guard id != kAudioObjectUnknown, let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDevice(id: id, uid: uid, name: HAL.string(id, kAudioObjectPropertyName) ?? uid,
                           inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                           outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
    }

    static let tapAggregatePrefix = "com.meetily.ai.tap"

    /// Our own private tap aggregates never show up in pickers.
    static func isTapAggregate(_ device: AudioDevice) -> Bool { device.uid.hasPrefix(tapAggregatePrefix) }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Device list and default-device changes, until the stream is cancelled.
    public static func events() -> AsyncStream<DeviceEvent> {
        AsyncStream { continuation in
            let system = AudioObjectID(kAudioObjectSystemObject)
            let queue = DispatchQueue(label: "meety.device-events")
            let watched: [(AudioObjectPropertySelector, DeviceEvent)] = [
                (kAudioHardwarePropertyDevices, .listChanged),
                (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
                (kAudioHardwarePropertyDefaultOutputDevice, .defaultOutputChanged),
            ]
            let listeners = watched.map { selector, event in
                let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield(event) }
                var address = HAL.address(selector)
                AudioObjectAddPropertyListenerBlock(system, &address, queue, block)
                return (selector, block)
            }
            nonisolated(unsafe) let registered = listeners
            continuation.onTermination = { _ in
                for (selector, block) in registered {
                    var address = HAL.address(selector)
                    AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
                }
            }
        }
    }
}

/// Which microphone to record, as `resolve_mic_or_default` decides it.
public enum MicResolution: Sendable, Equatable {
    /// The requested mic, or the default when none was requested.
    case requested(AudioDevice)
    /// The requested mic is gone; recording with the default (the old `mic-device-switched`).
    case fellBack(AudioDevice)
    /// No usable mic; record system audio only (the old `mic-unavailable`).
    case unavailable

    public static func resolve(requested name: String?, inputs: [AudioDevice], defaultInput: AudioDevice?) -> MicResolution {
        if let name, let match = inputs.first(where: { $0.name == name || $0.uid == name }) { return .requested(match) }
        guard let defaultInput else { return .unavailable }
        return name == nil ? .requested(defaultInput) : .fellBack(defaultInput)
    }

    public var device: AudioDevice? {
        switch self {
        case .requested(let d), .fellBack(let d): d
        case .unavailable: nil
        }
    }
}

enum HAL {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!) == noErr ? count : 0
        }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw AudioError.osStatus(what, status) }
    }
}

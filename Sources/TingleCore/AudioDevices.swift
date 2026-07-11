import CoreAudio
import Foundation

/// An audio input device as considered for tone detection.
struct AudioInputDevice: Equatable {
    var uid: String
    var name: String
    /// kAudioDeviceTransportType* four-char code.
    var transportType: UInt32
    var inputChannelCount: Int
}

/// Pure candidate filtering + ranking for the detection input. Testable with
/// fake descriptors; no CoreAudio calls in here.
///
/// tingle listens on a line-in capture device (the ting's line-out feeds it) —
/// never the built-in mic, and never CoreAudio synthetics like
/// "CADefaultDeviceAggregate" or app-virtual devices (Teams/Zoom).
enum InputDeviceSelector {
    /// Case-insensitive name fragments that mark a preferred device, in
    /// priority tiers. "Line in" outranks brand matches: multi-jack capture
    /// boxes (e.g. the Cubilux HLMS-C4) expose BOTH a "MIC IN" and a
    /// "Line IN" device, and loud ultrasonic chirps bleed across jacks well
    /// enough for the beacon scanner to lock the wrong one — where speech
    /// then arrives as near-silence (buttons work, dictation dead).
    static let nameTiers: [[String]] = [["line in", "line-in"], ["cubilux"]]
    static var preferredNameFragments: [String] { nameTiers.flatMap { $0 } }

    /// Lower = better; nil = no name match.
    static func nameTier(_ name: String) -> Int? {
        let lowered = name.lowercased()
        for (tier, fragments) in nameTiers.enumerated() where fragments.contains(where: { lowered.contains($0) }) {
            return tier
        }
        return nil
    }

    /// Aggregates, virtual devices, the built-in mic, and output-only devices
    /// are never candidates.
    static func isExcluded(_ device: AudioInputDevice) -> Bool {
        guard device.inputChannelCount > 0 else { return true }
        switch device.transportType {
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeAutoAggregate,
             kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeBuiltIn:
            return true
        default:
            return false
        }
    }

    static func nameMatchesPreferred(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return preferredNameFragments.contains { lowered.contains($0) }
    }

    /// Candidates in rank order: "line in" name matches first, then brand
    /// matches, then any other USB-transport input. Devices matching none
    /// are not offered at all. The first candidate is the default when no
    /// UID is configured.
    static func candidates(from devices: [AudioInputDevice]) -> [AudioInputDevice] {
        let eligible = devices.filter { !isExcluded($0) }
        let named = eligible
            .compactMap { device in nameTier(device.name).map { (device, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
        let usb = eligible.filter {
            nameTier($0.name) == nil && $0.transportType == kAudioDeviceTransportTypeUSB
        }
        return named + usb
    }
}

/// CoreAudio enumeration + change notifications for the selector above.
enum AudioDeviceCatalog {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// All devices with their UID/name/transport/input-channel facts.
    static func systemInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceIDs) == noErr
        else { return [] }
        return deviceIDs.compactMap(describe)
    }

    /// Invoke `block` (on `queue`) whenever the device list changes
    /// (unplug/replug). The listener lives for the process lifetime.
    static func onDevicesChanged(queue: DispatchQueue, _ block: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(systemObject, &address, queue) { _, _ in block() }
    }

    // MARK: - Per-device properties

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, selector: kAudioObjectPropertyName)
        else { return nil }
        return AudioInputDevice(
            uid: uid,
            name: name,
            transportType: uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0,
            inputChannelCount: inputChannelCount(of: id)
        )
    }

    private static func inputChannelCount(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32Property(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

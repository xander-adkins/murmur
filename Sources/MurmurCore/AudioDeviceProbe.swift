import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
}

/// CoreAudio input device listing: for the menu bar picker, for pinning a device by name, and for
/// logging when the list changes (AirPods coming and going explains most "nothing heard" takes).
final class AudioDeviceProbe {
    private var listenerInstalled = false

    func start() {
        logInputDevices(reason: "startup")
        installDeviceListener()
    }

    func stop() {
        removeDeviceListener()
    }

    static func inputDevice(matching name: String) -> AudioInputDevice? {
        inputDevices().first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    /// One property read; cheap enough to call on every button press.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return deviceID
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = defaultInputDeviceID() else {
            return nil
        }
        return inputDevices().first { $0.id == deviceID }
    }

    static func inputDevices() -> [AudioInputDevice] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else {
            return []
        }

        return devices
            .filter { hasInputStreams($0) }
            .map { AudioInputDevice(id: $0, name: name(of: $0)) }
    }

    // MARK: - Change listener

    fileprivate func logDeviceListChanged() {
        logInputDevices(reason: "coreaudio-device-list-changed")
    }

    private func logInputDevices(reason: String) {
        let summary = Self.inputDevices().map { "\($0.id):\($0.name)" }.joined(separator: " | ")
        log(.audioProbe, "reason=\(reason) inputDevices=\(summary.isEmpty ? "none" : summary)")
    }

    private func installDeviceListener() {
        guard !listenerInstalled else {
            return
        }
        var address = Self.systemAddress(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, audioDeviceListChanged, Unmanaged.passUnretained(self).toOpaque()
        )
        guard status == noErr else {
            log(.audioProbe, "failed to install device listener status=\(status)")
            return
        }
        listenerInstalled = true
    }

    private func removeDeviceListener() {
        guard listenerInstalled else {
            return
        }
        var address = Self.systemAddress(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, audioDeviceListChanged, Unmanaged.passUnretained(self).toOpaque()
        )
        listenerInstalled = false
    }

    // MARK: - CoreAudio helpers

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of deviceID: AudioDeviceID) -> String {
        var address = systemAddress(kAudioObjectPropertyName)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? (name as String? ?? "unknown") : "unknown"
    }
}

private let audioDeviceListChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else {
        return noErr
    }
    let probe = Unmanaged<AudioDeviceProbe>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        probe.logDeviceListChanged()
    }
    return noErr
}

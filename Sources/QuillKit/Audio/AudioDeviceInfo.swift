import CoreAudio
import Foundation

/// Which microphone the system was actually using.
///
/// This exists for the comparison rig, not for the app. Wispr Flow records a
/// `micDevice` on every transcript, and that single column is what lets a run be
/// audited afterwards: if it says "Built-in" when the rig was playing into a
/// virtual loopback device, the app never heard the test audio and the resulting
/// word-error-rate is fiction. Quill had no equivalent, so its runs could not be
/// audited to the same standard as the app it is being measured against.
public enum AudioDeviceInfo {

    /// One selectable microphone.
    public struct InputDevice: Equatable, Sendable, Identifiable {
        public let id: AudioDeviceID
        /// Stable across reboots and replugs; the numeric id is not, which is why
        /// this is what gets saved.
        public let uid: String
        public let name: String
    }

    /// Human-readable name of the current default input device, or nil if
    /// CoreAudio will not say.
    public static func currentInputName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return name(of: deviceID)
    }

    /// The microphone dictation will actually use: the one chosen in Settings if
    /// it is still plugged in, otherwise whatever the system default is.
    ///
    /// The fallback is not tidiness. A saved device that has been unplugged would
    /// otherwise stamp every transcript with a microphone that recorded nothing,
    /// which is precisely the audit failure this whole file exists to prevent.
    public static func activeInputName(uid: String? = QuillSettings.shared.inputDeviceUID) -> String? {
        if let uid, let device = inputDevices().first(where: { $0.uid == uid }) {
            return device.name
        }
        return currentInputName()
    }

    /// Every device that can actually record, in the order CoreAudio lists them.
    ///
    /// "Can record" is decided by asking for the input stream configuration and
    /// counting channels — `kAudioDevicePropertyStreams` alone lists speakers,
    /// which would put "MacBook Air Speakers" in a microphone menu.
    public static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard inputChannelCount(of: id) > 0,
                  !isHidden(id),
                  let name = name(of: id),
                  let uid = uid(of: id),
                  !isPrivateAggregate(name: name, uid: uid)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    /// CoreAudio's own "do not show this to a person" flag.
    ///
    /// Counting input channels is not enough to decide what belongs in a
    /// microphone menu. The system builds aggregate devices of its own while
    /// apps are recording, and they have input channels, real device IDs and
    /// names like `CADefaultDeviceAggregate-47292-0` — a process ID in the
    /// middle of it. One of those appeared in Quill's picker, offered to the user
    /// as something to choose.
    private static func isHidden(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &hidden) == noErr
        else { return false }
        return hidden != 0
    }

    /// Belt and braces for the ones that are not flagged hidden.
    ///
    /// `IsHidden` is the correct check and it is not always set on these — the
    /// aggregate seen in the picker was not hidden at all. The name is a
    /// documented CoreAudio convention rather than a guess, and matching on it
    /// costs nothing. Deliberately narrow: BlackHole is also a virtual device and
    /// is a perfectly legitimate thing to record from, so this excludes only what
    /// the system built for itself.
    private static func isPrivateAggregate(name: String, uid: String) -> Bool {
        name.hasPrefix("CADefaultDeviceAggregate")
            || uid.hasPrefix("CADefaultDeviceAggregate")
            // Private aggregates get a tilde-prefixed UID.
            || uid.hasPrefix("~")
    }

    /// nil when the saved device is gone — callers fall back to the default.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uid(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }
}

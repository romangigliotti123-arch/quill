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

    /// Human-readable name of the current default input device, or nil if
    /// CoreAudio will not say.
    public static func currentInputName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return name(of: deviceID)
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

// Probe 2 — is the engine's reported format actually the NEW device's, or a
// stale reading of the old one?
//
// Probe 1 showed installTap throwing "format mismatch, 2ch 44100" while both
// AVAudioFormat and the AUHAL stream format agreed on 44100 — and while the
// system reports BlackHole running at 48000. That points at the engine holding
// a format from before the device switch.
//
// This asks the DEVICE directly (kAudioDevicePropertyNominalSampleRate on the
// AudioObject, not the audio unit), and compares three numbers:
//   1. what the device itself says it runs at
//   2. what the audio unit's stream format says
//   3. what AVAudioEngine's inputNode reports
// If (1) disagrees with (2)/(3), the engine is stale and no amount of waiting
// fixes it — the fix has to force the node to rebuild.
import AVFoundation
import Foundation

func devices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids
}

func uid(of id: AudioDeviceID) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return st == noErr ? (cf as String) : nil
}

func name(of id: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &cf) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
    return st == noErr ? (cf as String) : "?"
}

/// The DEVICE's own sample rate, straight from the AudioObject.
func deviceRate(_ id: AudioDeviceID) -> Double? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let st = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &rate)
    return st == noErr ? rate : nil
}

func unitRate(_ unit: AudioUnit, scope: AudioUnitScope, element: AudioUnitElement) -> Double? {
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, element, &asbd, &size)
    return st == noErr ? asbd.mSampleRate : nil
}

print("=== all input-capable devices ===")
for id in devices() {
    if let u = uid(of: id) {
        print(String(format: "  id=%-5d rate=%-8.0f %@  [%@]", id, deviceRate(id) ?? -1, name(of: id), u))
    }
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BlackHole2ch_UID"
guard let devID = devices().first(where: { uid(of: $0) == target }) else {
    print("FAIL: \(target) not found"); exit(1)
}
print("\n=== target: \(name(of: devID)) id=\(devID) ===")
print("device's OWN nominal rate: \(deviceRate(devID) ?? -1)")

let engine = AVAudioEngine()
let input = engine.inputNode
guard let unit = input.audioUnit else { print("FAIL: no unit"); exit(1) }

print("\n--- before set ---")
print("  engine inputNode outputFormat: \(input.outputFormat(forBus: 0).sampleRate)")
print("  engine inputNode inputFormat : \(input.inputFormat(forBus: 0).sampleRate)")
print("  unit stream fmt (out,elem1)  : \(unitRate(unit, scope: kAudioUnitScope_Output, element: 1) ?? -1)")
print("  unit stream fmt (in,elem1)   : \(unitRate(unit, scope: kAudioUnitScope_Input, element: 1) ?? -1)")

var id = devID
let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                              kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
print("\nAudioUnitSetProperty -> \(st)")
usleep(500_000)

// Confirm the unit really did switch device.
var got = AudioDeviceID(0)
var gotSize = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global, 0, &got, &gotSize)
print("unit's CurrentDevice now: \(got)  (wanted \(devID))")

print("\n--- after set + 500ms ---")
print("  device's OWN nominal rate    : \(deviceRate(devID) ?? -1)")
print("  engine inputNode outputFormat: \(input.outputFormat(forBus: 0).sampleRate)")
print("  engine inputNode inputFormat : \(input.inputFormat(forBus: 0).sampleRate)")
print("  unit stream fmt (out,elem1)  : \(unitRate(unit, scope: kAudioUnitScope_Output, element: 1) ?? -1)")
print("  unit stream fmt (in,elem1)   : \(unitRate(unit, scope: kAudioUnitScope_Input, element: 1) ?? -1)")

let devR = deviceRate(devID) ?? -1
let engR = input.outputFormat(forBus: 0).sampleRate
print("\n=== VERDICT ===")
if devR != engR {
    print("STALE: engine reports \(engR) but the device runs at \(devR).")
    print("No settle loop can fix this — the engine is not re-reading the device.")
} else {
    print("engine agrees with device at \(devR).")
    print("If installTap still throws, the mismatch is with a THIRD format")
    print("(the graph's internal inputHWFormat), not either of these.")
}

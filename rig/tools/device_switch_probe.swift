// rig/tools/device_switch_probe.swift — switch input devices repeatedly and
// install a tap each time.
//
// build: xcrun swiftc -O -o rig/bin/device_switch_probe rig/tools/device_switch_probe.swift
// run:   rig/bin/device_switch_probe
//
// This is the test that would have found the AudioCapture crash in two minutes.
// It failed for hours instead because every attempt to reproduce it went through
// the whole app — build, launch, drive the hotkey, read history.json — and the
// answer was three numbers printed side by side:
//
//     BlackHole2ch_UID   in=48000 out=44100 [DIFFER]
//     BuiltInMicrophoneD in=44100 out=44100 [same]
//
// `installTap` asserts against the `in` column. AudioCapture was reading the
// `out` column. They agree on the built-in microphone, which is why it survived
// every test that used one, and every BlackHole run aborted the process.
//
// Keep it. Any future change to how the input device is selected should be run
// through this first, because the failure mode it guards is an uncatchable
// Objective-C exception rather than a test that goes red.
//
// The scenario the crash actually came from: start on one device, switch to
// another mid-session, install a tap again. That is what "run the eval, then go
// back to the built-in mic" does, and what unplugging a headset does.
//
// Repeats the whole cycle both directions several times. If inputFormat is the
// right property to read, every iteration installs and captures. If there is
// still a stale-format path anywhere, this is where it shows up.
import AVFoundation
import Foundation

func devices() -> [AudioDeviceID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
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

let targets = ["BlackHole2ch_UID", "BuiltInMicrophoneDevice"]
var ok = 0, bad = 0

for round in 1...4 {
    for target in targets {
        guard let dev = devices().first(where: { uid(of: $0) == target }) else {
            print("round \(round) \(target): NOT PRESENT"); continue
        }
        // A fresh engine per iteration is not the interesting case — reuse one,
        // the way the app does, so a cached format has somewhere to hide.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else { print("no unit"); exit(1) }
        var id = dev
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        usleep(200_000)

        let fmt = input.inputFormat(forBus: 0)          // the fix
        let out = input.outputFormat(forBus: 0)         // what it used to read
        guard fmt.sampleRate > 0 else { print("round \(round) \(target): zero rate"); bad += 1; continue }

        var frames = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { b, _ in
            frames += Int(b.frameLength)
        }
        engine.prepare()
        do {
            try engine.start()
            usleep(400_000)
            engine.stop()
            input.removeTap(onBus: 0)
            let agree = fmt.sampleRate == out.sampleRate ? "same" : "DIFFER"
            print("round \(round) \(target.prefix(18).padding(toLength: 18, withPad: " ", startingAt: 0)) "
                + "in=\(Int(fmt.sampleRate)) out=\(Int(out.sampleRate)) [\(agree)] frames=\(frames)")
            ok += 1
        } catch {
            print("round \(round) \(target): engine.start FAILED \(error)")
            bad += 1
        }
    }
}
print("\n\(ok) succeeded, \(bad) failed")
exit(bad == 0 ? 0 : 1)

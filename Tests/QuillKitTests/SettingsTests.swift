import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import QuillKit

// The three pieces added when settings became a thing a user can change: the
// push-to-talk gesture, the store behind it, and the diff that puts words on
// screen while you are still speaking.

private typealias SM = HotkeyStateMachine

// MARK: - Push to talk as its own key

@Test func tappingThePushKeyStartsHandsFreeWithNoArmDelay() {
    var machine = SM()
    // No arm timer and no wait: there is no tap-vs-hold ambiguity on a key that
    // only ever toggles, so the recording starts on the press itself.
    let effects = machine.handle(.toggleDown(isolated: true), at: 1)
    #expect(effects == [.beginPreroll, .notifyPressed])
    #expect(machine.state == .handsFree)
}

@Test func tappingThePushKeyAgainEndsHandsFree() {
    var machine = SM()
    _ = machine.handle(.toggleDown(isolated: true), at: 1)
    #expect(machine.handle(.toggleUp, at: 1.05) == [])
    #expect(machine.state == .handsFree, "releasing a toggle key must not end the dictation")
    #expect(machine.handle(.toggleDown(isolated: true), at: 4) == [.notifyReleased])
    #expect(machine.state == .idle)
}

@Test func theHoldKeyAlsoEndsHandsFreeStartedByThePushKey() {
    var machine = SM()
    _ = machine.handle(.toggleDown(isolated: true), at: 1)
    #expect(machine.handle(.triggerDown(isolated: true), at: 4) == [.notifyReleased])
    #expect(machine.state == .idle)
}

@Test func aStrayModifierCannotStrandAHandsFreeRecording() {
    var machine = SM()
    _ = machine.handle(.toggleDown(isolated: true), at: 1)
    // Isolation is required to *start* and deliberately not to *stop*: refusing
    // to stop because a ⇧ happened to be down would leave the microphone open
    // with no way to close it.
    #expect(machine.handle(.toggleDown(isolated: false), at: 4) == [.notifyReleased])
    #expect(machine.state == .idle)
}

@Test func aStrayModifierCannotStrandAHandsFreeRecordingOnTheTriggerPathEither() {
    // The path the test above does NOT cover, and the one the app actually
    // ships. Hold and toggle default to the same key, so HotkeyEngine's
    // `keyCode == hold.keyCode` branch claims the event and `.toggleDown` is
    // never produced — the forgiving clause it pins is dead code on the default
    // binding, and every real stop with a stray ⇧ held used to be swallowed:
    // microphone open, HUD up, nothing to close it with.
    var machine = SM()
    _ = machine.handle(.triggerDown(isolated: true), at: 1)
    _ = machine.handle(.triggerUp, at: 1.05)
    _ = machine.handle(.triggerDown(isolated: true), at: 1.2)
    _ = machine.handle(.triggerUp, at: 1.25)
    #expect(machine.state == .handsFree)

    // ⇧ is down, so the tap is not isolated. It cannot stop on the press —
    // the trigger is itself a chord modifier, and in ⇧⌥→ the ⇧ lands first, so
    // stopping here would end a dictation on the ⌥ of a chord the user is
    // typing and paste the transcript over their own selection.
    #expect(machine.handle(.triggerDown(isolated: false), at: 3) == [])
    #expect(machine.state == .handsFree)

    // The release with no keystroke in between is what proves it was a tap.
    #expect(machine.handle(.triggerUp, at: 3.1) == [.notifyReleased])
    #expect(machine.state == .idle)
}

@Test func aChordDuringHandsFreeIsNotAStop() {
    // ⇧⌥→ — the other half of the same decision. The arrow's key-down is what
    // says the trigger was part of a chord, and hands-free is the mode that
    // deliberately tolerates typing, so the dictation carries on.
    var machine = SM()
    _ = machine.handle(.toggleDown(isolated: true), at: 1)
    #expect(machine.state == .handsFree)

    #expect(machine.handle(.triggerDown(isolated: false), at: 3) == [])
    #expect(machine.handle(.keyDown(keyCode: 124, isBare: false), at: 3.05) == [])
    #expect(machine.state == .handsFree)

    // And the release that follows must not fire the stop the chord cancelled.
    #expect(machine.handle(.triggerUp, at: 3.2) == [])
    #expect(machine.state == .handsFree)
}

@Test func thePushKeyAsPartOfAChordDoesNotStartAnything() {
    var machine = SM()
    #expect(machine.handle(.toggleDown(isolated: false), at: 1) == [])
    #expect(machine.state == .idle)
}

@Test func thePushKeyPressedDuringAHoldIsIgnored() {
    var machine = SM()
    _ = machine.handle(.triggerDown(isolated: true), at: 1)
    _ = machine.handle(.armTimerFired(token: 1), at: 1.2)
    #expect(machine.state == .holding)
    #expect(machine.handle(.toggleDown(isolated: true), at: 1.5) == [])
    #expect(machine.state == .holding, "the hold is the gesture in flight and decides when it ends")
}

@Test func thePushKeyDuringTheArmWindowAbandonsTheGesture() {
    var machine = SM()
    _ = machine.handle(.triggerDown(isolated: true), at: 1)
    #expect(machine.state == .armed(token: 1))
    let effects = machine.handle(.toggleDown(isolated: true), at: 1.05)
    #expect(effects == [.cancelArmTimer, .abortPreroll])
    #expect(machine.state == .idle)
}

// MARK: - The store

private func temporarySettingsURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-settings-\(UUID().uuidString).json")
}

@Test func settingsDefaultToOneKeyDoingBothJobs() {
    let settings = QuillSettings(url: temporarySettingsURL())
    #expect(settings.hold == .rightOption)
    #expect(settings.toggle == .rightOption)
    #expect(settings.toggleSharesHoldKey)
    #expect(settings.liveText)
    #expect(settings.inputDeviceUID == nil)
}

@Test func changesSurviveARelaunch() {
    let url = temporarySettingsURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let first = QuillSettings(url: url)
    first.setHold(HotkeyBinding(keyCode: 62))
    first.setToggle(HotkeyBinding(keyCode: 63))
    first.setInputDeviceUID("BlackHole2ch_UID")
    first.setLiveText(false)

    let second = QuillSettings(url: url)
    #expect(second.hold.keyCode == 62)
    #expect(second.toggle.keyCode == 63)
    #expect(second.inputDeviceUID == "BlackHole2ch_UID")
    #expect(second.liveText == false)
    #expect(!second.toggleSharesHoldKey)
}

@Test func markConfiguredWritesTheFileEvenWithNothingChanged() {
    // The regression: onboarding used to force a write by setting a value back
    // to its own current value, which `update`'s own change-detection quietly
    // swallows — so someone who accepted every default finished setup and
    // settings.json still did not exist. isFirstRun is keyed on that file, so
    // onboarding came back on every single launch, forever, for anyone who
    // never touched a setting.
    let url = temporarySettingsURL()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(!FileManager.default.fileExists(atPath: url.path))
    let settings = QuillSettings(url: url)
    #expect(!FileManager.default.fileExists(atPath: url.path), "construction alone must not write")

    settings.markConfigured()
    #expect(FileManager.default.fileExists(atPath: url.path))

    // And it round-trips as the untouched defaults, not as some marker value.
    let reloaded = QuillSettings(url: url)
    #expect(reloaded.hold.keyCode == HotkeyBinding.rightOption.keyCode)
    #expect(reloaded.historyRetention == QuillSettings.Values().historyRetention)
}

@Test func aCorruptSettingsFileFallsBackToDefaultsRatherThanFailing() {
    let url = temporarySettingsURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try? "not json at all".write(to: url, atomically: true, encoding: .utf8)

    let settings = QuillSettings(url: url)
    #expect(settings.hold == .rightOption, "a bad file must not stop the app dictating")
}

@Test func aSettingsFileFromAnOlderBuildKeepsWhatItHasAndDefaultsTheRest() {
    let url = temporarySettingsURL()
    defer { try? FileManager.default.removeItem(at: url) }
    // No `liveText` key: written before the setting existed.
    try? #"{"holdKeyCode":62,"toggleKeyCode":62}"#.write(to: url, atomically: true, encoding: .utf8)

    let settings = QuillSettings(url: url)
    #expect(settings.hold.keyCode == 62)
    #expect(settings.liveText, "a missing key must take the default, not nil out the feature")
}

// MARK: - Bindings

@Test func everyAssignableKeyHasAPresenceBitThatIdentifiesOneSide() {
    // The device-dependent bits are what let a release of right ⌥ be seen while
    // left ⌥ is still held. A duplicate here means one of the two keys can never
    // be released, and the recording never stops.
    let masks = HotkeyBinding.assignable
        .filter { $0.keyCode != 63 }
        .map(\.presenceMask.rawValue)
    #expect(Set(masks).count == masks.count)
}

@Test func everyAssignableKeyHasAName() {
    for binding in HotkeyBinding.assignable {
        #expect(!binding.displayName.hasPrefix("Key "), "\(binding.keyCode) has no name")
        #expect(binding.glyph != "?")
    }
}

/// A live typer that records instead of typing. Passed to every coordinator
/// built in a test: the real one posts backspaces into whatever app is
/// frontmost, so a suite that forgot would edit the developer's editor.
final class SilentKeystrokes: KeystrokeEmitting {
    func type(_ text: String) -> Bool { true }
    func backspace(times: Int) -> Bool { true }
    func chord(key: CGKeyCode, flags: CGEventFlags) -> Bool { true }
}

/// Settings isolated to this test, with live text off so the assertions below
/// are about the paste path they were written for.
@MainActor
func pasteOnlySettings() -> QuillSettings {
    let settings = QuillSettings(
        url: FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-test-settings-\(UUID().uuidString).json"))
    settings.setLiveText(false)
    return settings
}

@Test func aRunCanBePointedAtItsOwnSettingsFile() {
    // The eval rig needs a specific microphone and specific bindings, and the
    // only way to give it those was to overwrite the real settings file and
    // restore it afterwards by hand. Which means that once, it was not restored:
    // Roman's microphone choice was erased and "show text as you speak" came back
    // off, silently, hours after he had asked for it.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let settings = QuillSettings(url: scratch)
    settings.setLiveText(false)
    settings.setInputDeviceUID("ScratchMic")

    #expect(FileManager.default.fileExists(atPath: scratch.path))
    let reloaded = QuillSettings(url: scratch)
    #expect(reloaded.liveText == false)
    #expect(reloaded.inputDeviceUID == "ScratchMic")
    // The real file is untouched: a fresh store on the default path does not see
    // anything this test did.
    #expect(QuillSettings.defaultURL.path != scratch.path)
}

// MARK: - The key recorder cannot leave the hotkey deaf

/// `isCapturingHotkey` makes the event tap deaf on purpose — the keypress that
/// assigns a binding must not also start a dictation. The bug was that
/// "listening" outlived the control that was listening.
///
/// Clicking the chip and then leaving with the MOUSE — closing the window, or
/// clicking straight into the app you were about to dictate into — left the flag
/// set with no way back. Hold, hands-free, Escape-cancel and ⌥⌫ were all dead for
/// the rest of the session, and the menu still said "Ready". The dashboard is
/// held by AppDelegate for the app's lifetime, so deallocation never rescued it.
@Test @MainActor func abandoningTheKeyRecorderDoesNotLeaveTheHotkeyDeaf() {
    let settings = QuillSettings.shared
    defer { settings.isCapturingHotkey = false }

    func armed(_ recorder: KeyRecorderControl) -> Bool {
        settings.isCapturingHotkey
    }

    // Pulled out of the view tree with a capture armed — a section swap, or the
    // dashboard rebuilding itself after a setting changed.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    // Or `close()` releases it under the local reference and the test process
    // dies on the next line rather than reporting anything.
    window.isReleasedWhenClosed = false
    let removed = KeyRecorderControl(binding: .rightOption, style: .dark)
    window.contentView?.addSubview(removed)
    removed.startRecordingForTesting()
    #expect(armed(removed), "the recorder did not arm at all — this test proves nothing")
    removed.removeFromSuperview()
    #expect(!armed(removed), "leaving the view tree left the hotkey deaf")

    // And the window closing under it.
    let closed = KeyRecorderControl(binding: .rightOption, style: .dark)
    window.contentView?.addSubview(closed)
    closed.startRecordingForTesting()
    #expect(armed(closed))
    window.close()
    #expect(!armed(closed), "closing the window left the hotkey deaf")
}

/// Two recorders live on the Settings screen and the section is rebuilt whenever
/// a setting changes. Tearing down the idle one must not clear a capture the
/// other one has live.
@Test @MainActor func tearingDownAnIdleRecorderDoesNotCancelALiveCapture() {
    let settings = QuillSettings.shared
    defer { settings.isCapturingHotkey = false }

    let live = KeyRecorderControl(binding: .rightOption, style: .dark)
    live.startRecordingForTesting()
    #expect(settings.isCapturingHotkey)

    do {
        let idle = KeyRecorderControl(binding: .rightOption, style: .dark)
        _ = idle
    }
    #expect(settings.isCapturingHotkey, "an idle recorder's deinit cancelled a live capture")
}

// MARK: - The ⌥⌫ switch

@Test func theUndoChordIsOnByDefaultAndSurvivesARoundTrip() {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-undochord-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: scratch) }

    let settings = QuillSettings(url: scratch)
    #expect(settings.undoChord)

    settings.setUndoChord(false)
    #expect(!settings.undoChord)
    #expect(!QuillSettings(url: scratch).undoChord)
}

@Test func aSettingsFileWrittenBeforeTheSwitchExistedKeepsTheChord() {
    // Every file on disk predates this key. Decoding them to `false` would turn
    // the feature off for the one person using the app, silently, on upgrade.
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-oldsettings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: scratch) }
    try? #"{"holdKeyCode":61,"toggleKeyCode":61,"liveText":true}"#
        .write(to: scratch, atomically: true, encoding: .utf8)

    #expect(QuillSettings(url: scratch).undoChord)
}

@Test func aProviderThatDoesNotCareAboutTheChordStillAllowsIt() {
    // The default on the protocol. Every test double conforms to it, and a
    // double that had to opt in would silently disable the chord in whichever
    // suite forgot.
    #expect(QuillSettings(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-\(UUID().uuidString).json")).undoChord)
}

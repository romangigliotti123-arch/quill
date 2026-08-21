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

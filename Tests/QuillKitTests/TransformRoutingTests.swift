import AppKit
import Foundation
import Testing
@testable import QuillKit

// Transforms, connected to the app at last.
//
// `TransformEngine`, `CommandRouter` and `SelectionReader` were 1,300 lines of
// tested, working code that nothing ever constructed. The Transforms screen
// listed eight of them, each captioned with the phrase that runs it, and saying
// any of those phrases typed it into the document as content.
//
// These tests are about the WIRING — that an utterance reaches the router, that
// a command runs instead of being typed, and above all that ordinary dictation
// still gets typed. The router's own guards are pinned in CommandRouterTests.

/// A bare instruction must not be typed into the document.
@MainActor
@Test func aSpokenTransformRunsInsteadOfBeingTyped() async {
    let router = CommandRouter()
    let transforms = TransformStore.seed

    let routed = router.route("make that a bullet list", transforms: transforms)
    guard case .transform(let picked) = routed.decision else {
        Issue.record("the router did not recognise its own advertised phrase: \(routed.reason)")
        return
    }
    #expect(picked.name == "Bullet points")
}

/// And the far more important direction: ordinary dictation is still content.
///
/// Treating a command as content types five words the user deletes. Treating
/// content as a command DELETES WHAT THEY SAID. Every sentence here is one a
/// person would really dictate.
@MainActor
@Test func ordinarySentencesAreStillTypedRatherThanRun() {
    let router = CommandRouter()
    let transforms = TransformStore.seed
    for said in [
        "make that a bullet list in the report tomorrow",
        "I need to make that shorter before Friday",
        "tell Noah we should summarise that for the client",
        "can you fix the grammar in that paragraph he sent",
        "shorter days are coming",
        "the email I sent this morning",
        "summarise means to cut it down",
    ] {
        let routed = router.route(said, transforms: transforms)
        guard case .content = routed.decision else {
            Issue.record("would have eaten a dictation: \(said) → \(routed.decision)")
            continue
        }
    }
}

/// Every phrase the Transforms screen advertises actually routes.
///
/// The screen prints these under each transform as "how to run it", and until the
/// engine was connected every one of them typed itself into the document.
@MainActor
@Test func everyPhraseTheScreenAdvertisesActuallyRuns() {
    let router = CommandRouter()
    let transforms = TransformStore.seed
    for transform in transforms where transform.isEnabled {
        for trigger in transform.triggers {
            let routed = router.route(trigger, transforms: transforms)
            guard case .transform(let picked) = routed.decision else {
                Issue.record("advertised phrase does not run: \(trigger) → \(routed.reason)")
                continue
            }
            #expect(picked.id == transform.id,
                    "\(trigger) ran \(picked.name) instead of \(transform.name)")
        }
    }
}

// MARK: - The chord half

@Test func aChordFindsItsTransformAndNothingElseDoes() {
    // Every part of the chord path existed except the line that consults it.
    // Assigning ⌃⌥B to "Bullet points" drew a keycap in the editor, saved a
    // TransformHotkey to disk, and then typed a "b" into the document, because
    // the event tap never asked TransformHotkeyRouter anything.
    let bullets = Transform(
        name: "Bullet points", instruction: "as a list", triggers: [],
        hotkey: TransformHotkey(keyCode: 11, modifiers: [.maskControl, .maskAlternate]))
    let shorter = Transform(
        name: "Shorter", instruction: "shorter", triggers: [],
        hotkey: TransformHotkey(keyCode: 1, modifiers: [.maskControl, .maskAlternate]))
    let unbound = Transform(name: "Formal", instruction: "formally", triggers: [], hotkey: nil)
    let all = [bullets, shorter, unbound]

    #expect(TransformHotkeyRouter.transform(forKeyCode: 11,
                                            flags: [.maskControl, .maskAlternate],
                                            in: all)?.name == "Bullet points")
    // A different chord, and a bare key, are somebody else's.
    #expect(TransformHotkeyRouter.transform(forKeyCode: 11, flags: [.maskCommand], in: all) == nil)
    #expect(TransformHotkeyRouter.transform(forKeyCode: 11, flags: [], in: all) == nil)
    // A transform with no chord can never be reached by one.
    #expect(TransformHotkeyRouter.transform(forKeyCode: 0, flags: [], in: all) == nil)
}

@Test func aDisabledTransformsChordIsNotClaimed() {
    // Otherwise turning a transform off would still eat its key, which is worse
    // than the transform running: the key does nothing at all and there is no
    // way to tell why.
    var off = Transform(
        name: "Bullet points", instruction: "as a list", triggers: [],
        hotkey: TransformHotkey(keyCode: 11, modifiers: [.maskControl, .maskAlternate]))
    off.isEnabled = false
    #expect(TransformHotkeyRouter.transform(forKeyCode: 11,
                                            flags: [.maskControl, .maskAlternate],
                                            in: [off]) == nil)
}

import Foundation
import Testing
@testable import QuillKit

// The diff that keeps live text honest.
//
// Everything here is about one hazard: this is the only code in Quill that
// issues *deletions* into an app it does not own. An off-by-one deletes a
// character the user typed themselves, in a document Quill has no way to read
// back, and they find out later with nothing to blame. So the arithmetic is
// tested directly rather than through a keyboard.

private func edit(_ from: String, _ to: String) -> (deletions: Int, insertion: String) {
    LiveTyper.edit(from: from, to: to)
}

@Test func theFirstWordsAreAllInsertion() {
    let result = edit("", "Hello there")
    #expect(result.deletions == 0)
    #expect(result.insertion == "Hello there")
}

@Test func continuingASentenceTypesOnlyWhatIsNew() {
    // The common case by a wide margin: the recogniser appends and revises
    // nothing, so nothing should be deleted.
    let result = edit("Hello there", "Hello there Roman")
    #expect(result.deletions == 0)
    #expect(result.insertion == " Roman")
}

@Test func aRevisedTailDeletesOnlyTheTail() {
    // "graph if I" becoming "graphify" — the recogniser changing its mind about
    // words it already gave us, which is why this cannot simply append.
    //
    // The agreement runs to "…to graph", so only " if I" is taken back and only
    // "ify" typed. Rewriting from the start of the changed *word* would look
    // tidier in this comment and cost five extra keystrokes in a document.
    let result = edit("Send it to graph if I", "Send it to graphify")
    #expect(result.deletions == 5)
    #expect(result.insertion == "ify")
}

@Test func nothingChangedMeansNothingIsTyped() {
    let result = edit("Hello there", "Hello there")
    #expect(result.deletions == 0)
    #expect(result.insertion.isEmpty)
}

@Test func aShorterResultDeletesTheDifferenceAndTypesNothing() {
    let result = edit("Hello there now", "Hello there")
    #expect(result.deletions == 4)
    #expect(result.insertion.isEmpty)
}

@Test func aChangeAtTheFirstCharacterRewritesEverything() {
    // Sentence casing arriving in the final pass. Real, and the reason partials
    // are cleaned before they are typed rather than after — this is the edit the
    // coordinator is arranging never to need.
    let result = edit("hello there", "Hello there")
    #expect(result.deletions == 11)
    #expect(result.insertion == "Hello there")
}

@Test func deletionsAreCountedInVisibleCharactersNotCodeUnits() {
    // "é" as e + combining accent is one grapheme and two UTF-16 units, and a
    // family emoji is one grapheme and eleven. Counting units here would send
    // extra backspaces into the user's document.
    let composed = "caf\u{0065}\u{0301}"           // café, decomposed
    #expect(edit(composed, "").deletions == 4)

    let family = "hi \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    #expect(edit(family, "hi ").deletions == 1)
}

@Test func aSharedPrefixEndingMidGraphemeIsNotSplit() {
    // Two different emoji that share a leading scalar. Comparing scalars would
    // report a common prefix inside the cluster and delete half of one.
    let result = edit("ok \u{1F468}\u{200D}\u{1F469}", "ok \u{1F468}\u{200D}\u{1F467}")
    #expect(result.deletions == 1)
    #expect(result.insertion == "\u{1F468}\u{200D}\u{1F467}")
}

@Test func theEditIsAlwaysSufficientToProduceTheTarget() {
    // The property that actually matters: applying (deletions, insertion) to the
    // current text must give exactly the target, for every pair.
    let samples = ["", "a", "Hello", "Hello there", "Hello there Roman",
                   "hello there", "Send it to Noah", "Send it to Carlo",
                   "caf\u{00E9}", "caf\u{0065}\u{0301}", "one. two. three."]
    for from in samples {
        for to in samples {
            let result = edit(from, to)
            #expect(result.deletions <= from.count, "never delete more than was typed")
            let applied = String(from.dropLast(result.deletions)) + result.insertion
            #expect(applied == to, "\"\(from)\" -> \"\(to)\" produced \"\(applied)\"")
        }
    }
}

// MARK: - Taking it back without eating the user's keystroke

private final class ScriptedKeystrokes: KeystrokeEmitting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var screen = ""
    private(set) var actions: [String] = []

    init(existing: String = "") { screen = existing }

    @discardableResult func type(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        screen += text
        actions.append("type(\(text))")
        return true
    }

    @discardableResult func backspace(times: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        screen = String(screen.dropLast(times))
        actions.append("backspace(\(times))")
        return true
    }
}

@MainActor
@Test func cancellingLeavesTheUsersOwnKeystrokeAndNoneOfOurs() {
    // The old signature was `retract(extraCharactersToLeave:)` and it did the
    // exact opposite of its name. Backspaces delete from the caret backwards and
    // the user's character is the LAST thing on screen, so deleting one fewer
    // than we typed removes THEIR character first and leaves one of OURS behind.
    // There is no number of backspaces that spares it — the only correct move is
    // to take everything back and put their character in again, which is why the
    // delegate now carries the character instead of a boolean.
    let keyboard = ScriptedKeystrokes()
    let typer = LiveTyper(keyboard: keyboard)
    typer.begin()
    typer.update(to: "send it over")
    #expect(keyboard.screen == "send it over")

    // The user presses "x" mid-hold. It is passed through, so it lands after our
    // text, and only then do we hear about the cancellation.
    keyboard.type("x")
    #expect(keyboard.screen == "send it overx")

    typer.retract(restoring: "x")
    #expect(keyboard.screen == "x", "left \(keyboard.screen.debugDescription) on screen")
}

@MainActor
@Test func escapeTakesBackEverythingAndAddsNothing() {
    // Escape is swallowed, so nothing of the user's is on screen and nothing is
    // owed back.
    let keyboard = ScriptedKeystrokes()
    let typer = LiveTyper(keyboard: keyboard)
    typer.begin()
    typer.update(to: "send it over")
    typer.retract()
    #expect(keyboard.screen == "")
}

@MainActor
@Test func aKeyThatInsertsNothingIsNotTreatedAsACharacter() {
    // An arrow key cancels the dictation and is passed through, but inserts no
    // text. Treating it as one character is how live typing deletes a character
    // of the user's own writing that was already there.
    let keyboard = ScriptedKeystrokes(existing: "already here ")
    let typer = LiveTyper(keyboard: keyboard)
    typer.begin()
    typer.update(to: "send it over")
    #expect(keyboard.screen == "already here send it over")
    typer.retract(restoring: "")
    #expect(keyboard.screen == "already here ", "ate the user's existing text")
}

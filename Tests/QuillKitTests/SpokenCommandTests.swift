import Foundation
import Testing
@testable import QuillKit

/// Roman dictates into Ghostty all day, because that is where Claude Code lives.
///
/// `AppContext.terminal` switched off sentence casing and the trailing full stop
/// on the reasoning that `Git status.` is not a command. Correct about commands,
/// and wrong about the place: **of 85 real dictations in his history, 85 were
/// English prose and 0 were shell commands**, and running the old rule over them
/// stripped the opening capital from 76 and the closing full stop from 71.
///
/// The sentences below are written for this test rather than taken from his
/// history — the measurement used the real thing, but his dictations are not
/// going in a public repository.
@Suite struct SpokenCommandTests {

    /// The expensive direction. A missing capital is invisible while you speak
    /// and arrives in front of whoever you are writing to; an unwanted one on a
    /// command is a single keystroke. Nothing in here may be called a command.
    @Test func prosePeopleActuallyDictateIntoATerminalIsNeverACommand() {
        let prose = [
            "Can you make the overlay bar sit on the left instead?",
            "That should do it, thanks.",
            "Also make a public GitHub repository so I can send people the link.",
            "I don't like it either.",
            "Open the settings screen and tell me what you see.",
            "Find the file I was talking about earlier.",
            "Cat that paragraph back to me so I can hear it.",
            "Make sure it still builds before you push anything.",
            "Go through it again and check the numbers.",
            "Clear up whatever is left over from the last run.",
            "Test it the way a person would actually use it.",
            "Export the whole thing as a single file.",
            "History shows I have done this three times now.",
            "Source the problem before you start changing things.",
        ]
        for line in prose {
            #expect(!SpokenCommand.looksLikeCommand(line), "called prose a command: \(line)")
        }
    }

    /// The cheap direction, and it still has to work. Every one of these opens
    /// with a real binary and has no sentence around it.
    @Test func thingsSomeoneWouldActuallySayToAShellAreCommands() {
        let commands = [
            "git status", "git add .", "git push", "npm run build", "npm install",
            "brew update", "cd projects", "ls", "clear", "swift build", "swift test",
            "docker ps", "git log", "git diff", "make clean", "python3 main.py",
            "rm -rf build", "grep -r todo", "chmod +x script.sh", "curl -O https://example.com",
        ]
        for line in commands {
            #expect(SpokenCommand.looksLikeCommand(line), "missed a command: \(line)")
        }
    }

    /// Shell syntax settles it wherever it appears — the recogniser does not
    /// invent a pipe or a `--flag`.
    @Test func shellSyntaxIsDecisiveOnItsOwn() {
        #expect(SpokenCommand.looksLikeCommand("deploy --force"))
        #expect(SpokenCommand.looksLikeCommand("./configure"))
        #expect(SpokenCommand.looksLikeCommand("cat log | grep error"))
        #expect(SpokenCommand.looksLikeCommand("ls ~/Documents"))
    }

    /// The same opening word, one of each. This is the pair the whole design is
    /// for: the window cannot tell them apart and the words can.
    @Test func theSameBinaryOpensBothACommandAndASentence() {
        #expect(SpokenCommand.looksLikeCommand("open index.html"))
        #expect(!SpokenCommand.looksLikeCommand("Open the door for me when you can."))
        #expect(SpokenCommand.looksLikeCommand("find build"))
        #expect(!SpokenCommand.looksLikeCommand("Find out whether that is even true."))
    }

    // MARK: - What the formatter does with the answer

    @Test func aSentenceDictatedIntoATerminalKeepsItsCapitalAndItsFullStop() {
        let sentence = "That should do it."
        #expect(AppContextFormatter.apply(sentence, context: .terminal) == sentence)
    }

    @Test func aCommandDictatedIntoATerminalStillLosesBoth() {
        // `Git status.` is not a command, and this is the case the old rule was
        // built for. It has to keep working.
        #expect(AppContextFormatter.apply("Git status.", context: .terminal) == "git status")
        #expect(AppContextFormatter.apply("Npm run build.", context: .terminal) == "npm run build")
    }

    /// A search field is not a terminal. "melbourne weather" wants no full stop
    /// whatever it looks like, so that context is unchanged.
    @Test func aSearchFieldIsUnaffectedByAnyOfThis() {
        #expect(!AppContext.query.capitalisesSentences(for: "That should do it."))
        #expect(!AppContext.query.keepsTrailingFullStop(for: "That should do it."))
    }
}

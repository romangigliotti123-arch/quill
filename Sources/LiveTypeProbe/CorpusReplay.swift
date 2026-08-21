// Does the faster cleaner still say the same thing?
//
// The vocabulary corrector is the piece that earned 2.81% WER over two identical
// 50-clip runs, and every guard in it was put there by a specific failure that
// damaged real text. Making it ten times faster is worth nothing if it changes
// one of those answers, and "the tests pass" only covers the cases someone
// thought to write down.
//
// So this replays every transcript the rig has ever recorded — the recogniser's
// raw output, before any cleaning — through cleanFast and prints one line per
// clip. Run it on the old build and the new one and diff the two files. Any
// difference at all is a regression until proven otherwise.
//
// Run: LiveTypeProbe --replay <file-with-one-raw-transcript-per-line>

import Foundation
import QuillKit

/// The same sentences through the path a real dictation takes — cleanFast, then
/// the context formatter carrying the chosen number style — rather than through
/// a step in isolation. A step that passes its own unit test and never runs in
/// this order would be a test of nothing.
enum FullPathDemo {
    static func run() {
        let cleaner = FastCleaner()
        let cases: [(String, AppContext)] = [
            ("send it to roman gigliotti 123 at gmail dot com", .prose),
            ("my email is roman gigliotti at gmail dot com", .prose),
            ("email me at roman dot gigliotti at outlook dot com", .prose),
            ("send the invoice to noah at kass barbers dot com dot au", .prose),
            ("Can you generate best notes and send it to the Gmail Grace Kingston 20 at gmail.com?", .prose),
            ("for example if I say Roman Gigliotti, 123, at gmail.com it should work", .prose),
            ("meet me at the shop at four", .prose),
            ("I'll look at gmail.com later", .prose),
            ("you will find me continually speaking of 4 men", .prose),
            ("give me 5 minutes", .prose),
            ("On 6 April 1830 the church was organised", .prose),
            ("she is 5 years old and I'm 15", .prose),
            ("we cut version 2.0 last night at 5:30", .prose),
            ("run it 3 times", .terminal),
        ]

        for style in [QuillSettings.Values.NumberStyle.spellOutSmall, .alwaysDigits, .alwaysWords] {
            print("")
            print("=== \(style.label) ===")
            for (raw, context) in cases {
                let out = AppContextFormatter.apply(cleaner.cleanFast(raw),
                                                    context: context,
                                                    numbers: style)
                let tag = context == .prose ? "" : "  [\(context.rawValue)]"
                print("  said  \(raw)\(tag)")
                print("  got   \(out)")
                print("")
            }
        }
    }
}

enum CorpusReplay {
    static func run(path: String) {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let lines = data.split(separator: "\n").map(String.init)

        // A fresh corrector per line as well as a shared one: the shared one is
        // how the app uses it (built once, used for every dictation), and the
        // fresh one is the answer nothing could have cached. They must agree.
        let shared = FastCleaner()
        var disagreements = 0

        for line in lines {
            let raw = line.replacingOccurrences(of: "\\n", with: " ")
            let warm = shared.cleanFast(raw)
            let cold = FastCleaner().cleanFast(raw)
            if warm != cold {
                disagreements += 1
                FileHandle.standardError.write(
                    "WARM/COLD DISAGREE\n  warm: \(warm)\n  cold: \(cold)\n".data(using: .utf8)!)
            }
            print(warm)
        }

        FileHandle.standardError.write(
            "replayed \(lines.count) transcripts, \(disagreements) warm/cold disagreements\n"
                .data(using: .utf8)!)
    }
}

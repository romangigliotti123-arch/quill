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

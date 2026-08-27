// What does the WHOLE cleanup chain do to a real sentence — not just cleanFast?
//
// `--replay` answers for the deterministic pass only. But a dictation goes
// through more than that: `SelfCorrection.resolve` runs on every single
// dictation, offline, before any gate is consulted, and it can DELETE text.
//
// This exists because of one record in Roman's own history, 24 Aug:
//
//   said:     "... They don't look realistic. I want the photos of the clothes
//              to actually look realistic. Not just like cartoons. ..."
//   inserted: "... They don't look realistic. Not just like cartoons. ..."
//
// A whole sentence, eleven words, gone — and `cleanFast` alone does not do it.
// Attributing that to the model pass by reading `usedThoroughCleanup: true` in
// history is a guess, because that flag is also set when the offline resolver
// changed the text and no request was ever sent. So this prints each stage
// separately and lets the answer come from the code rather than the flag.
//
// Run: LiveTypeProbe --stages <file-with-one-raw-transcript-per-line>

import Foundation
import QuillKit

enum ThoroughProbe {
    static func run(path: String) {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let cleaner = FastCleaner()
        let vocabulary = VocabularyBook.shared.terms

        var changedByResolver = 0
        var linesSeen = 0

        for line in data.split(separator: "\n").map(String.init) {
            let raw = line.replacingOccurrences(of: "\\n", with: " ")
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            linesSeen += 1

            let tidy = cleaner.cleanFast(raw)
            let resolved = SelfCorrection.resolve(tidy, protecting: vocabulary)

            // What actually lands in Ghostty, which is where he dictates most:
            // the resolver's answer if it had one, then the context formatter.
            // Checking cleanFast alone would be measuring a path no dictation
            // takes.
            let shipped = AppContextFormatter.apply(resolved ?? tidy,
                                                    context: .terminal,
                                                    numbers: .spellOutSmall)
            if shipped != (resolved ?? tidy) {
                print("~~~ line \(linesSeen): formatter changed it")
                print("  PRE : \(resolved ?? tidy)")
                print("  SHIP: \(shipped)")
                print("")
            }

            guard let resolved, resolved != tidy else { continue }
            changedByResolver += 1

            // Words present in the input and absent from the output. Word count
            // rather than a diff because the question is only ever "did the
            // speaker lose something they said".
            let before = tidy.split(whereSeparator: \.isWhitespace).count
            let after = resolved.split(whereSeparator: \.isWhitespace).count

            print("--- line \(linesSeen): resolver removed \(before - after) word(s)")
            print("  IN : \(tidy)")
            print("  OUT: \(resolved)")
            print("")
        }

        FileHandle.standardError.write(
            "\(linesSeen) transcripts, offline resolver changed \(changedByResolver)\n"
                .data(using: .utf8)!)
    }
}

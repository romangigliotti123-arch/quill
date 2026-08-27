// What does the app actually see in a style.json, and can it survive it?
//
// Roman's real file on 27 Aug 2026 carried counters of 4611686018427387904 —
// exactly 2^62 — in three separate places, and a sentenceLength total of
// 3.23e19, which is larger than Int64 can hold. The ratio survived: total/count
// is exactly 7.0 words per sentence, so both numbers were scaled by the same
// factor rather than corrupted independently.
//
// That shape matters. Counters that grow by DOUBLING land on a clean power of
// two; counters that grow by counting do not. So the question this answers is
// not "what is the number" but "what does the app do when it reads it" — does
// it decode, does the Style screen render it, and is the next increment the one
// that overflows and takes the process with it.
//
// Read-only. It is handed a path and never writes: this is somebody's real
// profile, and a probe that repairs what it is measuring has destroyed the
// evidence.
//
// Run: LiveTypeProbe --style <path/to/style.json>

import Foundation
import QuillKit

enum StyleProbe {
    static func run(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            FileHandle.standardError.write("cannot read \(url.path)\n".data(using: .utf8)!)
            exit(2)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let profile: StyleProfile
        do {
            profile = try decoder.decode(StyleProfile.self, from: data)
            print("decode            : OK")
        } catch {
            print("decode            : FAILED — \(error)")
            print("  the store falls back to freshDefault and refuses to write,")
            print("  so the profile reads as a factory reset rather than a loss.")
            return
        }

        print("correctionCount   : \(profile.correctionCount)")
        print("  as a power of two: \(powerOfTwo(profile.correctionCount).map(String.init) ?? "not one")")
        print("sentenceLength    : total \(profile.sentenceLength.total), count \(profile.sentenceLength.count)")
        print("  average         : \(profile.sentenceLength.average.map { String($0) } ?? "nil")")
        print("phrasings         : \(profile.phrasings.count)")
        for p in profile.phrasings {
            print("   \"\(p.from)\" -> \"\(p.to)\"  count \(p.count)")
        }

        // The two things a corrupt counter actually reaches.
        print("summary line      : \(profile.summaryLine)")
        let rules = profile.promptRules()
        print("prompt rules      : \(rules.isEmpty ? "none" : "")")
        for r in rules { print("   \(r)") }

        // The one that ends the process. Swift's + traps on overflow rather than
        // wrapping, so this is a crash and not a wrong number.
        let headroom = Int.max - profile.correctionCount
        print("headroom to Int.max: \(headroom)")
        if profile.correctionCount > 0, headroom < profile.correctionCount {
            print("!! the next merge of this profile with itself OVERFLOWS and traps")
        }
    }

    private static func powerOfTwo(_ n: Int) -> Int? {
        guard n > 0, n & (n - 1) == 0 else { return nil }
        return n.trailingZeroBitCount
    }
}

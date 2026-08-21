// Why does the model only run on 3% of his dictations?
//
// Roman's goal, in his words: "have some sort of model connected so that even if
// I murmur something or speak fast or say 'do this actually do this' it all gets
// picked up without me having to edit it after."
//
// The model is connected. It just almost never runs. Across 736 of his own
// dictations, `usedThoroughCleanup` is true on 25 of them. Three reasons are
// possible and they need very different fixes:
//
//   1. the GATE never fires — `needsModelPass` does not recognise his phrasing
//   2. the gate fires but the DEADLINE expires before the answer lands
//   3. the gate fires and the model returns nothing better
//
// This measures the first one directly, offline, over every real dictation on
// this machine. It is the only one of the three that can be measured without the
// network, and it is the cheapest to fix if it is the answer.
//
// Run: LiveTypeProbe --gate <transcripts.txt>

import Foundation
import QuillKit

enum GateProbe {

    /// The things he actually says when he changes his mind mid-sentence,
    /// counted from his own history rather than imagined.
    static let cues = [
        "actually", "no wait", "sorry", "scratch that", "i mean", "rather",
        "instead", "make that", "or rather", "hang on", "no,",
    ]

    static func run(path: String) {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let lines = data.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let cleaner = FastCleaner()

        var gateFired = 0
        var hasCue = 0
        var cueButNoGate: [String] = []
        var gateButNoCue = 0
        var offlineResolved = 0

        for line in lines {
            let tidy = cleaner.cleanFast(line)
            let fires = SelfCorrection.needsModelPass(tidy)
            let cue = cues.contains { tidy.lowercased().contains($0) }
            if fires { gateFired += 1 }
            if cue { hasCue += 1 }
            if cue && !fires, cueButNoGate.count < 14 { cueButNoGate.append(tidy) }
            if fires && !cue { gateButNoCue += 1 }
            // What the deterministic resolver already does without any model.
            if let resolved = SelfCorrection.resolve(tidy, protecting: []), resolved != tidy {
                offlineResolved += 1
            }
        }

        let n = lines.count
        print("")
        print("=== the model-pass gate, over \(n) of his real dictations ===")
        print("")
        print(String(format: "  gate fires (needsModelPass)     %4d  (%d%%)", gateFired, gateFired * 100 / n))
        print(String(format: "  contains a self-correction cue  %4d  (%d%%)", hasCue, hasCue * 100 / n))
        print(String(format: "  gate fires with no cue          %4d", gateButNoCue))
        print(String(format: "  resolved offline, no model      %4d  (%d%%)", offlineResolved, offlineResolved * 100 / n))
        print("")
        print("sentences with a cue the gate does NOT catch:")
        if cueButNoGate.isEmpty {
            print("   (none — the gate sees every cue)")
        }
        for s in cueButNoGate {
            print("   \(s.prefix(120))")
        }
    }
}

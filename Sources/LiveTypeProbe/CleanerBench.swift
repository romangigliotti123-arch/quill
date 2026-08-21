// Which part of cleanFast costs the 272ms?
//
// The live-typing probe showed cleanFast dominating the main thread and scaling
// with transcript length. "The cleaner is slow" is not something anyone can act
// on, so this splits it: the whole pass, and the vocabulary pass alone, at
// growing lengths. Both are public API, so this measures the shipping release
// build rather than a debug one.
//
// Run: LiveTypeProbe --bench

import Foundation
import QuillKit

enum CleanerBench {

    /// Real prose, so the vocabulary matcher sees the token shapes it would see
    /// in a dictation rather than a repeated word it can reject in one compare.
    static let sample = """
    To fade away like morning beauty from her mortal day down by the river of \
    Adona her soft voice is heard and thus her gentle lamentation falls like \
    morning dew O life of this our spring why fades the lotus of the water why \
    fade these children of the spring born but to smile and fall Ah Thel is like \
    a watry bow and like a parting cloud like a reflection in a glass like \
    shadows in the water like dreams of infants like a smile upon an infants face
    """

    static func text(ofLength n: Int) -> String {
        var out = ""
        while out.count < n { out += sample + " " }
        return String(out.prefix(n))
    }

    /// Median of `runs` so one scheduling hiccup does not become the finding.
    static func timeMs(runs: Int = 5, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let t0 = ProcessInfo.processInfo.systemUptime
            body()
            samples.append((ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }
        return samples.sorted()[samples.count / 2]
    }

    static func run() {
        let cleaner = FastCleaner()
        let vocabulary = VocabularyCorrector()

        // Warm anything lazy (the vocabulary file, the spell checker's first
        // connection) so the first row is not measuring startup.
        _ = cleaner.cleanFast(text(ofLength: 200))

        print("")
        print("=== cleanFast cost by transcript length (release build, median of 5) ===")
        print("")
        print("   chars   cleanFast   vocabulary   everything else   per char")
        print("   -----   ---------   ----------   ---------------   --------")

        var previous: (n: Int, ms: Double)?
        for n in [50, 100, 200, 400, 800, 1600] {
            let t = text(ofLength: n)
            let total = timeMs { _ = cleaner.cleanFast(t) }
            let vocab = timeMs { _ = vocabulary.correct(t) }
            let rest = max(0, total - vocab)
            print(String(format: "   %5d   %7.1f ms   %7.1f ms   %11.1f ms   %6.2f ms",
                         n, total, vocab, rest, total / Double(n)))
            if let p = previous {
                let lengthFactor = Double(n) / Double(p.n)
                let costFactor = total / max(0.001, p.ms)
                print(String(format: "           %.0fx the text -> %.1fx the cost", lengthFactor, costFactor))
            }
            previous = (n, total)
        }

        print("")
        print("Live typing runs this on every applied partial, against the whole")
        print("transcript so far — so a dictation of N characters pays it ~N/20")
        print("times with a growing argument.")
    }
}

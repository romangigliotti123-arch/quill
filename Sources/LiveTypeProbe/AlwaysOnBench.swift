// If the model ran on EVERY dictation, would Roman trust the result?
//
// His goal, in his words: "even if I murmur something or speak fast or say 'do
// this actually do this' it all gets picked up without me having to edit it
// after... accurate enough for me to just speak, trust what it said, and click
// send."
//
// The cleanup pass exists, is delete-only, and is enforced in code by
// CleanupProjection. It almost never runs, because the gate was built to protect
// a 250ms latency budget — and he has just said he would rather wait than edit.
// So the gate is a latency decision, and he has made it.
//
// What is NOT settled is whether always-on cleanup improves his text or damages
// it. That cannot be reasoned about; every previous guess in this codebase about
// what a model would do to his prose was wrong in one direction or the other. So
// this runs the real prompt against the real endpoint over his OWN dictations and
// prints every single change for reading.
//
// Deliberately prints changes rather than scoring them. There is no ground truth
// for what he meant — he is the only one who knows — so the output is evidence to
// read, not a number to optimise.
//
// Run: LiveTypeProbe --alwayson <his-speech.txt> [limit]

import Foundation
import QuillKit

enum AlwaysOnBench {

    static func run(path: String, limit: Int) async {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        let client = NIMClient()
        guard client.isConfigured else {
            print("no NIM key configured; nothing to measure")
            return
        }

        let cleaner = FastCleaner()
        // The client is injected so the breaker can be reset between calls. Two
        // 429s latch it open for a minute, which is exactly right in the app —
        // Roman should not pay a deadline per dictation while NVIDIA refuses —
        // and exactly wrong here, where it turns one rate limit into a whole run
        // of silent nils that read as "the model had nothing to say".
        let lines = data.split(separator: "\n").map(String.init)
            .filter { $0.split(separator: " ").count >= 6 }

        // Longest first: a one-line "On my way." has nothing to clean, and the
        // question is about the dictations he would actually hesitate to send.
        let sample = Array(lines.sorted { $0.count > $1.count }.prefix(limit))
        print("=== word repair on \(sample.count) of his own dictations ===")
        print("")

        var changed = 0, unchanged = 0, failed = 0
        var refused = 0, noCall = 0, refusalsShown = 0
        var latencies: [Double] = []

        for (index, raw) in sample.enumerated() {
            let fast = cleaner.cleanFast(raw)
            client.resetBreaker()
            let t0 = ProcessInfo.processInfo.systemUptime
            // A deliberately generous deadline. The question here is what the
            // model DOES, not whether it lands in 450ms — that is already
            // measured at 97%.
            // NOT cleanThorough: that applies the gate internally, so 38 of 40
            // sentences returned in 15ms having never reached the model, and the
            // run measured the gate rather than the pass. This is the pass with
            // the gate removed, which is the actual question.
            var out: String? = nil
            var rawAnswer: String? = nil
            if let completion = try? await client.complete(
                system: ContextPrompt.current.system, user: fast,
                model: nil, deadline: .milliseconds(4000)
            ) {
                rawAnswer = completion
                out = ContextProjection.project(completion, onto: fast)
            }
            let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            latencies.append(ms)

            guard let out else {
                // Separate the two very different reasons for nil. A failed call
                // is a network problem; a refused answer is the delete-only
                // contract doing its job, and the two need opposite fixes.
                failed += 1
                if let rawAnswer {
                    refused += 1
                    if refusalsShown < 6 {
                        refusalsShown += 1
                        print("--- \(index + 1) REFUSED (\(Int(ms))ms)")
                        print("  in   \(fast.prefix(220))")
                        print("  out  \(rawAnswer.prefix(220))")
                        print("")
                    }
                } else {
                    noCall += 1
                }
                try? await Task.sleep(for: .milliseconds(2500))
                continue
            }
            if out == fast {
                unchanged += 1
                try? await Task.sleep(for: .milliseconds(1200))
                continue
            }
            changed += 1
            print("--- \(index + 1) — \(Int(ms))ms")
            print("  was  \(fast)")
            print("  now  \(out)")
            print("")

            // Pace it. Six suite runs in an hour already tripped this endpoint's
            // rate limit once today, and a throttled run reads as "the model
            // stopped helping" rather than as an error.
            try? await Task.sleep(for: .milliseconds(1200))
        }

        latencies.sort()
        print("=== summary ===")
        print("  changed      \(changed)")
        print("  unchanged    \(unchanged)")
        print("  no answer    \(failed)  — refused by the projection \(refused), call failed \(noCall)")
        if !latencies.isEmpty {
            print(String(format: "  latency      p50 %.0fms  p90 %.0fms  worst %.0fms",
                         latencies[latencies.count / 2],
                         latencies[Int(Double(latencies.count) * 0.9)],
                         latencies.last!))
        }
        print("")
        print("Read every change above. The question is not how many it made,")
        print("it is whether a single one of them is something he did not say.")
    }
}

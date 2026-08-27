// Why does a long dictation fall behind, judder, and keep listening after the
// key is up?
//
// Roman's report, verbatim: read a paragraph for ~30 seconds and the text keeps
// appearing for ~30 seconds after you stop, the waveform bar freezes, and the
// key release does not end capture until all the text has landed.
//
// Those are three symptoms. This asks whether they are one cause.
//
// Everything in Quill that touches the screen funnels through the main queue:
// SpeechAnalyzerTranscriber.emit does DispatchQueue.main.async per partial,
// publish(level:) does one per audio buffer, and HotkeyEngine.deliver does one
// for the key release — deliberately, so press and release keep their order.
// LiveTyper is @MainActor, so its keystrokes are posted from that same queue,
// and SyntheticKeyboard sleeps the calling thread between every event
// (usleep(700) per backspace, usleep(1500) per 16-unit chunk of typing).
//
// So the question is arithmetic: does one dictation's worth of live-typing cost
// more main-thread time than the dictation takes to speak? If it does, the queue
// can never drain, and the release — sitting behind every partial ahead of it —
// is serviced only once the typing is finished. Which is exactly what he sees.
//
// This runs the real transcriber over a real 35s recording at 1x, and for every
// partial runs the real FastCleaner, the real AppContextFormatter and the real
// LiveTyper.edit. The keystrokes are not posted (nothing should be typed into
// whatever is frontmost while this runs) but their cost is paid for real, on the
// main queue, with the same usleep constants the shipping emitter uses. A
// heartbeat scheduled on that queue every 50ms measures how late it actually
// runs, which is the waveform's judder and the release's delay in one number.

import AVFoundation
import AppKit
import Foundation
import QuillKit

// MARK: - The cost model, taken from SyntheticKeyboard

/// Microseconds SyntheticKeyboard.backspace sleeps per character.
let backspaceGapUs: UInt32 = 700
/// Microseconds SyntheticKeyboard.type sleeps per chunk.
let typeGapUs: UInt32 = 1_500
/// UTF-16 units per typed chunk.
let chunkLimit = 16

/// What one edit costs the main thread, in microseconds, if it were posted.
func keystrokeCostUs(deletions: Int, insertion: String) -> Int {
    let chunks = SyntheticKeyboard.chunks(of: insertion, limit: chunkLimit).count
    return deletions * Int(backspaceGapUs) + chunks * Int(typeGapUs)
}

// MARK: - Recording

struct Applied {
    let index: Int
    let atAudioSecond: Double
    let textLength: Int
    let deletions: Int
    let insertionLength: Int
    let cleanMs: Double
    let keystrokeMs: Double
    /// Kept so a catastrophic edit can be shown rather than inferred: what was
    /// believed on screen, what it had to become, and where they first diverge.
    let before: String
    let after: String
    /// Raw recogniser text before the cleaner touched it, and the previous raw.
    let rawBefore: String
    let rawAfter: String
}

final class Recorder: @unchecked Sendable {
    var applied: [Applied] = []
    var partialsSeen = 0
    var partialsThrottled = 0
    /// Heartbeat lateness samples, milliseconds.
    var lateness: [Double] = []
    var started = ProcessInfo.processInfo.systemUptime
    /// When the last audio buffer was delivered — the moment "he stopped talking".
    var audioEnded: Double?
    /// When a block enqueued at audioEnded actually ran — the moment the release
    /// handler would have been serviced.
    var releaseServiced: Double?
    var finalText = ""
}

let rec = Recorder()

// MARK: - The live-typing loop, faithful to LiveTyper

/// LiveTyper.minimumInterval, the throttle that limits screen updates.
let minimumInterval: TimeInterval = 0.066

let cleaner = FastCleaner()
var typed = ""
var lastRaw = ""
var lastUpdate: TimeInterval = 0
var partialIndex = 0

/// Runs on the main queue, exactly as LiveTyper.update -> apply does.
@MainActor
func liveUpdate(_ raw: String) {
    rec.partialsSeen += 1
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastUpdate >= minimumInterval else {
        rec.partialsThrottled += 1
        return
    }

    // The real per-partial work the coordinator does before touching the typer.
    let t0 = ProcessInfo.processInfo.systemUptime
    let cleaned = AppContextFormatter.apply(cleaner.cleanFast(raw), context: .prose)
    let cleanMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000

    let edit = LiveTyper.edit(from: typed, to: cleaned)
    guard edit.deletions > 0 || !edit.insertion.isEmpty else {
        lastUpdate = ProcessInfo.processInfo.systemUptime
        return
    }

    // Pay what the keystrokes would cost, on this thread, as the real emitter does.
    let costUs = keystrokeCostUs(deletions: edit.deletions, insertion: edit.insertion)
    if costUs > 0 { usleep(useconds_t(costUs)) }

    partialIndex += 1
    rec.applied.append(Applied(
        index: partialIndex,
        atAudioSecond: now - rec.started,
        textLength: cleaned.count,
        deletions: edit.deletions,
        insertionLength: edit.insertion.count,
        cleanMs: cleanMs,
        keystrokeMs: Double(costUs) / 1000,
        before: typed,
        after: cleaned,
        rawBefore: lastRaw,
        rawAfter: raw
    ))

    lastRaw = raw
    typed = cleaned
    rec.finalText = cleaned
    lastUpdate = ProcessInfo.processInfo.systemUptime
}

// MARK: - Delegate

final class ProbeDelegate: TranscriberDelegate, @unchecked Sendable {
    // TranscriberDelegate is @MainActor, so the conformance would isolate this
    // initialiser too; top-level code in main.swift is not isolated.
    nonisolated init() {}
    func transcriber(didProduce transcript: Transcript) {
        MainActor.assumeIsolated { liveUpdate(transcript.text) }
    }
    func transcriber(didFail error: Error) {
        FileHandle.standardError.write("FAILED: \(error)\n".data(using: .utf8)!)
    }
}

// MARK: - Heartbeat

/// Enqueues itself on the main queue every 50ms and records how late it ran.
/// This is the waveform's frame budget and the release handler's queue position,
/// measured directly rather than inferred.
@MainActor
func heartbeat() {
    let due = ProcessInfo.processInfo.systemUptime + 0.050
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.050) {
        MainActor.assumeIsolated {
            let late = (ProcessInfo.processInfo.systemUptime - due) * 1000
            rec.lateness.append(max(0, late))
            heartbeat()
        }
    }
}

// MARK: - Run

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--alternatives"), i + 1 < args.count {
    let target = URL(fileURLWithPath: args[i + 1])
    let finished = DispatchSemaphore(value: 0)
    Task { await AlternativesProbe.run(url: target); finished.signal() }
    while finished.wait(timeout: .now() + 0.01) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--alwayson"), i + 1 < args.count {
    let target = args[i + 1]
    let cap = (i + 2 < args.count ? Int(args[i + 2]) : nil) ?? 40
    let finished = DispatchSemaphore(value: 0)
    Task { await AlwaysOnBench.run(path: target, limit: cap); finished.signal() }
    while finished.wait(timeout: .now() + 0.01) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    exit(0)
}
if let i = args.firstIndex(of: "--gate"), i + 1 < args.count {
    GateProbe.run(path: args[i + 1])
    exit(0)
}
if args.contains("--demo") {
    FullPathDemo.run()
    exit(0)
}
if args.contains("--bench") {
    CleanerBench.run()
    exit(0)
}
if let i = args.firstIndex(of: "--replay"), i + 1 < args.count {
    CorpusReplay.run(path: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--stages"), i + 1 < args.count {
    ThoroughProbe.run(path: args[i + 1])
    exit(0)
}
if let i = args.firstIndex(of: "--style"), i + 1 < args.count {
    StyleProbe.run(path: args[i + 1])
    exit(0)
}
guard args.count > 1 else {
    print("usage: livetypeprobe <audio.wav> | --bench")
    exit(2)
}
let url = URL(fileURLWithPath: args[1])

let source = AudioFileSource(url: url, realtime: true, chunkDuration: 0.1)
let transcriber = SpeechAnalyzerTranscriber(audio: source)
let delegate = ProbeDelegate()
transcriber.delegate = delegate

// The level callback the coordinator installs, hop and all. Its only job here is
// to occupy the main queue the same way the real one does.
nonisolated(unsafe) var levelCallbacks = 0
transcriber.onLevel = { _ in
    DispatchQueue.main.async { levelCallbacks += 1 }
}

let done = DispatchSemaphore(value: 0)

source.onEnded = {
    let ended = ProcessInfo.processInfo.systemUptime
    rec.audioEnded = ended
    // Stand in for HotkeyEngine.deliver(hotkeyReleased): the tap sees the key up
    // on its own thread and hops to main. How long until it is serviced is the
    // whole of symptom three.
    DispatchQueue.main.async {
        rec.releaseServiced = ProcessInfo.processInfo.systemUptime
        done.signal()
    }
}

Task { @MainActor in
    heartbeat()
    await transcriber.prepare()
    rec.started = ProcessInfo.processInfo.systemUptime
    do { try await transcriber.start() } catch {
        print("start failed: \(error)")
        exit(1)
    }
}

// The probe is a CLI, so it has to spin the main run loop itself for
// DispatchQueue.main to run at all.
let deadline = Date().addingTimeInterval(180)
while done.wait(timeout: .now() + 0.01) == .timedOut, Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
}

// Let the tail of the stream land.
let tailEnd = Date().addingTimeInterval(4)
while Date() < tailEnd {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

// MARK: - Report

let audioDuration = source.duration
let totalClean = rec.applied.reduce(0) { $0 + $1.cleanMs }
let totalKeys = rec.applied.reduce(0) { $0 + $1.keystrokeMs }
let totalDeletions = rec.applied.reduce(0) { $0 + $1.deletions }
let totalInserted = rec.applied.reduce(0) { $0 + $1.insertionLength }
let busy = totalClean + totalKeys

print("")
print("=== live typing cost over one long dictation ===")
print(String(format: "audio                     %.1f s", audioDuration))
print("partials delivered        \(rec.partialsSeen)")
print("  throttled away          \(rec.partialsThrottled)")
print("  applied                 \(rec.applied.count)")
print("final text length         \(rec.finalText.count) chars")
print("")
print("keystrokes that would be posted")
print("  backspaces              \(totalDeletions)")
print("  characters typed        \(totalInserted)")
print(String(format: "  ratio to final text     %.1fx", Double(totalInserted) / Double(max(1, rec.finalText.count))))
print("")
print("main-thread time consumed")
print(String(format: "  cleanFast + format      %.0f ms", totalClean))
print(String(format: "  keystroke sleeps        %.0f ms", totalKeys))
print(String(format: "  TOTAL                   %.0f ms  (%.0f%% of the %.0fs spoken)",
             busy, busy / (audioDuration * 1000) * 100, audioDuration))
print("")
if let a = rec.audioEnded, let r = rec.releaseServiced {
    print(String(format: "release handler serviced  %.0f ms after the audio stopped", (r - a) * 1000))
}
if !rec.lateness.isEmpty {
    let sorted = rec.lateness.sorted()
    let mean = rec.lateness.reduce(0, +) / Double(rec.lateness.count)
    print(String(format: "main-queue lateness       mean %.0f ms, p95 %.0f ms, worst %.0f ms  (%d samples)",
                 mean, sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, sorted.count))
    let stalled = rec.lateness.filter { $0 > 100 }.count
    print("  heartbeats over 100ms   \(stalled)")
}
print("")
print("worst single updates (deletions -> insertion):")
for a in rec.applied.sorted(by: { $0.keystrokeMs > $1.keystrokeMs }).prefix(8) {
    print(String(format: "  t=%5.1fs  del %4d  ins %4d  clean %5.1f ms  keys %6.1f ms  (text %d)",
                 a.atAudioSecond, a.deletions, a.insertionLength, a.cleanMs, a.keystrokeMs, a.textLength))
}

// MARK: - Why the big rewrites happen, and what a better diff would cost

/// Prefix AND suffix, which is what the shipping diff is missing. Returns the
/// span that actually differs.
func prefixSuffixEdit(from current: String, to target: String) -> (deletions: Int, insertion: String) {
    let c = Array(current), t = Array(target)
    var head = 0
    while head < c.count, head < t.count, c[head] == t[head] { head += 1 }
    var tail = 0
    while tail < c.count - head, tail < t.count - head, c[c.count - 1 - tail] == t[t.count - 1 - tail] {
        tail += 1
    }
    // Deleting from the caret backwards means everything after the divergence
    // still has to go; the win is only real if the edit is at the very end.
    return (c.count - head - tail, String(t[head..<(t.count - tail)]))
}

print("")
print("=== the catastrophic rewrites, in full ===")
for a in rec.applied.sorted(by: { $0.deletions > $1.deletions }).prefix(3) {
    print("")
    print(String(format: "t=%.1fs — deleted %d of %d characters and retyped %d",
                 a.atAudioSecond, a.deletions, a.before.count, a.insertionLength))
    let common = LiveTyper.edit(from: a.before, to: a.after)
    let divergeAt = a.before.count - common.deletions
    let ctxStart = max(0, divergeAt - 30)
    let b = Array(a.before), af = Array(a.after)
    print("  diverges at character \(divergeAt) of \(a.before.count)")
    print("  before …\(String(b[ctxStart..<min(b.count, divergeAt + 40)]))…")
    print("  after  …\(String(af[ctxStart..<min(af.count, divergeAt + 40)]))…")
    // Was it the recogniser revising, or the cleaner re-rendering settled text?
    let rawEdit = LiveTyper.edit(from: a.rawBefore, to: a.rawAfter)
    print("  recogniser's own raw revision: \(rawEdit.deletions) deletions")
    print("  so \(a.deletions - rawEdit.deletions) of the deletions were added by the cleaner/formatter")
}

let betterTotal = rec.applied.reduce(into: (del: 0, ins: 0)) { acc, a in
    let e = prefixSuffixEdit(from: a.before, to: a.after)
    acc.del += e.deletions
    acc.ins += e.insertion.count
}
print("")
print("=== what a prefix+suffix diff would have cost ===")
print("  backspaces              \(betterTotal.del)  (was \(totalDeletions))")
print("  characters typed        \(betterTotal.ins)  (was \(totalInserted))")
exit(0)

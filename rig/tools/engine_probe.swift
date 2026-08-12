// Does DictationTranscriber emit its first hypothesis sooner than
// SpeechTranscriber?
//
// SpeechTranscriber holds a fixed ~1.02s of audio before saying anything —
// measured at 1027/1024/1027/1022/1025/1026ms across six clips with the leading
// silence trimmed off, a 5ms spread that can only be an internal window. That is
// ~85% of Quill's time-to-first-word, so it is the only part of that number
// worth attacking.
//
// DictationTranscriber is the SDK's other module, with a `shortForm` content
// hint and `progressiveShortDictation` preset — built for exactly the push-to-
// talk case, where SpeechTranscriber is built for long-form transcription. This
// feeds both the same file at 1x and prints when each first speaks.
//
// Standalone on purpose: measuring this by integrating it into the app would
// mean a refactor (the two modules have different Result types) before knowing
// whether there is anything to win.

import AVFoundation
import Foundation
import Speech

nonisolated(unsafe) var url = URL(fileURLWithPath: "/dev/null")

/// Feeds a file at 1x in 100ms chunks, the same pacing a microphone gives.
func feed(_ continuation: AsyncStream<AnalyzerInput>.Continuation,
          format: AVAudioFormat) async throws {
    let file = try AVAudioFile(forReading: url)
    let source = file.processingFormat
    let converter = AVAudioConverter(from: source, to: format)
    let chunk = AVAudioFrameCount(source.sampleRate * 0.1)
    let started = Date()
    var index = 0

    while true {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { break }
        // AVAudioFile throws eofErr at the end rather than returning 0 frames.
        do { try file.read(into: buffer, frameCount: chunk) } catch { break }
        if buffer.frameLength == 0 { break }

        var out = buffer
        if let converter, source != format {
            let ratio = format.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error != nil { break }
            out = converted
        }
        continuation.yield(AnalyzerInput(buffer: out))

        index += 1
        let due = started.addingTimeInterval(Double(index) * 0.1)
        let remaining = due.timeIntervalSinceNow
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }
    continuation.finish()
}

func runSpeechTranscriber() async throws -> (first: Double?, text: String) {
    var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_AU"))
    if resolved == nil {
        resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }
    guard let locale = resolved else { return (nil, "<no locale>") }
    let module = SpeechTranscriber(locale: locale,
                                   transcriptionOptions: [],
                                   reportingOptions: [.volatileResults, .fastResults],
                                   attributeOptions: [])
    let analyzer = SpeechAnalyzer(modules: [module])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
        return (nil, "<no format>")
    }
    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let start = Date()
    var first: Double?
    var text = ""

    let reader = Task {
        for try await result in module.results {
            if first == nil { first = Date().timeIntervalSince(start) }
            if result.isFinal { text += String(result.text.characters) }
        }
    }
    try await analyzer.start(inputSequence: inputs)
    try await feed(continuation, format: format)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try? await reader.value
    return (first, text)
}

func runDictationTranscriber(preset: DictationTranscriber.Preset, label: String, punctuated: Bool = false) async throws
    -> (first: Double?, text: String) {
    var resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_AU"))
    if resolved == nil {
        resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }
    guard let locale = resolved else { return (nil, "<no locale>") }
    // Explicit options rather than the bare preset: the preset ships without
    // punctuation, and comparing a punctuated transcript against an unpunctuated
    // one measures the option, not the engine.
    let module = punctuated
        ? DictationTranscriber(locale: locale,
                               contentHints: [.shortForm],
                               transcriptionOptions: [.punctuation],
                               reportingOptions: preset.reportingOptions,
                               attributeOptions: [])
        : DictationTranscriber(locale: locale, preset: preset)
    let analyzer = SpeechAnalyzer(modules: [module])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
        return (nil, "<no format>")
    }
    let (inputs, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let start = Date()
    var first: Double?
    var text = ""

    let reader = Task {
        for try await result in module.results {
            if first == nil { first = Date().timeIntervalSince(start) }
            if result.isFinal { text += String(result.text.characters) }
        }
    }
    try await analyzer.start(inputSequence: inputs)
    try await feed(continuation, format: format)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try? await reader.value
    return (first, text)
}

func show(_ label: String, _ r: (first: Double?, text: String)) {
    let payload: [String: Any] = [
        "engine": label,
        "clip": url.deletingPathExtension().lastPathComponent,
        "first_ms": r.first.map { Int(($0 * 1000).rounded()) } as Any,
        "text": r.text,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
}


@main
struct Probe {
    static func main() async {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        guard !path.isEmpty else {
            FileHandle.standardError.write(Data("usage: dictprobe <file.wav>\n".utf8))
            exit(2)
        }
        url = URL(fileURLWithPath: path)

            do { show("speech-current", try await runSpeechTranscriber()) }
            catch { FileHandle.standardError.write(Data("speech failed: \(error)\n".utf8)) }
            do { show("dictation-progressive", try await runDictationTranscriber(
                    preset: .progressiveShortDictation, label: "p", punctuated: true)) }
            catch { FileHandle.standardError.write(Data("dictation failed: \(error)\n".utf8)) }
    }
}

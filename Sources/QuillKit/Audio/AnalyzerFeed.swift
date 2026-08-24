import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Turns capture buffers into `AnalyzerInput`s at whatever format the speech
/// models actually want (16 kHz mono, in practice — but it is asked, not assumed).
///
/// Two implementations because the package floor is macOS 26 and the good one is
/// 27-only. Everything downstream is written against this protocol so the
/// difference stops here.
protocol AnalyzerFeeding: AnyObject {
    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput]
    /// Whatever the converter is still holding after the last buffer. Skipping
    /// this drops the tail of the final word.
    func flush() throws -> [AnalyzerInput]
}

enum AnalyzerFeed {

    /// One path, always: the hand-rolled converter below.
    ///
    /// **There used to be two, chosen by `#if compiler(>=6.4)`, and that is a
    /// choice made by whichever machine compiles the code rather than by anyone
    /// reading it.** GitHub's runner had a newer Xcode than the developer's Mac,
    /// so every published release silently took the macOS 27
    /// `AnalyzerInputConverter` branch while every local build took this one —
    /// no commit, no diff, nothing to review.
    ///
    /// That branch does not work. Measured on one 6.5-second clip, same Mac,
    /// same file, the two builds of the same commit:
    ///
    ///     locally built (Swift 6.3.3) : 28 partial, 4 final,
    ///                                   "What is your country, Olaf? …"
    ///     CI built      (Swift 6.4+)  : 0 partial, empty transcript,
    ///                                   "Audio input timestamp overlaps or
    ///                                    precedes prior audio input"
    ///
    /// So dictation was broken in every release ever published, and worked
    /// perfectly for the one person who built it himself — the exact shape of
    /// the `Bundle.module` crash in v1.0.0, arrived at by a different route.
    /// `Scripts/check_transcription.sh` now runs the built app against a real
    /// clip so the release job fails instead of shipping silence.
    ///
    /// `AnalyzerInputConverter` can come back the day someone can run it against
    /// audio and show a transcript coming out. Not before: it was adopted for
    /// tidiness, it has never once produced a word in a shipped build, and a
    /// second path nobody can execute is not a fallback, it is a coin toss on the
    /// build machine.
    static func make(
        modules: [any SpeechModule],
        captureFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat?
    ) async throws -> AnalyzerFeeding {
        guard let analyzerFormat else { throw TranscriptionError.noCompatibleAudioFormat }
        return LegacyAnalyzerFeed(from: captureFormat, to: analyzerFormat)
    }
}

/// A single stateful `AVAudioConverter` doing sample-rate and
/// channel conversion.
///
/// It has to be one long-lived converter, not one per buffer — a resampler
/// carries filter state across calls, and recreating it every 100 ms puts a click
/// at every boundary that the recognizer hears as consonants.
private final class LegacyAnalyzerFeed: AnalyzerFeeding {
    private let converter: AVAudioConverter?
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let lock = NSLock()

    init(from source: AVAudioFormat, to target: AVAudioFormat) {
        self.source = source
        self.target = target
        let converter = AVAudioConverter(from: source, to: target)
        // Priming inserts silence at the head to give the filter history; for
        // push-to-talk that silence is in front of the first word.
        converter?.primeMethod = .none
        self.converter = converter
    }

    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else { throw TranscriptionError.noCompatibleAudioFormat }

        lock.lock(); defer { lock.unlock() }

        let ratio = target.sampleRate / source.sampleRate
        // The slack matters: a resampler can emit more frames than the naive
        // ratio predicts, and a short output buffer silently truncates.
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError { throw conversionError }
        guard status != .error, out.frameLength > 0 else { return [] }

        let startTime: CMTime?
        if let time, time.isSampleTimeValid, time.sampleRate > 0 {
            startTime = CMTime(seconds: Double(time.sampleTime) / time.sampleRate, preferredTimescale: 48_000)
        } else {
            // nil means "contiguous with the last buffer", which is exactly true
            // for a continuous engine tap.
            startTime = nil
        }
        return [AnalyzerInput(buffer: out, bufferStartTime: startTime)]
    }

    func flush() throws -> [AnalyzerInput] { [] }
}

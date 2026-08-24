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

    /// Two paths, and which one you get depends on the toolchain that compiled
    /// this file. That is not a design; it is a fact to be defended against.
    ///
    /// `Scripts/build.sh` tries the Command Line Tools toolchain first and falls
    /// back to Xcode's. On this Mac those are Swift 6.4 and Swift 6.3.3 — so a
    /// local build takes the branch below and a build on a machine without CLT
    /// takes the other one. Every published release took the other one, because
    /// that is what the GitHub runner resolves to.
    ///
    /// Measured, same Mac, same 3-second clip, same commit:
    ///
    ///     modern (AnalyzerInputConverter) : 12 partial, 3 final, correct text
    ///     legacy (hand-rolled)            : 0 partial, empty, "Audio input
    ///                                       timestamp overlaps or precedes"
    ///
    /// So dictation worked for whoever built it and has never once worked in a
    /// release. The legacy path's timestamps were the bug — see
    /// `LegacyAnalyzerFeed` — and are fixed; both paths now transcribe. This
    /// keeps both because a fallback that only exists on paper is what produced
    /// eight broken releases, and `Scripts/verify_release.sh` checks the artefact
    /// that actually ships rather than the one that happened to be built here.
    static func make(
        modules: [any SpeechModule],
        captureFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat?
    ) async throws -> AnalyzerFeeding {
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            return ModernAnalyzerFeed(try await AnalyzerInputConverter.converter(compatibleWith: modules))
        }
        #endif
        guard let analyzerFormat else { throw TranscriptionError.noCompatibleAudioFormat }
        return LegacyAnalyzerFeed(from: captureFormat, to: analyzerFormat)
    }
}

#if compiler(>=6.4)
/// macOS 27's `AnalyzerInputConverter`: it owns the resampling, the format
/// negotiation and the chunking that the fallback below has to do by hand.
///
/// Gated on the compiler, not just `@available`: `AnalyzerInputConverter` has
/// to be *declared* in the SDK being compiled against, which only ships with
/// the Swift 6.4 toolchain — a machine that has updated its OS to macOS 27
/// ahead of Xcode has that type nowhere for `@available` alone to find. Once
/// Xcode catches up, this compiles back in on its own; nothing to revert.
@available(macOS 27, *)
private final class ModernAnalyzerFeed: AnalyzerFeeding {
    private let converter: AnalyzerInputConverter
    // The engine tap and the stop() path can both reach the converter, and it is
    // a plain class with no isolation of its own.
    private let lock = NSLock()

    init(_ converter: AnalyzerInputConverter) { self.converter = converter }

    func inputs(from buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws -> [AnalyzerInput] {
        lock.lock(); defer { lock.unlock() }
        return try converter.convert(buffer, at: time)
    }

    func flush() throws -> [AnalyzerInput] {
        lock.lock(); defer { lock.unlock() }
        return try converter.flush()
    }
}
#endif

/// The fallback, for a toolchain without `AnalyzerInputConverter`.
///
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
    /// Frames handed to the analyzer so far, in the analyzer's own sample rate.
    /// Guarded by `lock` with the converter it belongs to.
    private var emitted: AVAudioFramePosition = 0

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

        // Counted in OUTPUT frames, not derived from the input's sample time.
        //
        // **This is what broke dictation in every published release.** The old
        // version computed `CMTime(seconds: time.sampleTime / time.sampleRate)`
        // from the capture timeline, then handed the analyzer a buffer measured
        // in the analyzer's own rate. Those two do not line up: a resampler emits
        // whatever number of frames the filter has ready, not exactly
        // `frameLength × ratio`, so consecutive buffers claim start times that
        // overlap the duration of the one before. `SpeechAnalyzer` rejects that —
        //
        //     Audio input timestamp overlaps or precedes prior audio input
        //
        // — and once rejected it returns no results at all. Zero partials, an
        // empty final, and a user watching one wrong word appear for a whole
        // spoken sentence.
        //
        // A running count of frames actually emitted, at the rate they are
        // emitted in, is monotonic by construction and exactly as long as the
        // audio it describes. Nothing else can be, because only the converter
        // knows how many frames it produced.
        let startTime = CMTime(value: emitted, timescale: CMTimeScale(target.sampleRate))
        emitted += AVAudioFramePosition(out.frameLength)
        return [AnalyzerInput(buffer: out, bufferStartTime: startTime)]
    }

    func flush() throws -> [AnalyzerInput] { [] }
}

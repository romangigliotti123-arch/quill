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

    /// Picks the 27 path when it is there, the hand-rolled one when it is not.
    /// `analyzerFormat` is only consulted by the fallback; the macOS 27 converter
    /// negotiates it with the modules itself.
    static func make(
        modules: [any SpeechModule],
        captureFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat?
    ) async throws -> AnalyzerFeeding {
        if #available(macOS 27, *) {
            return ModernAnalyzerFeed(try await AnalyzerInputConverter.converter(compatibleWith: modules))
        }
        guard let analyzerFormat else { throw TranscriptionError.noCompatibleAudioFormat }
        return LegacyAnalyzerFeed(from: captureFormat, to: analyzerFormat)
    }
}

/// macOS 27's `AnalyzerInputConverter`: it owns the resampling, the format
/// negotiation and the chunking that the fallback below has to do by hand.
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

/// macOS 26 fallback: a single stateful `AVAudioConverter` doing sample-rate and
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

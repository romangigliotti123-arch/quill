import AVFoundation
import Foundation

/// Microphone capture on `AVAudioEngine`.
///
/// macOS 27 ships `CaptureInputSequenceProvider`, which would replace this whole
/// type with three lines — but it is built on `AVCaptureSession` and hands back
/// only `AnalyzerInput`s, so the overlay's level meter would have to be
/// reconstructed by decoding the analyzer's own 16 kHz stream back into samples
/// through an API that is deprecated in the same SDK release. The engine tap
/// gives the transcriber and the meter the same buffer for free, and it is the
/// path that has actually shipped. See AnalyzerFeed.swift for the piece of
/// macOS 27 that *is* worth taking: `AnalyzerInputConverter`.
public final class AudioCapture: AudioSource {

    public var onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?
    public var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private let enableVoiceProcessing: Bool
    private var running = false
    private var prepared = false

    /// Voice processing needs roughly 300 ms to settle, and buffers captured
    /// inside that window come back attenuated or silent — murmur lost the first
    /// word of short dictations to exactly this. For push-to-talk that 300 ms is
    /// the entire latency budget, so Quill leaves it off by default: the
    /// transcriber's own models are noise-robust, and the mic is a hand's width
    /// from the speaker. The flag is here for anyone who wants to trade first-word
    /// latency for echo cancellation on a desk speaker setup.
    public init(enableVoiceProcessing: Bool = false) {
        self.enableVoiceProcessing = enableVoiceProcessing
    }

    public var captureFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        // A sample rate of zero is how the engine reports "there is no usable
        // input device", not an error — asking it to start in that state throws
        // something unreadable about kAudioUnitErr_FormatNotSupported.
        return format.sampleRate > 0 ? format : nil
    }

    public func prepare() {
        guard !prepared, !running else { return }
        // Touching inputNode is what actually instantiates the HAL unit; doing it
        // on hotkey-down means start() is a flag flip rather than a device open.
        _ = engine.inputNode
        engine.prepare()
        prepared = true
    }

    public func start() throws {
        guard !running else { return }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            throw AudioSourceError.microphoneDenied
        }

        let input = engine.inputNode

        if enableVoiceProcessing {
            // Best effort: a device that refuses voice processing still captures.
            try? input.setVoiceProcessingEnabled(true)
        }

        // Read the format *after* the voice-processing switch — enabling it
        // changes the node's output format underneath you.
        guard let format = captureFormat else { throw AudioSourceError.noInputDevice }

        let warmupDeadline = (enableVoiceProcessing && input.isVoiceProcessingEnabled)
            ? Date().addingTimeInterval(0.3)
            : nil

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if let warmupDeadline, Date() < warmupDeadline { return }
            self.onBuffer?(buffer, time)
            let level = LevelMeter.level(of: buffer)
            DispatchQueue.main.async { self.onLevel?(level) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineFailed(error.localizedDescription)
        }
        running = true
    }

    public func stop() {
        guard running else { return }
        // Order matters: pulling the tap first guarantees no callback can fire
        // into a half-torn-down session while the engine spins down.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // stop() halts rendering; it does NOT discard what the nodes have already
        // buffered. Restart the same engine and those frames are delivered as the
        // first audio of the NEXT dictation, so the transcript opens with the tail
        // of the previous one.
        //
        // Proven rather than assumed: the rig records an independent tap of the
        // same audio window, and for the contaminated clips that tap contained
        // ONLY the correct utterance. The device was clean; the leftovers were
        // inside this engine. reset() is the documented way to drop them.
        engine.reset()

        running = false
        prepared = false
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }
}

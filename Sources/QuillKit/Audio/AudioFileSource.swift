import AVFoundation
import Foundation

/// An `AudioSource` that plays a file instead of opening the microphone.
///
/// This is not a convenience — it is the only way the transcription path can be
/// verified at all. A microphone needs a granted TCC prompt, a human, and a
/// quiet room; a WAV needs none of those, so "does the engine actually produce
/// text, and how fast" becomes a command you can run instead of a claim you make.
///
/// In `realtime` mode buffers are released on a wall-clock schedule matching the
/// audio's own timeline, which is what makes measured partial latency mean the
/// same thing it would with a live mic.
/// `@unchecked` because the pump task and its owner touch this object from two
/// executors. It is single-producer, single-consumer by construction: nothing
/// mutates it between `start()` and `stop()`.
public final class AudioFileSource: AudioSource, @unchecked Sendable {

    public var onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?
    public var onLevel: ((Float) -> Void)?
    /// Fired once the last buffer has been delivered.
    public var onEnded: (() -> Void)?

    public let url: URL
    public let realtime: Bool
    /// Seconds of audio per delivered buffer. 0.1 s matches what a 1024-frame
    /// engine tap feels like at 16 kHz and is what the latency scout measured with.
    public let chunkDuration: Double

    private var file: AVAudioFile?
    private var pump: Task<Void, Never>?

    public init(url: URL, realtime: Bool = true, chunkDuration: Double = 0.1) {
        self.url = url
        self.realtime = realtime
        self.chunkDuration = chunkDuration
    }

    public private(set) var duration: TimeInterval = 0

    public var captureFormat: AVAudioFormat? { file?.processingFormat }

    public func prepare() {
        guard file == nil else { return }
        guard let opened = try? AVAudioFile(forReading: url) else { return }
        file = opened
        duration = Double(opened.length) / opened.processingFormat.sampleRate
    }

    public func start() throws {
        prepare()
        guard let file else { throw AudioSourceError.engineFailed("cannot read \(url.lastPathComponent)") }
        guard pump == nil else { return }

        let format = file.processingFormat
        let framesPerChunk = AVAudioFrameCount(format.sampleRate * chunkDuration)
        let started = Date()
        // A second start() on the same source must replay, not read past the end:
        // `read(into:)` continues from wherever the last run left the cursor.
        file.framePosition = 0

        pump = Task { [weak self] in
            var position: AVAudioFramePosition = 0
            var chunkIndex = 0
            while position < file.length, !Task.isCancelled {
                let wanted = min(AVAudioFrameCount(file.length - position), framesPerChunk)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: wanted) else { break }
                do { try file.read(into: buffer, frameCount: wanted) } catch { break }
                if buffer.frameLength == 0 { break }

                let time = AVAudioTime(sampleTime: position, atRate: format.sampleRate)
                self?.onBuffer?(buffer, time)
                let level = LevelMeter.level(of: buffer)
                DispatchQueue.main.async { self?.onLevel?(level) }

                position += AVAudioFramePosition(buffer.frameLength)
                chunkIndex += 1

                if self?.realtime == true {
                    // Sleep to the absolute schedule rather than by a fixed
                    // interval, so decode time does not accumulate into drift and
                    // quietly turn a "realtime" run into a slow one.
                    let due = started.addingTimeInterval(Double(chunkIndex) * (self?.chunkDuration ?? 0.1))
                    let remaining = due.timeIntervalSinceNow
                    if remaining > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
            }
            if !Task.isCancelled { self?.onEnded?() }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        DispatchQueue.main.async { [weak self] in self?.onLevel?(0) }
    }
}

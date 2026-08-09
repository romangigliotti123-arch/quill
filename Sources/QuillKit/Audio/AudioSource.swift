import AVFoundation
import Foundation

/// Where PCM comes from. The only reason this is a protocol is that a real
/// microphone cannot be exercised in a test or on a build machine — the file
/// source behind it is what makes the transcription path provable without
/// hardware, a TCC grant, or a human being in the room.
public protocol AudioSource: AnyObject {
    /// Raw capture buffers, delivered on whatever thread produced them (for the
    /// microphone that is a real-time audio thread — do nothing slow in here).
    /// `time` is the capture timestamp, or nil when the producer has none.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)? { get set }
    /// Normalized 0…1 input level for the overlay waveform, delivered on main.
    var onLevel: ((Float) -> Void)? { get set }

    /// The format buffers will arrive in. Only meaningful once `start()` has
    /// been called, because the microphone's format is decided by the device.
    var captureFormat: AVAudioFormat? { get }

    /// Allocate whatever is expensive, without opening the mic. Called on
    /// hotkey-down alongside the model warm so `start()` is close to free.
    func prepare()
    func start() throws
    func stop()
}

public enum AudioSourceError: LocalizedError {
    case noInputDevice
    case microphoneDenied
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available. Check the input device in System Settings ▸ Sound."
        case .microphoneDenied:
            return "Quill cannot hear you — grant Microphone in \(Permission.microphone.settingsPath)."
        case .engineFailed(let detail):
            return "The audio engine would not start: \(detail)"
        }
    }
}

/// Level metering, kept apart from capture so it can be tested against
/// synthesised buffers instead of a microphone.
public enum LevelMeter {

    /// Below this the meter reads zero; a quiet room floors around -60 dBFS and
    /// a waveform that twitches at the noise floor reads as "it's hearing me"
    /// when it is not.
    public static let floorDB: Float = -55
    /// Normal speech at a laptop mic peaks around -12 dBFS, so the meter is
    /// scaled to be fully lit there rather than at 0 dBFS, which only clipping
    /// ever reaches.
    public static let ceilingDB: Float = -12

    /// RMS of the first channel, mapped to 0…1 on a decibel scale. Linear RMS
    /// was tried first and looks dead: speech spends most of its energy in the
    /// bottom tenth of a linear scale, so the waveform barely moves.
    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else {
            return int16Level(of: buffer)
        }
        return normalize(rms(channels[0], frames: Int(buffer.frameLength)))
    }

    /// A file source can hand us Int16 (that is what `say` writes), and
    /// `floatChannelData` is nil for those.
    private static func int16Level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.int16ChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Double = 0
        let channel = channels[0]
        for i in 0..<frames {
            let sample = Double(channel[i]) / 32768.0
            sum += sample * sample
        }
        return normalize(Float((sum / Double(frames)).squareRoot()))
    }

    private static func rms(_ samples: UnsafePointer<Float>, frames: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Double = 0
        for i in 0..<frames {
            let sample = Double(samples[i])
            sum += sample * sample
        }
        return Float((sum / Double(frames)).squareRoot())
    }

    /// Exposed so a test can assert the curve without owning a buffer.
    public static func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        let scaled = (db - floorDB) / (ceilingDB - floorDB)
        return min(1, max(0, scaled))
    }
}

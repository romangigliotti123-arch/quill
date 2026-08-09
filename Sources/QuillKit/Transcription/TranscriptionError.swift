import Foundation
import Speech

public enum TranscriptionError: LocalizedError {
    case unavailable
    case localeUnsupported(String)
    case modelNotInstalled(String)
    case noCompatibleAudioFormat
    /// The analyzer accepted audio but never closed out the session. The text
    /// collected so far is still delivered — this is reported, not swallowed.
    case finalizeTimedOut(seconds: Double)
    case notAuthorized
    case missingUsageDescription(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device speech transcription is not available on this Mac."
        case .localeUnsupported(let id):
            return "No speech model supports \(id)."
        case .modelNotInstalled(let id):
            return "The \(id) speech model is not installed yet. macOS installs it on demand — "
                 + "open System Settings ▸ General ▸ Language & Region and add the language, then try again."
        case .noCompatibleAudioFormat:
            return "No audio format the speech models accept could be negotiated."
        case .finalizeTimedOut(let seconds):
            return "The transcriber did not finish within \(Int(seconds * 1000))ms; using the text captured so far."
        case .notAuthorized:
            return "Speech Recognition permission has not been granted."
        case .missingUsageDescription(let key):
            return "\(key) is missing from Info.plist. Asking for this permission without it "
                 + "terminates the process instead of returning a denial, so the request was skipped."
        }
    }
}

/// Locale and model-asset handling, kept out of the transcriber because it is
/// process-wide state with a hard cap, not per-dictation state.
public enum SpeechAssets {

    /// Roman is in Melbourne; en-AU is what his vowels are. If the OS has no
    /// en-AU model this falls back rather than failing, because a US model
    /// transcribing an Australian is far better than no dictation.
    public static let preferredLocale = Locale(identifier: "en_AU")

    /// Resolves a wanted locale to one the installed models actually claim.
    /// Returns nil only when English itself is unsupported, which should not
    /// happen on a shipping Mac.
    public static func resolve(_ wanted: Locale = preferredLocale) async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return match }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    /// Reserving pins the model so the OS does not evict it. There is a hard cap
    /// of five reservations per process and reserving over it throws, so the
    /// count is checked first; a full inventory is not an error worth failing a
    /// dictation over, and releasing somebody else's reservation is not ours to do.
    ///
    /// This never downloads: English models ship with the OS and are OS-managed.
    /// If one genuinely is not installed, `isInstalled` reports it and the caller
    /// surfaces `modelNotInstalled` instead of silently pulling gigabytes over
    /// the network on an app that advertises itself as offline.
    @discardableResult
    public static func reserve(_ locale: Locale) async -> Bool {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return true }
        guard reserved.count < AssetInventory.maximumReservedLocales else { return false }
        return (try? await AssetInventory.reserve(locale: locale)) ?? false
    }

    public static func isInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }
}

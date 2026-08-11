import Foundation

/// Everything about Quill a user is allowed to change, in one place, on disk.
///
/// Read from three threads that never meet: the event tap's own runloop (which
/// asks for the bindings on every keystroke), the audio thread (which asks for
/// the microphone when the engine spins up), and main (the Settings screen).
/// Hence the lock — and hence the deliberate absence of `@MainActor`, which
/// would put an actor hop on the hot path of a keystroke.
///
/// Values are read live rather than cached by their consumers. Changing the
/// dictation key takes effect on the next key press, not the next launch; that
/// is the difference between a setting and a preference file.
public final class QuillSettings: @unchecked Sendable, HotkeyBindingProviding {

    public static let shared = QuillSettings()

    /// Overridable, because a measurement run has no business editing the
    /// settings of the person it is measuring.
    ///
    /// The eval rig needs a specific microphone and specific key bindings, and
    /// the only way to give it those was to write the real settings file and put
    /// it back afterwards. It was put back by hand, which means once it was not:
    /// Roman's chosen microphone was erased and "show text as you speak" — the
    /// feature he had asked for that morning — came back off, with nothing to
    /// indicate either had happened. A run that mutates the user's configuration
    /// is one interrupted run away from losing it.
    ///
    /// `QUILL_SETTINGS_FILE` points the whole app at a scratch file instead.
    public static let defaultURL: URL = {
        if let override = ProcessInfo.processInfo.environment["QUILL_SETTINGS_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quill/settings.json")
    }()

    /// The persisted shape. Every field is optional-tolerant on decode so a
    /// settings file written by an older build never stops the app launching —
    /// a corrupt or partial file falls back to defaults rather than throwing.
    public struct Values: Codable, Sendable, Equatable {
        public var holdKeyCode: UInt16
        public var toggleKeyCode: UInt16
        /// CoreAudio device UID, or nil to follow whatever the system default is.
        /// UID rather than the numeric AudioDeviceID: IDs are reassigned on every
        /// boot and on every replug, so a saved ID points at a different
        /// microphone tomorrow.
        public var inputDeviceUID: String?
        /// Type the words into the focused app as they are recognised, instead of
        /// pasting the finished sentence on key release.
        public var liveText: Bool

        public init(holdKeyCode: UInt16 = HotkeyBinding.rightOption.keyCode,
                    toggleKeyCode: UInt16 = HotkeyBinding.rightOption.keyCode,
                    inputDeviceUID: String? = nil,
                    liveText: Bool = true) {
            self.holdKeyCode = holdKeyCode
            self.toggleKeyCode = toggleKeyCode
            self.inputDeviceUID = inputDeviceUID
            self.liveText = liveText
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Values()
            holdKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .holdKeyCode) ?? fallback.holdKeyCode
            toggleKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .toggleKeyCode) ?? fallback.toggleKeyCode
            inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
            liveText = try c.decodeIfPresent(Bool.self, forKey: .liveText) ?? fallback.liveText
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var values: Values
    private var capturing = false

    /// Tests pass their own URL. A self-test that rewrites the real settings file
    /// would change the app under the person running it.
    public init(url: URL = QuillSettings.defaultURL) {
        self.url = url
        self.values = Values()
        load()
    }

    // MARK: - Reading

    public var current: Values { withLock { values } }

    public var hold: HotkeyBinding { HotkeyBinding(keyCode: withLock { values.holdKeyCode }) }
    public var toggle: HotkeyBinding { HotkeyBinding(keyCode: withLock { values.toggleKeyCode }) }
    public var inputDeviceUID: String? { withLock { values.inputDeviceUID } }
    public var liveText: Bool { withLock { values.liveText } }

    /// True when one key does both jobs, which is the default and means push-to-talk
    /// is reached by double-tapping rather than by a key of its own.
    public var toggleSharesHoldKey: Bool {
        withLock { values.holdKeyCode == values.toggleKeyCode }
    }

    /// Set while the Settings screen is listening for a new binding.
    ///
    /// Without it, pressing the key you are trying to assign starts a dictation
    /// into the settings window — the recorder and the engine are watching the
    /// same physical key press, and only one of them should win.
    public var isCapturingHotkey: Bool {
        get { withLock { capturing } }
        set { withLock { capturing = newValue } }
    }

    // MARK: - Writing

    public func update(_ mutate: (inout Values) -> Void) {
        var changed = false
        lock.lock()
        var copy = values
        mutate(&copy)
        if copy != values {
            values = copy
            changed = true
        }
        lock.unlock()
        guard changed else { return }
        save(copy)
        NotificationCenter.default.post(name: .quillSettingsChanged, object: nil)
    }

    public func setHold(_ binding: HotkeyBinding) { update { $0.holdKeyCode = binding.keyCode } }
    public func setToggle(_ binding: HotkeyBinding) { update { $0.toggleKeyCode = binding.keyCode } }
    public func setInputDeviceUID(_ uid: String?) { update { $0.inputDeviceUID = uid } }
    public func setLiveText(_ on: Bool) { update { $0.liveText = on } }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Values.self, from: data)
        else { return }
        values = decoded
    }

    private func save(_ snapshot: Values) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

public extension Notification.Name {
    /// Posted after any setting actually changed value. Consumers that cache
    /// (the menu bar's hint text, the settings screen itself) rebuild on this;
    /// the event tap does not need it, because it reads live.
    static let quillSettingsChanged = Notification.Name("com.romangigliotti.quill.settingsChanged")
}

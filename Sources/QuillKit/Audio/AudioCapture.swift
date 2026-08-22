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

    /// Both handlers are written from whatever thread drives a dictation and read
    /// from the tap's own queue, so both go through the lock.
    ///
    /// Capturing them once when the tap is installed would be cheaper and is the
    /// obvious fix, but it is the wrong one here: setting `onBuffer = nil` is how
    /// the transcriber detaches from a SHARED audio source without stopping the
    /// engine, and a captured copy would keep feeding a session that has already
    /// been torn down. The tap has to see the current value, which means it has to
    /// be read safely.
    ///
    /// A lock is acceptable on this path because `installTap` delivers on an
    /// AVAudioEngine-owned serial queue, not the HAL render thread — this is not
    /// a real-time context, and the alternative is an unsynchronised read of a
    /// closure reference while another thread reassigns it.
    public var onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)? {
        get { withLock { _onBuffer } }
        set { withLock { _onBuffer = newValue } }
    }
    public var onLevel: ((Float) -> Void)? {
        get { withLock { _onLevel } }
        set { withLock { _onLevel = newValue } }
    }

    public var onInterruption: ((AudioSourceError) -> Void)? {
        get { withLock { _onInterruption } }
        set { withLock { _onInterruption = newValue } }
    }

    private var _onBuffer: ((AVAudioPCMBuffer, AVAudioTime?) -> Void)?
    private var _onLevel: ((Float) -> Void)?
    private var _onInterruption: ((AudioSourceError) -> Void)?
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private let engine = AVAudioEngine()
    private let enableVoiceProcessing: Bool
    private let settings: QuillSettings
    private var running = false
    private var prepared = false
    /// The format the live tap was installed with, kept so a configuration change
    /// can be compared against it. The transcriber built its analyzer feed from
    /// this exact format once and never re-asks, so "the same numbers" is the
    /// difference between carrying on and having to stop.
    private var activeFormat: AVAudioFormat?
    private var configurationObserver: NSObjectProtocol?

    /// Voice processing needs roughly 300 ms to settle, and buffers captured
    /// inside that window come back attenuated or silent — murmur lost the first
    /// word of short dictations to exactly this. For push-to-talk that 300 ms is
    /// the entire latency budget, so Quill leaves it off by default: the
    /// transcriber's own models are noise-robust, and the mic is a hand's width
    /// from the speaker. The flag is here for anyone who wants to trade first-word
    /// latency for echo cancellation on a desk speaker setup.
    public init(enableVoiceProcessing: Bool = false,
                settings: QuillSettings = .shared) {
        self.enableVoiceProcessing = enableVoiceProcessing
        self.settings = settings
        // Block-based, so the token is what removes it. `removeObserver(self)`
        // does not touch observers registered this way.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// The input hardware changed underneath a live dictation.
    ///
    /// AirPods connecting or dropping, a call starting and moving them between
    /// their 48 kHz and 16 kHz modes, a USB interface unplugged, the system
    /// default switching. Per Apple's contract the engine stops and uninitializes
    /// itself when this happens, taking the installed tap with it — so buffers
    /// simply stop. Nothing downstream can tell: `running` is still true,
    /// `engine.isRunning` is read nowhere, and the coordinator's only liveness
    /// signal is the level meter, which has no timeout on its own absence. Roman
    /// loses the second half of a sentence and is handed the first half as though
    /// it were all of it.
    ///
    /// Two outcomes, and the difference is the format. The transcriber reads
    /// `captureFormat` once at `start()` and builds an `AnalyzerFeeding` around
    /// it — on macOS 26 that is a single long-lived `AVAudioConverter` with
    /// `primeMethod = .none` — and never re-asks. Feeding it buffers at a
    /// different sample rate is API misuse: at best it resamples at the wrong
    /// ratio and the recogniser hears garbled speech, which is worse than
    /// truncation because the text comes out plausible. So:
    ///
    ///   - same format → reinstall the tap and restart. Only the gap is lost.
    ///   - different, or gone → stop, and say so. Visible truncation beats
    ///     silent truncation, and beats invented words by more than that.
    private func handleConfigurationChange() {
        guard running, let installed = activeFormat else { return }

        let replacement = captureFormat
        if let replacement,
           replacement.sampleRate == installed.sampleRate,
           replacement.channelCount == installed.channelCount,
           // Asked of the node itself, immediately before handing the format
           // back to it. Same reason as in `start()`: a mismatch here is an
           // uncatchable exception rather than a returned error.
           engine.inputNode.inputFormat(forBus: 0).sampleRate == installed.sampleRate {
            engine.inputNode.removeTap(onBus: 0)
            installTap(format: installed)
            engine.prepare()
            if (try? engine.start()) != nil { return }
        }

        // Recovery is not possible or did not take. Tear down rather than sit
        // there `running` with no audio behind it.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        running = false
        prepared = false
        activeFormat = nil
        let handler = withLock { _onInterruption }
        handler?(.noInputDevice)
    }

    /// The format the tap must be installed with: the input node's INPUT side.
    ///
    /// `inputFormat`, not `outputFormat`. On the input node these are two
    /// different formats and only one of them is the hardware's:
    ///
    ///   - `inputFormat(forBus:0)`  — what the device is actually producing.
    ///   - `outputFormat(forBus:0)` — what the node hands the rest of the graph,
    ///     which stays on whatever rate the engine was built against.
    ///
    /// They are equal whenever the selected device happens to run at the engine's
    /// rate, which is why this read the wrong one for so long: with the built-in
    /// microphone (44100) both say 44100 and everything works. Point the unit at
    /// a device running at a different rate — BlackHole at 48000, the eval rig's
    /// loopback — and they diverge:
    ///
    ///     device's own nominal rate     48000
    ///     inputNode.inputFormat         48000   <- the hardware
    ///     inputNode.outputFormat        44100   <- the graph, unchanged
    ///
    /// `installTap` validates its `format` against the hardware side and throws
    /// an Objective-C exception when they disagree — uncatchable from Swift, so
    /// the process aborts:
    ///
    ///     required condition is false: format.sampleRate == inputHWFormat.sampleRate
    ///
    /// That was a hard crash on every dictation whenever a non-44100 device was
    /// selected. It looks like a race — the CoreAudio logs show the device
    /// renegotiating for ~300ms after the switch — and it is not one: waiting,
    /// polling until two reads agree, `engine.reset()`, and listening for
    /// `AVAudioEngineConfigurationChange` were all tried and all failed, because
    /// `outputFormat` is not stale, it is a different and stable number that was
    /// never the right one to ask for.
    ///
    /// Proven with a standalone harness against BlackHole: `outputFormat` throws,
    /// `inputFormat` installs and delivers 48000 frames in one second.
    ///
    /// A sample rate of zero is how the engine reports "there is no usable
    /// input device", not an error — asking it to start in that state throws
    /// something unreadable about kAudioUnitErr_FormatNotSupported.
    ///
    /// That guard reads better against this property than the one it replaced.
    /// Measured: after an `AudioUnitSetProperty` that FAILS (device id refused,
    /// -10851), `inputFormat` reports 0 and `outputFormat` still reports 44100.
    /// The old code would have carried on with a plausible number describing a
    /// device the unit is not on; this returns nil and the caller throws
    /// `noInputDevice`, which is the truth.
    public var captureFormat: AVAudioFormat? {
        let format = engine.inputNode.inputFormat(forBus: 0)
        return format.sampleRate > 0 ? format : nil
    }

    public func prepare() {
        guard !prepared, !running else { return }
        // Touching inputNode is what actually instantiates the HAL unit; doing it
        // on hotkey-down means start() is a flag flip rather than a device open.
        _ = engine.inputNode
        selectConfiguredInputDevice()
        engine.prepare()
        prepared = true
    }

    /// Points the engine's input at the microphone chosen in Settings.
    ///
    /// `AVAudioEngine` has no API for this: the input node is hard-wired to the
    /// system default, and the only way past it is to reach through to the
    /// underlying HAL audio unit. It has to happen while the engine is stopped,
    /// and before the format is read — changing the device changes the node's
    /// output format underneath you, and a tap installed with the old format
    /// silently delivers nothing.
    ///
    /// A device that is no longer plugged in is not an error worth failing on:
    /// falling through to the system default is what the user expects when they
    /// unplug a headset mid-day, and `AudioDeviceInfo.activeInputName` reports the
    /// same fallback so the transcript is stamped with what actually recorded it.
    ///
    /// The default has to be written back BY NAME, which is the whole reason this
    /// resolves a device id in the nil case instead of returning early.
    ///
    /// There is one `AVAudioEngine` for the process, and an audio-unit property
    /// persists on its instance — `stop()`/`reset()` do not clear one. So the
    /// early return this used to take when `inputDeviceUID` was nil left the unit
    /// pinned to whatever was chosen last. Pick "Shure MV7" in Settings, dictate
    /// once, put the picker back to "System default", put your AirPods in: every
    /// dictation after that still records the Shure, while the picker reads
    /// System default and `activeInputName(uid: nil)` stamps the history row
    /// "AirPods Pro" — capture and stamp disagreeing, which is the audit failure
    /// AudioDeviceInfo says it exists to prevent. With a loopback device selected
    /// during an eval it is total loss: silence every time, and an overlay
    /// blaming a microphone the user never chose. The documented unplug fallback
    /// had the same hole and only ever worked across a relaunch.
    ///
    /// Read before write, because this runs on the latency path. `prepare()` is
    /// called on key-down, and a CurrentDevice write forces a HAL renegotiation
    /// and changes the input node's format underneath the about-to-be-read
    /// `captureFormat`. On the common never-touched-the-picker case the device is
    /// already right, and the correct amount of work is none.
    private func selectConfiguredInputDevice() {
        guard let unit = engine.inputNode.audioUnit else { return }
        let target = settings.inputDeviceUID.flatMap(AudioDeviceInfo.deviceID(forUID:))
            ?? AudioDeviceInfo.defaultInputDeviceID()
        // No input device at all: leave the unit alone. `captureFormat` then
        // reports 0 and `start()` throws `noInputDevice`, which is the truth.
        guard var id = target else { return }

        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioUnitGetProperty(unit,
                                kAudioOutputUnitProperty_CurrentDevice,
                                kAudioUnitScope_Global,
                                0,
                                &current,
                                &size) == noErr, current == id {
            return
        }

        AudioUnitSetProperty(unit,
                             kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global,
                             0,
                             &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    public func start() throws {
        guard !running else { return }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            throw AudioSourceError.microphoneDenied
        }

        let input = engine.inputNode
        // Repeated from prepare() on purpose: start() is reachable without it
        // (a confirmation with no speculation behind it), and the device has to be
        // set on the stopped engine either way.
        selectConfiguredInputDevice()

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

        // `installTapOnBus` is the one call in this app that can kill the
        // process, and it did: every one of the fourteen crash reports on this
        // Mac is this line. It validates its arguments with an Objective-C
        // exception, which Swift cannot catch, so a bad argument is not an error
        // — it is `abort()`. From the outside that is "the app quits by itself",
        // with no message and nothing on screen, usually just as you press the
        // key to speak.
        //
        // Two arguments can be bad, and both are now checked here rather than
        // discovered by the assertion:
        //
        // 1. A tap is already on the bus. `installTapOnBus` throws rather than
        //    replacing, and this method could reach it with one installed —
        //    `running` is not set until the very end, so two starts racing each
        //    other both pass the guard at the top, and the recovery path in
        //    `handleConfigurationChange` installs one too. `removeTap` is a
        //    no-op when there is nothing there, so it is free to call always.
        // 2. The format does not describe the hardware. The engine asserts that
        //    the format handed in matches the input node's own, and the device
        //    can change in the microseconds between reading it and using it —
        //    unplugging a headset while pressing the key is enough.
        input.removeTap(onBus: 0)

        let live = input.inputFormat(forBus: 0)
        guard live.sampleRate > 0, live.channelCount > 0 else {
            throw AudioSourceError.noInputDevice
        }
        guard live.sampleRate == format.sampleRate,
              live.channelCount == format.channelCount else {
            // Changed underneath us between the read above and this line. An
            // error is the right answer: the caller shows "could not start
            // listening" and the next press works, which is a far better day
            // than the process disappearing.
            throw AudioSourceError.engineFailed(
                "the microphone changed while starting — press the key again")
        }

        installTap(format: format, warmupDeadline: warmupDeadline)
        activeFormat = format

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineFailed(error.localizedDescription)
        }
        running = true
    }

    /// One tap, in one place, so the recovery path cannot install a subtly
    /// different one from the start path.
    private func installTap(format: AVAudioFormat, warmupDeadline: Date? = nil) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if let warmupDeadline, Date() < warmupDeadline { return }
            // Read once, call outside the lock: the handler runs a transcription
            // ingest, and holding a lock across it would let a slow ingest block
            // whatever thread is trying to stop the dictation.
            let handler = self.withLock { self._onBuffer }
            handler?(buffer, time)
            let level = LevelMeter.level(of: buffer)
            DispatchQueue.main.async {
                let meter = self.withLock { self._onLevel }
                meter?(level)
            }
        }
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
        activeFormat = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let meter = self.withLock { self._onLevel }
            meter?(0)
        }
    }
}

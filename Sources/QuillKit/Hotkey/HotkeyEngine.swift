import CoreGraphics
import Foundation

/// Stamped into `.eventSourceUserData` on every keystroke Quill synthesises.
///
/// This is not housekeeping, it is load-bearing. The tap below is a *session*
/// tap, so the ⌘V the text injector posts comes straight back into this callback
/// looking exactly like the user slamming a key mid-hold — which cancels the very
/// dictation that is currently inserting its own result. The injector must stamp
/// this value (`CGEventSource.userData`, or per-event via
/// `setIntegerValueField(.eventSourceUserData:)`) on everything it posts; anything
/// carrying it is ignored here.
public let QuillSyntheticEventMarker: Int64 = 0x5155_494C_4C01  // "QUILL" + 0x01

/// Push-to-talk on a bare modifier, built on a CGEventTap.
///
/// Why a tap and not Carbon: `RegisterEventHotKey` cannot bind a bare modifier at
/// all, and a bare modifier is the only trigger that never fights with typing.
/// Why `.defaultTap` and not `.listenOnly`: only a default tap can return nil to
/// swallow an event, which is how Escape cancels a dictation without also
/// escaping out of whatever app is focused.
///
/// The tap runs on its own thread and runloop rather than main. A tap callback
/// that misses its deadline gets the tap force-disabled by the system, and "main
/// thread was busy laying out a window" is a routine way to miss it. Everything
/// the delegate sees is hopped back to main.
public final class EventTapHotkeyEngine: HotkeyEngine, @unchecked Sendable {

    // Mutable state is either confined to the tap thread (machine, timers) or
    // guarded by `lock` (tap, source, runloop, stopping). `delegate` is only ever
    // touched on main. Hence @unchecked.

    public weak var delegate: HotkeyEngineDelegate?

    /// Asked on every keystroke rather than read once. That is what makes a
    /// rebind take effect on the next key press instead of the next launch.
    private let bindings: HotkeyBindingProviding
    private let retryInterval: TimeInterval

    private var machine: HotkeyStateMachine
    private var armTimer: Timer?
    private var retryTimer: Timer?

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var worker: Thread?
    private var stopping = false
    private var lastReportedReason: String?

    public init(
        bindings: HotkeyBindingProviding = QuillSettings.shared,
        timing: HotkeyStateMachine.Timing = .default,
        retryInterval: TimeInterval = 2.0
    ) {
        self.bindings = bindings
        self.machine = HotkeyStateMachine(timing: timing)
        self.retryInterval = retryInterval
    }

    // Only ever reached if the engine was never started, or was already stopped:
    // the tap thread holds a strong reference for as long as it is running. That
    // is deliberate — the tap has an unretained pointer to self, and an engine
    // that outlives its owner is a leak, while one that dies under a live tap is
    // a crash. Owners must call stop().
    deinit {
        stop()
    }

    // MARK: - Lifecycle

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        let alreadyRunning = worker != nil
        lock.unlock()
        if alreadyRunning { return isInstalled }

        lock.lock()
        stopping = false
        lock.unlock()

        // Created on the caller's thread so `start()` can answer honestly and
        // synchronously; only servicing it needs the dedicated runloop. It is
        // recorded before the thread exists so a `stop()` that lands in between
        // still finds a port to invalidate.
        if let created = makeTap() {
            store(created)
        } else {
            reportUnavailable()
        }

        let thread = Thread { [weak self] in
            self?.serviceTap()
        }
        thread.name = "com.quill.hotkey-tap"
        thread.qualityOfService = .userInteractive

        lock.lock()
        worker = thread
        lock.unlock()
        thread.start()

        return isInstalled
    }

    public func stop() {
        lock.lock()
        guard worker != nil else { lock.unlock(); return }
        stopping = true
        // Killing the port here, synchronously, closes the window where a queued
        // callback could reach an engine that is already being deallocated — the
        // tap holds an unretained pointer to self.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        let runLoop = tapRunLoop
        worker = nil
        lock.unlock()

        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    public var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tap != nil
    }

    // MARK: - Tap thread

    private func serviceTap() {
        lock.lock()
        tapRunLoop = CFRunLoopGetCurrent()
        let stopBeforeStart = stopping
        let existing = tap
        lock.unlock()
        guard !stopBeforeStart else { tearDown(); return }

        if let existing {
            attach(existing)
        } else {
            scheduleRetry()
        }

        while !isStopping {
            // A bare CFRunLoopRun can return the instant its last source goes away
            // (between a failed tap and the next retry tick), so the loop is
            // explicit and a finished pass is throttled rather than spun on.
            if CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 10, false) == .finished {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        tearDown()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func makeTap() -> CFMachPort? {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: quillHotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func store(_ tap: CFMachPort) {
        lock.lock()
        self.tap = tap
        // Cleared so a *later* failure with the same cause still gets reported.
        lastReportedReason = nil
        lock.unlock()
    }

    /// Must run on the tap thread: the source has to belong to the runloop that
    /// will service it.
    private func attach(_ tap: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.lock()
        self.source = source
        lock.unlock()
    }

    private func tearDown() {
        armTimer?.invalidate()
        armTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        machine.reset()

        lock.lock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        tap = nil
        source = nil
        tapRunLoop = nil
        lock.unlock()
    }

    /// The grant almost never lands while the app is looking. Polling means the
    /// hotkey starts working the moment the user flips the switch in System
    /// Settings, instead of at the next launch — which is the difference between
    /// "it works" and "it's broken" for anyone who does not think to relaunch.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isStopping else { return }
            guard let tap = self.makeTap() else {
                self.reportUnavailable()
                return
            }
            self.retryTimer?.invalidate()
            self.retryTimer = nil
            self.store(tap)
            self.attach(tap)
        }
        retryTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    // MARK: - Event handling (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Both of these kill the tap permanently unless it is re-enabled: the
        // timeout when a callback ran long, the other when something else in the
        // session took over input. Neither reports an error anywhere.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Logged because this is invisible from the outside and it eats
            // keystrokes: between the disable and the next event the tap sees
            // nothing, so a dictation started in that window never begins at all.
            // If gestures are going missing, this line is the first thing to look
            // for.
            NSLog("[quill] tap disabled (%@) and re-enabled — events in that window were lost",
                  type == .tapDisabledByTimeout ? "timeout" : "user input")
            apply(machine.handle(.tapInterrupted, at: Self.now()))
            return false
        }

        if event.getIntegerValueField(.eventSourceUserData) == QuillSyntheticEventMarker {
            return false
        }

        // The Settings screen is waiting for the user to press the key they want
        // to assign. Acting on it here would start a dictation with the same press
        // that chose the key — so the engine goes deaf, and any gesture already in
        // flight is dropped rather than left half-finished.
        if bindings.isCapturingHotkey {
            if machine.state != .idle { apply(machine.handle(.tapInterrupted, at: Self.now())) }
            return false
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        switch type {
        case .flagsChanged:
            let hold = bindings.hold
            let toggle = bindings.toggle
            if keyCode == hold.keyCode {
                let isDown = flags.contains(hold.presenceMask)
                let isolated = flags.intersection(HotkeyBinding.isolationMask) == hold.genericMask
                // Logged before the machine sees it, because the interesting case
                // produces no effects at all: a trigger pressed while any other
                // modifier is down is treated as a chord and refused, and a
                // refusal is indistinguishable from the key never arriving. That
                // blind spot hid roughly a quarter of an eval run.
                if Self.logsGestures {
                    NSLog("[quill] trigger %@ isolated=%@ flags=%llx",
                          isDown ? "DOWN" : "up", isolated ? "yes" : "NO", flags.rawValue)
                }
                apply(machine.handle(isDown ? .triggerDown(isolated: isolated) : .triggerUp,
                                     at: Self.now()))
            } else if keyCode == toggle.keyCode {
                // Only reachable when the two are bound to different keys — the
                // branch above claims the shared case, which is what keeps
                // double-tap working as the default push-to-talk.
                let isDown = flags.contains(toggle.presenceMask)
                let isolated = flags.intersection(HotkeyBinding.isolationMask) == toggle.genericMask
                apply(machine.handle(isDown ? .toggleDown(isolated: isolated) : .toggleUp,
                                     at: Self.now()))
            } else if HotkeyBinding.isTrackedModifier(keyCode: keyCode) {
                apply(machine.handle(.otherModifierChanged, at: Self.now()))
            }
            // Never swallowed: eating a modifier's flagsChanged leaves every other
            // app believing that modifier is still held down.
            return false

        case .keyDown:
            let isBare = flags.intersection(HotkeyBinding.chordMask).isEmpty
            return apply(machine.handle(.keyDown(keyCode: keyCode, isBare: isBare),
                                        at: Self.now()))

        default:
            return false
        }
    }

    /// Off unless asked for. A line per gesture is noise in normal use and the
    /// only way to see anything when a gesture silently fails to become a
    /// dictation — the state machine is the one part of this path with no other
    /// evidence, because a gesture that never arms produces no transcript, no
    /// history row and no overlay to notice.
    private static let logsGestures =
        ProcessInfo.processInfo.environment["QUILL_LOG_HOTKEY"] == "1"

    @discardableResult
    private func apply(_ effects: [HotkeyStateMachine.Effect]) -> Bool {
        if Self.logsGestures, !effects.isEmpty {
            NSLog("[quill] hotkey %@ -> %@", String(describing: machine.state),
                  effects.map { String(describing: $0) }.joined(separator: ","))
        }
        var swallow = false
        for effect in effects {
            switch effect {
            case .beginPreroll:
                deliver { $0.hotkeyMayBegin() }
            case .abortPreroll:
                deliver { $0.hotkeyAborted() }
            case .notifyPressed:
                deliver { $0.hotkeyPressed() }
            case .notifyReleased:
                deliver { $0.hotkeyReleased() }
            case .notifyCancelled:
                deliver { $0.hotkeyCancelled() }
            case let .startArmTimer(token, delay):
                startArmTimer(token: token, delay: delay)
            case .cancelArmTimer:
                armTimer?.invalidate()
                armTimer = nil
            case .swallowEvent:
                swallow = true
            }
        }
        return swallow
    }

    private func startArmTimer(token: Int, delay: TimeInterval) {
        armTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.armTimer = nil
            self.apply(self.machine.handle(.armTimerFired(token: token), at: Self.now()))
        }
        armTimer = timer
        // Scheduled on the tap thread's own runloop, so the state machine is only
        // ever touched from one thread and needs no lock of its own.
        RunLoop.current.add(timer, forMode: .common)
    }

    /// systemUptime, not Date: a clock adjustment mid-gesture must not turn a
    /// double-tap into a single one.
    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// DispatchQueue.main rather than Task { @MainActor }: press and release must
    /// arrive in the order they happened, and only the queue guarantees FIFO.
    /// assumeIsolated is safe because this block only ever runs on the main queue.
    private func deliver(_ call: @escaping @MainActor (HotkeyEngineDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let delegate = self?.delegate else { return }
                call(delegate)
            }
        }
    }

    // MARK: - Why it failed

    private func reportUnavailable() {
        let reason = Self.unavailabilityReason()
        lock.lock()
        let alreadySaid = (lastReportedReason == reason)
        lastReportedReason = reason
        lock.unlock()
        // The retry loop runs forever; saying the same thing every two seconds
        // would bury the moment the cause actually changes.
        guard !alreadySaid else { return }
        deliver { $0.hotkeyEngineUnavailable(reason: reason) }
    }

    /// tapCreate returns nil with no error, no exception and no log. Guessing is
    /// what costs the afternoon, so name the two things it is nearly always.
    private static func unavailabilityReason() -> String {
        if Permissions.secureInputEnabled {
            return """
            Secure Input is on, so macOS will not let any app install an event tap. \
            Nothing is broken and there is no permission to grant — quit whatever \
            turned it on (a terminal with Secure Keyboard Entry enabled, or a \
            password manager that left the flag set) and the hotkey starts working.
            """
        }
        if Permissions.state(of: .accessibility) != .granted {
            return """
            Accessibility is not granted for this build of Quill. \
            \(Permission.accessibility.settingsPath) — and if Quill is already \
            listed there, remove it and add it again: the grant is tied to the code \
            signature, so a rebuild with a different signature keeps the old, dead entry.
            """
        }
        if Permissions.state(of: .inputMonitoring) != .granted {
            return """
            Accessibility is granted but Input Monitoring is not, and some macOS \
            builds require both before an event tap will start. \
            \(Permission.inputMonitoring.settingsPath).
            """
        }
        return """
        The system refused the event tap even though Accessibility and Input \
        Monitoring look granted and Secure Input is off. Quitting and relaunching \
        Quill clears this in most cases; if it does not, remove Quill from \
        \(Permission.accessibility.settingsPath) and add it back.
        """
    }
}

/// C trampoline: recovers the engine from the refcon and translates "handled" into
/// the nil return that swallows an event.
private let quillHotkeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<EventTapHotkeyEngine>.fromOpaque(refcon).takeUnretainedValue()
    return engine.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

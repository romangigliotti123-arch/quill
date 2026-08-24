import Foundation
import Testing
@testable import QuillKit

/// Signing in from the Account tab crashed v1.0.1 with an AppKit exception.
///
/// `AccountStore.notify()` called its listeners on whatever thread finished the
/// network request, which after `authenticate` is a background Swift-concurrency
/// thread. Five of the six observers are views that set `isHidden`, `isDimmed`
/// or `needsLayout` straight away, and AppKit off the main thread raises:
///
///     DevicesCard.isSignedIn.didset
///     -[NSView _setHidden:setNeedsDisplay:]
///     -[NSWindow(Regions) _postWindowNeedsToResetDragMargins]
///     -[NSException raise]
///
/// Signing UP did not crash, which is exactly why it shipped — whether AppKit
/// actually raises depends on what the view hierarchy is doing at that instant,
/// so the same mistake presented as a working code path about half the time.
@Suite struct AccountNotifyThreadTests {

    @Test func observersRegisteredOffTheMainThreadAreStillCalledOnIt() async {
        let shot = OneShot()
        let sawMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread, "this test is pointless if it runs on main")
                let id = AccountStore.shared.observe { _ in
                    let onMain = Thread.isMainThread
                    shot.fire { c.resume(returning: onMain) }
                }
                shot.remember(id)
            }
        }
        shot.stopObserving()
        #expect(sawMain, "an observer was called off the main thread — AppKit will raise")
    }

    @Test func signOutNotifiesOnTheMainThread() async {
        // signOut touches no network, so this is the whole notify path with
        // nothing to stub: persist, then tell everyone.
        let shot = OneShot()
        let sawMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let first = OneShot()
            let id = AccountStore.shared.observe { _ in
                // observe() delivers the current value immediately; the one we
                // want is the notification signOut triggers after it. `first`
                // swallows exactly one call, whichever thread it arrives on.
                var swallowed = false
                first.fire { swallowed = true }
                guard !swallowed else { return }
                let onMain = Thread.isMainThread
                shot.fire { c.resume(returning: onMain) }
            }
            shot.remember(id)
            DispatchQueue.global(qos: .userInitiated).async {
                AccountStore.shared.signOut()
            }
        }
        shot.stopObserving()
        #expect(sawMain, "signOut notified off the main thread")
    }
}

// MARK: -

/// A one-shot latch, and the reason it has to exist.
///
/// `observe` delivers the current value immediately and every later `notify`
/// calls the same handler again — and `AccountStore.shared` is a singleton that
/// the section and sidebar tests also attach observers to, so a `signOut`
/// anywhere in the run reaches this handler too. Resuming a checked continuation
/// twice is not a failed assertion, it is
/// `SWIFT TASK CONTINUATION MISUSE` and a `SIGTRAP` that takes the whole test
/// process down: every other test in the run reports nothing at all. Seen once,
/// on a full run, long after these two tests were written and passing.
///
/// A flaky test that kills the runner is worse than no test.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var observer: UUID?

    /// Runs `body` for the first caller only.
    func fire(_ body: () -> Void) {
        lock.lock()
        let first = !fired
        fired = true
        lock.unlock()
        if first { body() }
    }

    func remember(_ id: UUID) { lock.lock(); observer = id; lock.unlock() }

    /// Called after the continuation has returned, never from inside the
    /// handler: `observe` can deliver synchronously, before it has returned the
    /// id to deregister with, and the old code's `if let id` was simply nil on
    /// that path — leaving the observer attached for the rest of the run.
    func stopObserving() {
        lock.lock(); let id = observer; observer = nil; lock.unlock()
        if let id { AccountStore.shared.stopObserving(id) }
    }
}

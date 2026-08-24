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
        let sawMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread, "this test is pointless if it runs on main")
                var id: UUID?
                id = AccountStore.shared.observe { _ in
                    let onMain = Thread.isMainThread
                    if let id { AccountStore.shared.stopObserving(id) }
                    c.resume(returning: onMain)
                }
            }
        }
        #expect(sawMain, "an observer was called off the main thread — AppKit will raise")
    }

    @Test func signOutNotifiesOnTheMainThread() async {
        // signOut touches no network, so this is the whole notify path with
        // nothing to stub: persist, then tell everyone.
        let sawMain = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            var id: UUID?
            var first = true
            id = AccountStore.shared.observe { _ in
                // observe() delivers the current value immediately; the one we
                // want is the notification signOut triggers after it.
                if first { first = false; return }
                let onMain = Thread.isMainThread
                if let id { AccountStore.shared.stopObserving(id) }
                c.resume(returning: onMain)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                AccountStore.shared.signOut()
            }
        }
        #expect(sawMain, "signOut notified off the main thread")
    }
}

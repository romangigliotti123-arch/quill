import AppKit

/// A detached copy of a pasteboard's contents.
///
/// Detached is the whole point. The `NSPasteboardItem`s handed back by
/// `pasteboardItems` belong to the pasteboard and are emptied by
/// `clearContents()`. Holding them and writing them back restores nothing — the
/// user's clipboard just goes blank, minutes after the dictation that caused it,
/// with no way to connect the two. So the bytes are copied out eagerly and this
/// type stores data, not items.
public struct PasteboardSnapshot: Equatable, Sendable {

    /// One entry per pasteboard item, each mapping raw pasteboard type → bytes.
    /// All types, not just `.string`: clipboards routinely carry RTF, HTML, file
    /// URLs and images at once, and restoring only the plain-text flavour
    /// quietly downgrades what the user copied.
    public let items: [[String: Data]]

    /// How many items the pasteboard actually held, which is not always how many
    /// we managed to read. See `isFaithful`.
    public let sourceItemCount: Int

    /// `changeCount` at capture time. Kept as evidence of *which* clipboard this
    /// was; the restore decision uses our own write's count instead (below).
    public let changeCount: Int

    public init(items: [[String: Data]], sourceItemCount: Int, changeCount: Int) {
        self.items = items
        self.sourceItemCount = sourceItemCount
        self.changeCount = changeCount
    }

    public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }

    /// True when everything on the pasteboard came back readable.
    ///
    /// An unfaithful snapshot must not be used: restoring it clears a clipboard
    /// that was not empty and puts back less than was there. The caller's answer
    /// is to leave the clipboard alone entirely, not to restore what it has.
    public var isFaithful: Bool { items.count(where: { !$0.isEmpty }) == sourceItemCount }

    /// Clipboard managers (Maccy, Paste, Raycast) skip items carrying this type,
    /// per the nspasteboard.org convention. Dictation travelling through the
    /// clipboard is an implementation detail of pasting; it has no business
    /// filling up the user's paste history.
    public static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    // MARK: - Capture

    /// Reads every flavour of every item eagerly. That costs a full copy of the
    /// clipboard — a screenshot on the pasteboard is tens of megabytes — on the
    /// insertion path, which is the latency-sensitive one. It is still the right
    /// trade: the alternative is not being able to give the clipboard back.
    public static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let source = pasteboard.pasteboardItems ?? []
        let copied = source.map { item -> [String: Data] in
            var entry: [String: Data] = [:]
            for type in item.types {
                // nil is a promised flavour the provider declined to produce
                // (file promises, lazily-rendered images). It is skipped rather
                // than chased, and the shortfall shows up in `isFaithful`.
                if let data = item.data(forType: type) { entry[type.rawValue] = data }
            }
            return entry
        }
        return PasteboardSnapshot(
            items: copied,
            sourceItemCount: source.count,
            changeCount: pasteboard.changeCount
        )
    }

    // MARK: - Restore

    /// Returns false when there was nothing to put back, so the caller can tell
    /// "restored the user's clipboard" from "left it empty because it was empty".
    @discardableResult
    public func restore(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let objects = PasteboardSnapshot.detach(items)
        guard !objects.isEmpty else { return false }
        return pasteboard.writeObjects(objects)
    }

    /// Bytes → fresh, independently-owned items. Split out from `restore` because
    /// this is the rule that goes wrong, and it is testable without a pasteboard.
    public static func detach(_ items: [[String: Data]]) -> [NSPasteboardItem] {
        items.compactMap { entry in
            guard !entry.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: .init(type)) }
            return item
        }
    }

    /// Whether the clipboard we are about to overwrite is still ours to overwrite.
    ///
    /// Between our write and the restore the user can copy something new. Putting
    /// a 250 ms-old clipboard back on top of that destroys what they just copied,
    /// and they would never connect the loss to a dictation. If anyone else has
    /// touched the pasteboard, we stand down and leave our text there instead.
    /// Whether putting the user's clipboard back would destroy something they
    /// have since copied.
    ///
    /// `changeCount` alone is the wrong question, and it fails on the most common
    /// setup there is. Roman runs a clipboard manager; so does a large share of
    /// anyone who dictates for a living. Those poll the pasteboard and touch it —
    /// re-declaring types, adding their own, normalising contents — and every
    /// touch advances `changeCount`. Quill read that as "the user copied
    /// something new in the gap", declined to restore, and left the dictation
    /// sitting on the clipboard. Measured on this Mac: after a dictation the
    /// clipboard held "Don't die." and the text that was there before it was
    /// gone, permanently, on what would have been every single dictation.
    ///
    /// The real question is about CONTENT. If the board still holds exactly what
    /// Quill wrote, then whatever bumped the counter did not put anything there
    /// the user wants — restoring is safe. If it holds something else, someone
    /// did, and it is not ours to overwrite.
    ///
    /// `currentText` nil with a moved counter is treated as unsafe: an empty or
    /// non-text clipboard is a state we cannot attribute, and the cost of being
    /// wrong is destroying something the user copied.
    public static func restoreIsSafe(ourChangeCount: Int,
                                     currentChangeCount: Int,
                                     ourText: String? = nil,
                                     currentText: String? = nil) -> Bool {
        if currentChangeCount == ourChangeCount { return true }
        guard let ourText, let currentText else { return false }
        return ourText == currentText
    }

    // MARK: - Writing our own text

    /// Puts `text` on the pasteboard and reads it straight back.
    ///
    /// Returns the `changeCount` of our write, or nil if the pasteboard refused —
    /// which really happens when another process is mid-write. The read-back is
    /// not paranoia: `setString` reporting true while the pasteboard holds
    /// something else is exactly how text disappears.
    @discardableResult
    public static func write(
        _ text: String,
        to pasteboard: NSPasteboard,
        transient: Bool
    ) -> Int? {
        var types: [NSPasteboard.PasteboardType] = [.string]
        if transient { types.append(transientType) }
        let count = pasteboard.declareTypes(types, owner: nil)
        let wrote = pasteboard.setString(text, forType: .string)
        if transient {
            // The convention is a date string; managers key on the type existing.
            pasteboard.setData(Data(ISO8601DateFormatter().string(from: Date()).utf8),
                               forType: transientType)
        }
        guard wrote, pasteboard.string(forType: .string) == text else { return nil }
        return count
    }
}

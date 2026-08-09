import Foundation

/// Sample history, used only when the real store is empty.
///
/// A dictation app on first launch has nothing to show, and a screen designed
/// against nothing is a screen designed against an empty rectangle — the
/// spacing, the truncation, the diff colours and the density all only exist
/// once there is text in them. So the section falls back to this.
///
/// Everything here is deliberately *raw-shaped*: the `rawText` side is what
/// Apple's recogniser actually emits — no capitals, no punctuation, filler
/// intact, compound names split ("net lify", "fire store", "graphite") — and
/// the `insertedText` side is what `FastCleaner` and the vocabulary corrector
/// turn that into. Fixtures where both columns are already tidy would make the
/// diff render as a solid block of "unchanged", which is exactly the screen the
/// section exists to avoid shipping.
public enum DictationFixtures {

    public static func records(relativeTo now: Date = Date(),
                               calendar: Calendar = .current) -> [DictationRecord] {
        seeds.compactMap { seed in
            guard let date = calendar.date(byAdding: .day, value: -seed.daysAgo, to: now),
                  let stamped = calendar.date(bySettingHour: seed.hour, minute: seed.minute,
                                              second: 0, of: date)
            else { return nil }
            let words = seed.inserted.split(whereSeparator: { $0.isWhitespace }).count
            return DictationRecord(
                id: seed.id,
                date: stamped,
                rawText: seed.raw,
                insertedText: seed.inserted,
                wordCount: words,
                inputDevice: seed.device,
                timings: .init(timeToFirstWordMs: seed.firstWordMs,
                               finalToInsertedMs: seed.insertMs,
                               endToEndMs: seed.endToEndMs,
                               audioDurationMs: seed.audioMs,
                               usedThoroughCleanup: seed.thorough))
        }
    }

    private struct Seed {
        let id: UUID
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let raw: String
        let inserted: String
        let device: String
        let firstWordMs: Int
        let insertMs: Int
        let endToEndMs: Int
        let audioMs: Int
        let thorough: Bool
    }

    /// Fixed UUIDs, so "which row is selected" survives a rebuild and two
    /// renders of the same screen are byte-identical.
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    private static let mac = "MacBook Air Microphone"
    private static let pods = "AirPods Pro"

    private static let seeds: [Seed] = [
        Seed(id: id(1), daysAgo: 0, hour: 9, minute: 41,
             raw: "um okay so push the net lify build once the fire store rules land carlo needs the workshop dashboard before thursday and uh make sure the graphite graph gets rebuilt after otherwise the you know search on the site is going to be pointing at the old schema tell him the swatch photos can wait until monday i would rather have the dashboard working first",
             inserted: "Okay, so push the Netlify build once the Firestore rules land. Carlo needs the workshop dashboard before Thursday, and make sure the graphify graph gets rebuilt after, otherwise the search on the site is going to be pointing at the old schema. Tell him the swatch photos can wait until Monday, I would rather have the dashboard working first.",
             device: mac, firstWordMs: 186, insertMs: 71, endToEndMs: 418, audioMs: 28_600, thorough: true),

        Seed(id: id(2), daysAgo: 0, hour: 9, minute: 12,
             raw: "reply to noah cass and tell him the booking page is live um the deposit flow goes in tonight and nothing else changes this week",
             inserted: "Reply to Noah Kass and tell him the booking page is live. The deposit flow goes in tonight, and nothing else changes this week.",
             device: mac, firstWordMs: 204, insertMs: 68, endToEndMs: 392, audioMs: 10_600, thorough: true),

        Seed(id: id(3), daysAgo: 0, hour: 8, minute: 57,
             raw: "idea for quill uh let a transform run on whatever is on the clipboard not just on the last dictation",
             inserted: "Idea for Quill: let a transform run on whatever is on the clipboard, not just on the last dictation.",
             device: mac, firstWordMs: 171, insertMs: 63, endToEndMs: 356, audioMs: 8_900, thorough: true),

        Seed(id: id(4), daysAgo: 0, hour: 8, minute: 30,
             raw: "groceries coffee oat milk and the good bread from the place on sydney road",
             inserted: "Groceries: coffee, oat milk, and the good bread from the place on Sydney Road.",
             device: pods, firstWordMs: 233, insertMs: 74, endToEndMs: 447, audioMs: 6_200, thorough: false),

        Seed(id: id(5), daysAgo: 0, hour: 8, minute: 4,
             raw: "draft the builda bed copy lead with the reversible bedhead the fabric range second and price last",
             inserted: "Draft the Builda Bed copy: lead with the reversible bedhead, the fabric range second, and price last.",
             device: mac, firstWordMs: 179, insertMs: 66, endToEndMs: 371, audioMs: 8_100, thorough: true),

        Seed(id: id(6), daysAgo: 0, hour: 7, minute: 52,
             raw: "remind me to check whether the analyser keeps its context window across a locked session",
             inserted: "Remind me to check whether the analyser keeps its context window across a locked session.",
             device: mac, firstWordMs: 168, insertMs: 61, endToEndMs: 344, audioMs: 7_300, thorough: true),

        Seed(id: id(7), daysAgo: 1, hour: 18, minute: 12,
             raw: "the graphite workspace needs rebuilding after we merge block craft otherwise the god nodes point at files that moved",
             inserted: "The graphify workspace needs rebuilding after we merge blockcraft, otherwise the god nodes point at files that moved.",
             device: mac, firstWordMs: 192, insertMs: 70, endToEndMs: 401, audioMs: 9_800, thorough: true),

        Seed(id: id(8), daysAgo: 1, hour: 17, minute: 48,
             raw: "next fulfilment stage two is still on the old fire store project so the allow list has to be copied across before friday",
             inserted: "nxt Fulfilment stage two is still on the old Firestore project, so the allowlist has to be copied across before Friday.",
             device: mac, firstWordMs: 211, insertMs: 72, endToEndMs: 424, audioMs: 10_100, thorough: true),

        Seed(id: id(9), daysAgo: 1, hour: 14, minute: 20,
             raw: "book the craigie burn shoot for the tuesday morning um and ask if we can use the chair by the window",
             inserted: "Book the Craigieburn shoot for Tuesday morning, and ask if we can use the chair by the window.",
             device: pods, firstWordMs: 246, insertMs: 79, endToEndMs: 468, audioMs: 8_400, thorough: false),

        Seed(id: id(10), daysAgo: 1, hour: 11, minute: 5,
             raw: "quill beat flow on latency again this morning median zero point four two against one point one",
             inserted: "Quill beat Flow on latency again this morning: median 0.42 against 1.1.",
             device: mac, firstWordMs: 163, insertMs: 59, endToEndMs: 338, audioMs: 7_000, thorough: true),

        Seed(id: id(11), daysAgo: 2, hour: 16, minute: 30,
             raw: "the swift ui macro thing is a dead end on command line tools so keep the whole dashboard in app kit",
             inserted: "The SwiftUI macro thing is a dead end on Command Line Tools, so keep the whole dashboard in AppKit.",
             device: mac, firstWordMs: 188, insertMs: 67, endToEndMs: 389, audioMs: 8_700, thorough: true),

        Seed(id: id(12), daysAgo: 2, hour: 9, minute: 15,
             raw: "send carlo the warwick railroaded swatch list and ask which three he wants on the site first",
             inserted: "Send Carlo the Warwick railroaded swatch list and ask which three he wants on the site first.",
             device: mac, firstWordMs: 175, insertMs: 64, endToEndMs: 362, audioMs: 7_600, thorough: true),
    ]
}

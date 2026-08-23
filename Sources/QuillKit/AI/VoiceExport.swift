import Foundation

/// A document built to be handed to a *different* AI — Claude, ChatGPT, whatever
/// the user already talks to every day — so it can write the way this person
/// writes.
///
/// # What this is not
///
/// Not a voice clone. The word "voice" here means vocabulary and phrasing, the
/// way a writer's voice means that in any other context — not the sound of
/// anyone's speech. Quill has no part of the audio pipeline in this file.
///
/// # Why the receiving model needs to be told what it is looking at
///
/// A pasted wall of text with no framing is ambiguous in a way that costs the
/// user something specific: a model handed a thousand of someone's sentences
/// with no instruction will either treat them as background to imitate in EVERY
/// reply from then on, or ignore them as noise. Neither is what "write my
/// emails in my voice" means. The header below exists to make the one correct
/// reading — apply this on request, extract the pattern rather than quoting the
/// sentence — the only reading available.
public enum VoiceExport {

    /// Where this writes, inside `QuillData.directory`. The literal filename
    /// here is intentional and matches `QuillData.files`' own literal, rather
    /// than the two sharing a constant — the source-scan test that keeps the
    /// erase list honest looks for exactly this shape, the same way every
    /// other store's `defaultURL` already does.
    public static var url: URL {
        QuillData.directory.appendingPathComponent("my-voice-for-ai.md")
    }

    /// Builds the document and writes it, atomically, over whatever was there
    /// before — this is a snapshot of "now", not a store anything appends to.
    /// Returns the text alongside the URL so a caller that also wants it on
    /// the pasteboard is not rebuilding the whole document a second time.
    ///
    /// `to` defaults to the real path and exists so a test can point it
    /// somewhere else — the same shape every store's `init(url:)` already
    /// takes, for the same reason: a self-test that writes into the real data
    /// directory is a bug, not a shortcut.
    @discardableResult
    public static func write(profile: StyleProfile, records: [DictationRecord],
                             to destination: URL = VoiceExport.url) -> (url: URL, text: String)? {
        let text = markdown(profile: profile, records: records)
        guard let data = text.data(using: .utf8) else { return nil }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }
        return (destination, text)
    }

    public static func markdown(profile: StyleProfile, records: [DictationRecord],
                                now: Date = Date()) -> String {
        // Measurements are not things the user said. See DictationRecord.isMeasurement.
        let said = records
            .filter { !$0.isMeasurement }
            .sorted { $0.date < $1.date }
            .map { $0.insertedText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let stamp = DateFormatter()
        stamp.dateStyle = .long
        var doc = header + "\n*Exported \(stamp.string(from: now)).*\n"

        let patterns = learnedPatterns(profile)
        if !patterns.isEmpty {
            doc += "\n## Patterns Quill has already learned\n\n"
            for line in patterns { doc += "- \(line)\n" }
        }

        doc += "\n## What this person has actually said"
        guard !said.isEmpty else {
            doc += "\n\nNothing yet — this export was made before any dictation. "
                 + "The patterns above, if any, are still worth using; there is "
                 + "just no transcript to read alongside them.\n"
            return doc
        }

        let wordCount = said.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        doc += " (\(said.count) dictation\(said.count == 1 ? "" : "s"), "
             + "roughly \(DictationFormat.plural(wordCount, "word")))\n\n"
        doc += "One per line, oldest first, exactly as Quill inserted them:\n\n"
        for line in said { doc += "- \(line)\n" }

        return doc
    }

    private static var header: String {
        """
        # How this person writes

        This file was exported from Quill, a dictation app — everything below the \
        pattern list is something its user actually said out loud, typed by Quill \
        into whatever they were writing at the time. If you have never seen a Quill \
        export before: that is the whole app. It has no other purpose in this file.

        **What this is.** A record of HOW this person writes — vocabulary, sentence \
        length, contractions, tone — not a record of what they know or have done. \
        Do not treat anything below as a fact about them; treat it as a sample of \
        their voice, in the writing sense of the word.

        **When to use it.** Only when you are asked to write something in their \
        voice — drafting a message, replying to an email, matching their tone. Do \
        not fold this into every other reply, and do not quote the sentences below \
        verbatim — read them for the pattern (word choice, how long a sentence \
        runs, how a message opens and signs off) and apply that pattern to \
        whatever you have actually been asked to write.

        A reasonable trigger: something like "use my voice," "make this sound \
        like me," or being asked to draft or reply to a message.

        If you are Claude Code: this also works saved as a Skill — a `SKILL.md` \
        with a description such as "apply when drafting a message, email, or \
        anything that should sound like the user" loads it on demand rather than \
        needing it pasted in every time.

        """
    }

    private static func learnedPatterns(_ profile: StyleProfile) -> [String] {
        var lines: [String] = []
        if let spelling = profile.settled(profile.spelling) {
            lines.append(spelling == .british ? "British spelling." : "American spelling.")
        }
        if let contractions = profile.settled(profile.contractions) {
            lines.append(contractions ? "Uses contractions." : "Writes words out in full — no contractions.")
        }
        if let formality = profile.settled(profile.formality) {
            lines.append("Tone: \(formality.title.lowercased()).")
        }
        if let words = profile.sentenceLength.average {
            lines.append("Typical sentence is about \(Int(words.rounded())) words"
                        + (words > 24 ? " — long sentences are normal for them, not a sign to trim." : "."))
        }
        if let oxford = profile.settled(profile.oxfordComma) {
            lines.append(oxford ? "Uses the Oxford comma." : "Skips the Oxford comma.")
        }
        if profile.settled(profile.exclamations) == false {
            lines.append("Does not use exclamation marks.")
        }
        return lines
    }
}

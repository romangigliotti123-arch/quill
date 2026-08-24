import AppKit
import Testing
@testable import QuillKit

// Three things added after Roman's own voice corpus showed what actually goes
// wrong: sound-based repair of proper nouns, formatting that knows where the
// text is going, and a dictionary that fills itself in.
//
// The tests that matter most here are the ones asserting these features do
// NOTHING in the cases where doing something would be destructive.

// MARK: - Phonetic repair

@Test func soundMatchingRepairsWhatSpellingDistanceCannotReach() {
    // Measured failures from the voice corpus. All of these are far away by
    // letters and adjacent by sound, which is the whole reason the corrector was
    // sitting on its hands.
    #expect(VocabularyCorrector.phoneticKey("grapify") == VocabularyCorrector.phoneticKey("graphify"))
    #expect(VocabularyCorrector.phoneticKey("graph if I") == VocabularyCorrector.phoneticKey("graphify"))
    #expect(VocabularyCorrector.phoneticKey("fire store") == VocabularyCorrector.phoneticKey("Firestore"))
    #expect(VocabularyCorrector.phoneticKey("Craig Eburn") == VocabularyCorrector.phoneticKey("Craigieburn"))
    #expect(VocabularyCorrector.phoneticSimilarity("netterfly", "netlify") >= VocabularyCorrector.phoneticThreshold)
}

@Test func aTranspositionCostsOneNotTwo() {
    // "net a fly" against "Netlify" is NTFL against NTLF: one swap. Plain
    // Levenshtein charges two substitutions for that and the pair falls out of
    // range, which is why the distance function has to see transpositions.
    let swapped = VocabularyCorrector.damerauLevenshtein(Array("ntfl"), Array("ntlf"))
    let plain = VocabularyCorrector.levenshtein(Array("ntfl"), Array("ntlf"))
    #expect(swapped == 1)
    #expect(plain == 2)
}

@Test func soundMatchingNeverRewritesOrdinaryEnglish() {
    // The whole risk of matching on sound. "not a fly" has the same consonant
    // skeleton as "Netlify"; if the corrector fired on it, Quill would plant a
    // brand name in the middle of a sentence the user plainly meant. Every span
    // here is ordinary English, so the phonetic route must stay shut.
    let corrector = VocabularyCorrector(vocabulary: Vocabulary(terms: [
        "Netlify", "Firestore", "graphify", "Craigieburn", "Melbourne",
    ]))
    for sentence in [
        "there is not a fly in here",
        "check the network settings",
        "the graphic designer sent it over",
        "we put a firewall in front of it",
        "she is not a flyer",
    ] {
        #expect(corrector.correct(sentence) == sentence,
                "rewrote ordinary English: \(sentence) -> \(corrector.correct(sentence))")
    }
}

@Test func soundMatchingFiresWhenSomethingIsNotAWord() {
    let corrector = VocabularyCorrector(vocabulary: Vocabulary(terms: ["Netlify", "graphify"]))
    // "Netterfly" is not a word, so there is nothing to protect and everything
    // to gain.
    #expect(corrector.correct("push it to Netterfly tonight").contains("Netlify"))
    #expect(corrector.correct("the grapify workspace").contains("graphify"))
}

// MARK: - Where the text is going

@Test func aTerminalGetsNoFullStopAndNoCapital_forACommand() {
    // `git status.` is not a command, and the full stop has to be deleted by hand
    // every single time. This half is unchanged and has to stay working.
    #expect(AppContextFormatter.apply("Git status.", context: .terminal) == "git status")
    #expect(AppContextFormatter.apply("Npm run build.", context: .terminal) == "npm run build")
}

/// This expectation used to be `"Run the build."` -> `"run the build"`, and it
/// was wrong about the sentence rather than about the rule.
///
/// "Run the build." is not a shell command — the command is `npm run build` —
/// it is a sentence someone said to Claude Code, which is what a terminal
/// mostly contains now. Measured on 85 real dictations from Roman's history:
/// 85 prose, 0 commands, 76 opening capitals stripped and 71 full stops
/// stripped by the old rule. See `SpokenCommandTests`.
@Test func aSentenceInATerminalIsNoLongerTreatedAsACommand() {
    #expect(AppContextFormatter.apply("Run the build.", context: .terminal) == "Run the build.")
    #expect(AppContextFormatter.apply("Can you check that for me?", context: .terminal)
            == "Can you check that for me?")
}

@Test func proseIsLeftExactlyAsTheCleanupProducedIt() {
    let sentence = "Push the build tonight."
    #expect(AppContextFormatter.apply(sentence, context: .prose) == sentence)
}

@Test func aQuestionMarkIsInformationAndSurvivesEverywhere() {
    // A full stop is decoration; a question mark is meaning. Stripping it would
    // change what the sentence says.
    #expect(AppContextFormatter.apply("did the build pass?", context: .terminal).hasSuffix("?"))
    #expect(AppContextFormatter.apply("did the build pass?", context: .query).hasSuffix("?"))
}

@Test func anEllipsisIsDeliberateAndIsNotATrailingFullStop() {
    #expect(AppContextFormatter.apply("hold on…", context: .terminal) == "hold on…")
    #expect(AppContextFormatter.apply("wait...", context: .terminal) == "wait...")
}

@Test func aProperNounAtTheStartKeepsItsCapital() {
    // The vocabulary corrector may have capitalised it a moment earlier, on
    // purpose. Lower-casing it back would undo the one repair that worked.
    #expect(AppContextFormatter.apply("SSH into the box", context: .terminal) == "SSH into the box")
    #expect(AppContextFormatter.apply("Netlify deploy, then Netlify open", context: .terminal)
              .hasPrefix("Netlify"))
}

@Test func theContextIsProseUnlessItIsCertain() {
    // A wrong guess silently changes how someone's words come out, so anything
    // unrecognised has to land on the behaviour the app had before this existed.
    #expect(AppContext.of(bundleID: nil) == .prose)
    #expect(AppContext.of(bundleID: "com.some.unknown.app") == .prose)
    #expect(AppContext.of(bundleID: "com.mitchellh.ghostty") == .terminal)
    #expect(AppContext.of(bundleID: "com.apple.Terminal") == .terminal)
    #expect(AppContext.of(bundleID: "com.microsoft.VSCode") == .code)
    #expect(AppContext.of(bundleID: "com.apple.mail") == .prose)
}

// MARK: - Harvesting a dictionary

@Test func aProjectFolderBecomesATermAndScaffoldingDoesNot() {
    #expect(VocabularyHarvest.candidate(from: "blockcraft") == "blockcraft")
    #expect(VocabularyHarvest.candidate(from: "roman-design-co") == "roman design co")
    #expect(VocabularyHarvest.candidate(from: "agent_pipeline") == "agent pipeline")

    // Structure, not product. Every junk entry is another chance for the
    // corrector to rewrite a word the user meant, so the filter matters more
    // than the finding.
    for junk in ["src", "node-modules", "build", "dist", ".git", "tests", "assets"] {
        #expect(VocabularyHarvest.candidate(from: junk) == nil, "accepted junk: \(junk)")
    }
    // Already-ordinary English teaches the recogniser nothing.
    #expect(VocabularyHarvest.candidate(from: "my-portfolio-site") == nil)
    #expect(VocabularyHarvest.candidate(from: "client work") == nil)
    // Version and date strings are not words anyone dictates.
    #expect(VocabularyHarvest.candidate(from: "backup-2026-08-11") == nil)
}

@Test func harvestingNeverProposesSomethingAlreadyKnown() {
    let existing = Vocabulary(terms: ["blockcraft", "Netlify"])
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-harvest-\(UUID().uuidString)")
    let fm = FileManager.default
    for name in ["blockcraft", "geodash", "src", "my-portfolio-site"] {
        try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    let terms = VocabularyHarvest.suggestions(roots: [root], existing: existing).map(\.term)
    #expect(terms.contains("geodash"))
    #expect(!terms.contains("blockcraft"), "suggested a term already in the dictionary")
    #expect(!terms.contains("src"))
    #expect(!terms.contains("my portfolio site"))
}

@Test func harvestingSaysWhereEachSuggestionCameFrom() {
    // A suggestion that cannot be judged can only be accepted on faith, and this
    // one is proposing to change how the user's speech is rewritten.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-harvest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("blockcraft"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let found = VocabularyHarvest.suggestions(roots: [root], existing: Vocabulary(terms: []))
    #expect(found.first?.source.contains("blockcraft") == true)
}

@Test func britishSpellingIsAWordAndIsNeverRewritten() {
    // Found on Roman's own voice: "The colour on the second panel" came out
    // "The Quill on the second panel".
    //
    // Two faults stacked. The spell-check guard asked "en", which is American,
    // so every spelling he actually uses — colour, organised, metre, realise —
    // was reported as a non-word, and a non-word is exactly what unlocks the
    // sound-based repair. Then "colour" and "quill" both reduce to the key "kl",
    // so the match was perfect. The guard meant to protect real English was
    // pointing at his English and calling it fair game.
    #expect(VocabularyCorrector.isRealEnglishWord("colour"))
    #expect(VocabularyCorrector.isRealEnglishWord("organised"))
    #expect(VocabularyCorrector.isRealEnglishWord("realise"))
    #expect(VocabularyCorrector.isRealEnglishWord("metre"))
    #expect(VocabularyCorrector.isRealEnglishWord("aluminium"))

    let corrector = VocabularyCorrector(vocabulary: Vocabulary(terms: ["Quill", "Netlify"]))
    for sentence in [
        "the colour on the second panel does not match",
        "I have organised the files by client",
        "we should realise the savings this quarter",
    ] {
        #expect(corrector.correct(sentence) == sentence,
                "rewrote British English: \(corrector.correct(sentence))")
    }
}

@Test func aSoundKeyTooShortToMeanAnythingIsNotEvidence() {
    // "quill" and "colour" both reduce to "kl". A two-character skeleton collides
    // with half the language, so matching on one is a coin flip that silently
    // rewrites a word. Short terms are still reachable by spelling, which is the
    // right instrument for them — "Kess" still becomes "Kass".
    #expect(VocabularyCorrector.phoneticKey("quill") == VocabularyCorrector.phoneticKey("colour"))
    #expect(VocabularyCorrector.phoneticSimilarity("quill", "colour") == 0)

    // The long keys the feature exists for are untouched.
    #expect(VocabularyCorrector.phoneticSimilarity("netterfly", "netlify")
              >= VocabularyCorrector.phoneticThreshold)
}

// MARK: - A word added in the Dictionary has to work on the next dictation

@Test func addingATermTakesEffectWithoutRelaunching() throws {
    // The cleaner is built once at launch and lives as long as the process, and
    // it held a snapshot of the vocabulary file. So "Add word" wrote to disk and
    // changed nothing: the term was listed in the Dictionary, and the corrector
    // it was added to went on not knowing about it until the app was restarted.
    // A silent no-op that looks exactly like success.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-vocab-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{\"terms\":[]}".utf8).write(to: url)

    let book = VocabularyBook(url: url)
    let corrector = VocabularyCorrector(book: book)

    #expect(corrector.correct("push it to Netterfly tonight") == "push it to Netterfly tonight",
            "repaired a term that is not in the dictionary")

    #expect(book.add("Netlify"))
    #expect(corrector.correct("push it to Netterfly tonight").contains("Netlify"),
            "the corrector did not see a term added after it was built")

    // Same word twice is not an error, but it is not a change either — the panel
    // says so rather than reporting a second success.
    #expect(book.add("netlify") == false)
    #expect(book.add("   ") == false)
    #expect(book.terms.count == 1)
}

@Test func aHandEditToTheVocabularyFileIsPickedUp() throws {
    // The file's own documentation calls it the source of truth and invites
    // editing it directly, so following it has to mean following it, not
    // following whatever it said when the app launched.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-vocab-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("{\"terms\":[\"Netlify\"]}".utf8).write(to: url)

    let book = VocabularyBook(url: url)
    #expect(book.terms == ["Netlify"])

    // Modification dates have one-second resolution on some filesystems; a stamp
    // that has not moved is indistinguishable from a file that has not changed.
    Thread.sleep(forTimeInterval: 1.1)
    try Data("{\"terms\":[\"Netlify\",\"Craigieburn\"]}".utf8).write(to: url)
    #expect(book.terms.contains("Craigieburn"), "did not notice the file changing")
}

@Test func harvestingRejectsAnOrdinaryEnglishWordOnItsOwn() {
    // Straight off Roman's machine: the harvest proposed "dashboard", "maze",
    // "cortex" and "orbital", all of them folders he named with a real word. A
    // single English word is the worst possible entry — the recogniser already
    // knows it, so it can never repair anything, and it sits in the list as one
    // more chance to rewrite a word he meant.
    for word in ["dashboard", "maze", "cortex", "orbital", "homepage"] {
        #expect(VocabularyHarvest.candidate(from: word) == nil, "accepted \(word)")
    }
    // Not English, and therefore exactly what the dictionary is for.
    for word in ["blockcraft", "geodash", "mediadeck", "buildabed"] {
        #expect(VocabularyHarvest.candidate(from: word) == word, "rejected \(word)")
    }
    // Several ordinary words together are still a name: the value is the spacing
    // and the casing, not the individual words.
    #expect(VocabularyHarvest.candidate(from: "roman-design-co") == "roman design co")
}

@Test func anEditorKeepsSentenceCasingBecauseItIsMostlyAChatPanel() {
    // Read straight out of Roman's own history: four consecutive sentences
    // dictated to me through VS Code, every one of them lower-cased.
    //
    //   raw "One thing I want you to do is…"  ->  "one thing I want you to do is…"
    //   raw "Try to change this so that…"     ->  "try to change this so that…"
    //
    // The rule was right about code and wrong about the place he actually uses
    // it. The costs are not symmetrical either: an unwanted capital inside a
    // string literal is one keystroke and impossible to miss, a missing capital
    // on every sentence you dictate is invisible while you speak and arrives in
    // front of whoever you are writing to.
    let sentence = "One thing I want you to do is change the app."
    #expect(AppContextFormatter.apply(sentence, context: .code) == sentence)
    #expect(AppContextFormatter.apply(sentence, context: .prose) == sentence)

    // A terminal still gets neither, which is where suppression earns its place.
    #expect(AppContextFormatter.apply("Git status.", context: .terminal) == "git status")
    // And a search field still loses the full stop but is not a command.
    #expect(AppContextFormatter.apply("Melbourne weather.", context: .query) == "melbourne weather")
}

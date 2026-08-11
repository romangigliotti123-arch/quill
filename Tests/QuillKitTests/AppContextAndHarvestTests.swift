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

@Test func aTerminalGetsNoFullStopAndNoCapital() {
    // `git status.` is not a command, and the full stop has to be deleted by hand
    // every single time.
    #expect(AppContextFormatter.apply("Git status.", context: .terminal) == "git status")
    #expect(AppContextFormatter.apply("Run the build.", context: .terminal) == "run the build")
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
    for name in ["blockcraft", "cortex", "src", "my-portfolio-site"] {
        try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    let terms = VocabularyHarvest.suggestions(roots: [root], existing: existing).map(\.term)
    #expect(terms.contains("cortex"))
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

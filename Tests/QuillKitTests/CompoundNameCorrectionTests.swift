import Testing
@testable import QuillKit

// The compound tool names in FastCleaner.corrections — "get hub" -> "GitHub".
//
// Every entry here is a name the recogniser splits into two ordinary English
// words, which is the one shape neither correction layer can reach:
// VocabularyCorrector refuses single words the spell checker accepts, and a
// two-word span of ordinary English is held to a near-exact bar that "get hub"
// does not clear against "github" by letters alone.
//
// The `mustNotFire` half is the important half. A missed correction costs a
// correction; a false fire rewrites a sentence the user meant and they will not
// notice. Every case below was found firing during development, not invented:
// "I need to get hub caps for the car" really did become "I need to GitHub caps
// for the car" before the anchors were added.

private func clean(_ s: String) -> String { FastCleaner.applyCorrections(to: s) }

@Test func repairsCompoundNamesThatAreNotOrdinaryEnglish() {
    #expect(clean("push it to git hub tonight") == "push it to GitHub tonight")
    #expect(clean("the gethub repo") == "the GitHub repo")
    #expect(clean("the post gres database") == "the Postgres database")
    #expect(clean("deploy to cloud flare") == "deploy to Cloudflare")
    #expect(clean("ask chat gpt about it") == "ask ChatGPT about it")
    #expect(clean("bundle it with web pack") == "bundle it with webpack")
    #expect(clean("open vs code") == "open VS Code")
    #expect(clean("a node js server") == "a Node.js server")
    #expect(clean("built with next js") == "built with Next.js")
    #expect(clean("a three js scene") == "a Three.js scene")
}

@Test func repairsAmbiguousCompoundNamesOnlyWithTheirAnchor() {
    #expect(clean("it is on get hub already") == "it is on GitHub already")
    #expect(clean("check the get hub repo") == "check the GitHub repo")
    #expect(clean("I pushed to get hub") == "I pushed to GitHub")
    #expect(clean("push it to get hub") == "push it to GitHub")
    #expect(clean("rewrite it in type script") == "rewrite it in TypeScript")
    #expect(clean("open the type script file") == "open the TypeScript file")
    #expect(clean("upload it to you tube") == "upload it to YouTube")
    #expect(clean("watch the you tube video") == "watch the YouTube video")
    #expect(clean("check my linked in profile") == "check my LinkedIn profile")
    #expect(clean("sync thing is running") == "Syncthing is running")
    #expect(clean("style it with tail wind") == "style it with Tailwind")
    #expect(clean("put it in air table") == "put it in Airtable")
}

@Test func leavesOrdinaryEnglishContainingThoseWordsAlone() {
    // Through the WHOLE pipeline, not just the anchored table.
    //
    // This used `FastCleaner.applyCorrections` — one stage of two — and passed
    // for its whole life while the shipping path rewrote four of these sentences
    // a step later. The vocabulary corrector's exact-letters branch fires on the
    // bare pair (`normalise("type script") == "typescript"`), so the anchors this
    // test was written to prove were being overruled immediately after it stopped
    // looking.
    //
    // Testing one stage of a two-stage pipeline is how that shipped green, and it
    // is how the next one would too.
    let cleaner = FastCleaner()
    func whole(_ said: String) -> String { cleaner.cleanFast(said) }

    // Each of these fired before the anchors existed.
    let untouched = [
        "I need to get hub caps for the car",
        "I had to get hub caps",
        "we need to get hub bolts",
        "the wheel hub",
        "you tube of toothpaste",
        "can you tube the sample",
        "did you tube feed update",
        "the air table was covered in dust",
        "I linked in the report",
        "a tail wind helped the flight",
        "type script tags by hand",
        "sync thing up later",
        "the black hole in the data",
        "a home brew kit",
    ]
    for sentence in untouched {
        #expect(clean(sentence) == sentence, "the anchored table rewrote: \(sentence)")
        // The pipeline sentence-cases the first word, which is not a rewrite.
        let out = whole(sentence)
        let expected = sentence.prefix(1).uppercased() + sentence.dropFirst()
        #expect(out == expected || out == sentence, "the pipeline rewrote: \(sentence) → \(out)")
    }
}

// Heard in a real dictation on 21 Aug 2026, in Roman's own voice, reading a
// paragraph written to exercise this table. These are the two misses from that
// run that a literal entry can fix without guessing.
@Test func repairsTheManglingsFromTheFirstRealVoiceRun() {
    #expect(clean("with a fire stall back end") == "with a Firestore back end")
    #expect(clean("the old no. js version") == "the old Node.js version")
    #expect(clean("the old no js version") == "the old Node.js version")
    #expect(clean("a no js server") == "a Node.js server")
}

@Test func doesNotTurnAnOrdinaryNoIntoNode() {
    // "no" answering a question about JavaScript is why those entries are
    // anchored on "version" and "server" rather than matching "no js" alone.
    let untouched = [
        "no js is not required here",
        "the answer is no",
    ]
    for sentence in untouched {
        #expect(clean(sentence) == sentence, "rewrote: \(sentence)")
    }
}

// Second real-voice run, 21 Aug 2026. Same paragraph, different manglings.
@Test func repairsTheManglingsFromTheSecondRealVoiceRun() {
    #expect(clean("Sing thinking is finally keeping my notes")
            == "Syncthing is finally keeping my notes")
    #expect(clean("I rewrote the whole thing in Types Group over the weekend")
            == "I rewrote the whole thing in TypeScript over the weekend")
    #expect(clean("the old note js version") == "the old Node.js version")
}

@Test func leavesTheNetlifyManglingAloneBecauseItIsOrdinaryEnglish() {
    // "not a fly" is a real phrase. An entry mapping it to Netlify would rewrite
    // this sentence, which is worse than leaving "The sites are not a fly" wrong.
    let sentence = "there is a fly in the kitchen and it will not leave"
    #expect(clean(sentence) == sentence)
    #expect(clean("that is not a fly it is a wasp") == "that is not a fly it is a wasp")
}

// Real dictation, 21 Aug 2026. The recogniser wrote "node.js" correctly and the
// cleanup pulled it apart: "the node. Js version bump". The punctuation rule
// that turns "word.Next" into "word. Next" was treating a file extension as a
// sentence break, and sentence casing then capitalised the fragment.
@Test func doesNotSplitADottedName() {
    // The vocabulary is handed in rather than read off this Mac.
    //
    // This test passed for months because "Three.js" happened to be in Roman's
    // own Dictionary, and it went red the moment that file was reset — not
    // because the cleanup changed, but because the machine did. A suite whose
    // answer depends on the user's data is one that is green here and red on
    // every fresh clone, which is the first thing anyone from GitHub runs.
    //
    // What the test is actually about is the line below it: a file extension is
    // not a sentence break. The capitalisation is the Dictionary's job, so the
    // Dictionary is stated.
    let cleaner = FastCleaner(vocabulary: VocabularyCorrector(
        vocabulary: Vocabulary(terms: ["Three.js"])))
    #expect(cleaner.cleanFast("the node.js version bump went through")
            == "The node.js version bump went through")
    #expect(cleaner.cleanFast("a three.js scene loads fine")
            == "A Three.js scene loads fine")
    #expect(cleaner.cleanFast("it is live on roman-design-co.web.app now")
            == "It is live on roman-design-co.web.app now")
}

@Test func stillSeparatesARealSentenceBreak() {
    let cleaner = FastCleaner()
    #expect(cleaner.cleanFast("I fixed the build.Just the one test failed")
            == "I fixed the build. Just the one test failed")
    #expect(cleaner.cleanFast("that is done.It works now")
            == "That is done. It works now")
}
